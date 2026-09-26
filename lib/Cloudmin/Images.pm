package Cloudmin::Images;

# Durable image imports. Libvirt owns destination volumes; staging files and
# job records are private to Cloudmin and never live in the module's web root.
use strict;
use warnings;
use WebminCore qw(read_file_contents write_file_contents make_dir
	convert_to_json convert_from_json get_lock_links_dir);
use Digest::SHA qw(hmac_sha256_hex sha256_hex);
use Fcntl qw(:DEFAULT O_NOFOLLOW);
use POSIX qw(setsid _exit);
use Cwd qw(abs_path);
use File::Basename qw(dirname);
require(dirname(__FILE__).'/Attempts.pm');
require(dirname(__FILE__).'/Worker.pm');
require(dirname(__FILE__).'/Libvirt.pm');

my $RESERVE_BYTES = 256 * 1024**2;

# import_limit_bytes([gib])
# Converts the administrator's whole-GiB setting; absent or zero uses space.
sub import_limit_bytes
{
my ($gib) = @_;
return 0 if (!defined($gib) || $gib eq '' || $gib eq '0');
# Keep byte counts exact in both Perl and the browser's numeric representation.
die "Invalid maximum image import size. Choose available space or a positive whole number of GiB.\n"
	if (ref($gib) || $gib !~ /\A[1-9]\d{0,6}\z/ || $gib > 8388607);
return $gib * 1024**3;
}

# new(class, directory => path, lock_file => callback, unlock_file => callback,
#     test_lock => callback, log => callback, disk_free => callback,
#     [uri => URI], [worker => runner], [pool_lock => callback], [max_bytes => n])
# Opens the private job store with the module's Webmin locking and logging APIs.
# uri defaults to qemu:///system; worker defaults to an isolated task runner.
# pool_lock(uuid, callback, creating) coordinates reservations and deletion
# with pool lifecycle changes; creating requests an active-pool recheck.
# max_bytes optionally caps image files; zero or absent uses available space.
sub new
{
my ($class, %opts) = @_;
# Callers must choose storage outside the module's public directory.
die "Image job directory is required\n" if (!$opts{'directory'});
Cloudmin::Worker::byte_limit($opts{'max_bytes'}) if ($opts{'max_bytes'});
make_dir($opts{'directory'}, 0700, 1)
	|| die "Cannot create image job directory: $!\n";
return bless({ %opts, uri => $opts{'uri'} || 'qemu:///system' }, $class);
}

# with_lock(self, file, nodiff, callback)
# Releases Webmin locks even when an operation returns early or throws an error.
# nodiff suppresses file-content logging; callback() returns the result.
sub with_lock
{
my ($self, $file, $nodiff, $code) = @_;
$self->{'lock_file'}->($file, 0, 0, $nodiff)
	|| die "Cannot lock $file\n";
my $result;
my $ok = eval { $result = $code->(); 1 };
my $error = $@;
$self->{'unlock_file'}->($file);
# Propagate callback failures only after releasing the Webmin lock.
die $error if (!$ok);
return $result;
}

# log_action(self, action, job, [error])
# Flushes metadata diffs with the action; never passes form tokens or disk data.
sub log_action
{
my ($self, $action, $job, $error) = @_;
$self->{'log'}->($action, 'image', $job->{'id'}, {
	name => $job->{'name'}, state => $job->{'state'},
	pool => $job->{'pool_name'}, error => $error || $job->{'error'} || '',
});
}

# generate_id()
# Returns an unpredictable identifier for form tokens and private files.
sub generate_id
{
open(my $fh, '<', '/dev/urandom') || die "Cannot open random source: $!\n";
read($fh, my $bytes, 32) == 32 || die "Cannot read random source\n";
close($fh);
return unpack('H*', $bytes);
}

# key(self)
# Loads or creates the module-local CSRF signing key under a file lock.
sub key
{
my ($self) = @_;
my $file = "$self->{directory}/form-key";
# The signing key must never enter Webmin's file-change log.
return $self->with_lock($file, 1, sub {
	my $key = read_file_contents($file);
	# A read failure must not replace the key and invalidate
	# existing forms.
	die "Cannot read form key: $!\n" if (!defined($key) && -e $file);
	if (!$key) {
		# Only the lock holder initializes an empty key file.
		$key = generate_id();
		write_private_file($file, $key);
		}
	return $key;
	});
}

# form_token(self, owner)
# Signs a one-day form token, also used to make double submissions idempotent.
sub form_token
{
my ($self, $owner) = @_;
my $value = time().'.'.generate_id();
return $value.'.'.hmac_sha256_hex("$owner:$value", $self->key());
}

# check_token(self, owner, token)
# Requires a token issued to this authenticated Webmin user within one day.
sub check_token
{
my ($self, $owner, $token) = @_;
my ($stamp, $nonce, $signature) = ($token || '') =~
	/\A(\d+)\.([a-f0-9]{64})\.([a-f0-9]{64})\z/;
# Allow small clock skew, but reject stale, malformed or foreign-user
# tokens.
die "This form has expired. Reload the page and try again.\n"
	if (!$stamp || $stamp > time()+300 || $stamp < time()-86400 ||
	    $signature ne hmac_sha256_hex("$owner:$stamp.$nonce",
	$self->key()));
}

# path(self, id, suffix)
# Validates the job ID; suffix is a fixed extension supplied by internal
# callers.
sub path
{
my ($self, $id, $suffix) = @_;
die "Invalid image job\n" if (($id || '') !~ /\A[a-f0-9]{32}\z/);
return "$self->{directory}/$id.$suffix";
}

# save(self, id, record)
# Atomically replaces the status file so readers never see partial JSON.
sub save
{
my ($self, $id, $record) = @_;
$record->{'updated'} = time();
write_private_file($self->path($id, 'json'), convert_to_json($record, 0, 1));
}

# write_private_file(file, data)
# Uses Webmin's atomic writer with private permissions and catchable errors.
sub write_private_file
{
my ($file, $data) = @_;
no warnings 'once';
local $main::error_must_die = 1;
my $mask = umask(0077);
my $ok = eval { write_file_contents($file, $data); 1 };
my $error = $@;
umask($mask);
# Restore the caller's permissions policy even when the atomic write
# fails.
die $error if (!$ok);
}

# get(self, id, [owner])
# Reads a job, optionally restricting access to its initiating Webmin user.
sub get
{
my ($self, $id, $owner) = @_;
my $json = read_file_contents($self->path($id, 'json'));
# Missing or unreadable records are not valid import jobs.
die "Image job not found\n" if (!defined($json));
my $job = convert_from_json($json);
# Use the same error for a missing job and one owned by another user.
die "Image job not found\n" if (defined($owner) && $job->{'owner'} ne $owner);
return $job;
}

1;
