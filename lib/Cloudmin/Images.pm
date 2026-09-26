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

1;
