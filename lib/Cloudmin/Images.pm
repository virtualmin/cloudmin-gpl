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

# with_job_lock(self, id, action, callback)
# Skips busy jobs, locks their metadata and staging data, and logs after unlock.
# callback(job) receives the record read under the lock.
sub with_job_lock
{
my ($self, $id, $action, $code) = @_;
my $file = $self->path($id, 'json');
# A running import owns this lock; do not block another HTTP request on
# it.
return if ($self->{'test_lock'}->($file));
my ($job, $result);
my $ok = eval {
	$result = $self->with_lock($file, 0, sub {
		# Re-read under the lock in case another request completed
		# first.
		$job = $self->get($id);
		# Staged images can be gigabytes; never capture them for diffs.
		return $self->with_lock($self->path($id, 'part'), 1,
			sub { $code->($job) });
		});
	1;
	};
my $error = $@;
# No-op callbacks skip audit entries, but completed and failed actions
# log.
$self->log_action($action, $job, $error)
	if ($job && (!$ok || defined($result)));
# Return the original operation error after lock and audit handling.
die $error if (!$ok);
return $result;
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

# list(self, [owner], [active_only], [strict])
# Returns jobs newest first, optionally filtering by owner and working imports.
# Strict reads refuse incomplete ownership information before storage deletion.
sub list
{
my ($self, $owner, $active, $strict) = @_;
# Read-only users can view a fresh host before any job store is created.
die "Cannot read image job directory\n"
	if ($strict && (-e $self->{'directory'} || -l $self->{'directory'}) && !-d $self->{'directory'});
return [] if (!-d $self->{'directory'});
opendir(my $dh, $self->{'directory'}) || die "Cannot list image jobs: $!\n";
my @ids = map { /\A([a-f0-9]{32})\.json\z/ ? $1 : () } readdir($dh);
closedir($dh);
# A concurrent deletion may remove an entry after directory enumeration.
my @jobs = grep { $_ && $_->{'state'} ne 'deleted' }
	map { $strict ? $self->get($_) : eval { $self->get($_) } } @ids;
# A supplied owner narrows the result without changing shared store
# contents.
@jobs = grep { $_->{'owner'} eq $owner } @jobs if (defined($owner));
# Use the same live-worker criteria for the overview count and job listing.
if ($active) {
	@jobs = grep {
		$_->{'state'} =~ /\A(?:queued|downloading|uploading|copying|verifying|importing)\z/ &&
		time() - $_->{'updated'} < 3700 &&
		(!$_->{'pid'} || kill(0, $_->{'pid'}))
		} @jobs;
	}
return [ sort { $b->{'created'} <=> $a->{'created'} } @jobs ];
}

# staging_limit(self)
# Reserves space on the actual staging filesystem, not only the target pool.
sub staging_limit
{
my ($self) = @_;
my $available = $self->{'disk_free'}->($self->{'directory'});
# Unknown capacity must fail before an import starts consuming space.
die "Cannot determine free staging space.\n"
	if (!defined($available) || $available !~ /\A\d+\z/);
my $limit = $available - $RESERVE_BYTES;
# Keep the reserve even when the proposed image itself would fit.
die "Not enough free space for image staging.\n" if ($limit <= 0);
my $maximum = $self->{'max_bytes'} || 0;
return $maximum && $maximum < $limit ? $maximum : $limit;
}

# import_pool(self, uuid, [connection])
# Rechecks the current destination before accepting or processing image data.
sub import_pool
{
my ($self, $uuid, $conn) = @_;
require Sys::Virt;
$conn ||= Sys::Virt->new(uri => $self->{'uri'}, readonly => 0);
my $pool = $conn->get_storage_pool_by_uuid($uuid);
die "The selected storage pool is no longer active.\n" if (!$pool->is_active());
my $xml = $pool->get_xml_description();
die "Image import requires a directory, filesystem or NFS pool.\n"
	if ($xml !~ /<pool\b[^>]*type=['"](?:dir|fs|netfs)['"]/);
Cloudmin::Libvirt::refresh_pool($pool);
return $pool;
}

# pool_limit(pool)
# Leaves a filesystem reserve and rejects unknown destination capacity.
sub pool_limit
{
my ($pool) = @_;
my $available = $pool->get_info()->{'available'};
die "Cannot determine free storage pool space.\n"
	if (!defined($available) || ref($available) || $available !~ /\A\d+\z/);
die "The storage pool does not have enough free space.\n"
	if ($available <= $RESERVE_BYTES);
return $available - $RESERVE_BYTES;
}

# validate_url(url)
# Accepts HTTPS downloads only, without embedded credentials or control bytes.
sub validate_url
{
my ($url) = @_;
die "Enter a direct HTTPS image URL without login credentials.\n"
	if (!defined($url) || length($url) > 4096 ||
	    $url !~ m{\Ahttps://[^/\s\@?#]+/[^\s\x00-\x1f]*\z}i);
# Webmin's URL parser matches the scheme case-sensitively.
$url =~ s/\Ahttps:/https:/i;
return $url;
}

# catalogue_request(image, pool) copies validated image metadata for an import.
sub catalogue_request
{
my ($image, $pool) = @_;
return { source => 'download', pool => $pool->{'id'}, pool_name => $pool->{'name'},
	slug => $image->{'id'},
	(map { $_ => $image->{$_} } qw(name format url checksum_url checksum_algorithm
		architecture firmware cloud_init guest_agent min_disk_bytes)),
	checksum_source => ($image->{'catalogue_origin'} || '') eq 'bundled' ? 'vendor' : 'catalogue' };
}

# matches_download(job, request) compares assets without trusting display names.
# The destination pool is checked separately when joining an unfinished import.
sub matches_download
{
my ($job, $request) = @_;
# Only catalogue downloads can match a reusable source.
return 0 if (($job->{'source'} || '') ne 'download');
# Require the exact asset and checksum source, not merely the same release ID.
foreach my $field (qw(slug url format architecture checksum_url checksum_algorithm)) {
	return 0 if (($job->{$field} || '') ne ($request->{$field} || ''));
}
return 1;
}

# create(self, owner, token, request, [selection], [attempt])
# Records a validated import once. Repeated submission returns the same job.
# selection distinguishes images submitted together with one form token.
# attempt permits a fresh submission while preserving the signed token.
sub create
{
my ($self, $owner, $token, $request, $selection, $attempt) = @_;
$self->check_token($owner, $token);
$self->prune_deleted();
my $id = substr(sha256_hex(Cloudmin::Attempts::key($token, $attempt).(defined($selection) ? ':'.$selection : '')),
	0, 32);
# An attempt identifies one submission. Changed inputs must never silently
# return an earlier upload or import with different validation and storage.
my $fingerprint = sha256_hex(convert_to_json($request, 1));
# existing(): accept a retry only when its owner and original inputs match.
my $existing = sub {
	my $job = $self->get($id, $owner);
	my $saved = $job->{'request_fingerprint'};
	# Older records keep the original form fields at the top level.
	$saved ||= sha256_hex(convert_to_json({ map { $_ => $job->{$_} }
		keys %$request }, 1));
	die "This form has already submitted different image settings; reload the page\n"
		if ($saved ne $fingerprint);
	return $job;
	};
# A repeated form submission only reads an existing job, so it must not
# wait for that job's download or upload to release its write lock.
return $existing->() if (-f $self->path($id, 'json'));
# create(): reserve and audit the import while its pool is locked.
my $create = sub {
	my $created;
	my $job = $self->with_lock($self->path($id, 'json'), 0, sub {
		# Another submitter may have created the record while we waited.
		return $existing->() if (-f $self->path($id, 'json'));
		my $job = { %$request, id => $id, owner => $owner, created => time(),
			request_fingerprint => $fingerprint,
			state => $request->{'source'}
			eq 'upload' ? 'waiting' : 'queued',
			bytes => 0,
			volume => 'cloudmin-'.($request->{'slug'} || 'image').
				'-'.substr($id, 0, 12).'.'.$request->{'format'} };
		$self->save($id, $job);
		$created = 1;
		return $job;
		});
	# A repeated form submission reuses its job without duplicating the
	# audit.
	$self->log_action('create', $job) if ($created);
	return $job;
	};
return $self->{'pool_lock'} ? $self->{'pool_lock'}->($request->{'pool'}, $create, 1) : $create->();
}

# prune_deleted(self)
# Discards deletion markers after their one-day submission tokens have expired.
# A second day covers allowed clock skew and leaves retries time to finish.
sub prune_deleted
{
my ($self) = @_;
opendir(my $dh, $self->{'directory'}) || die "Cannot list image jobs: $!\n";
my @ids = map { /\A([a-f0-9]{32})\.json\z/ ? $1 : () } readdir($dh);
closedir($dh);
foreach my $id (@ids) {
	my $file = $self->path($id, 'json');
	my $job = eval { $self->get($id) };
	next if (!$job || $job->{'state'} ne 'deleted' ||
		($job->{'updated'} || 0) >= time()-172800 || $self->{'test_lock'}->($file));
	$self->with_lock($file, 1, sub {
		# Another import request may have pruned this record while we waited.
		return if (!-f $file);
		my $current = $self->get($id);
		return if ($current->{'state'} ne 'deleted' ||
			($current->{'updated'} || 0) >= time()-172800);
		foreach my $path ($self->path($id, 'cancel'), $file) {
			unlink($path) || die "Cannot remove expired image job: $!\n" if (-e $path);
			}
		});
	}
}

# transfer(self, job, input, limit, state)
# Copies bounded binary chunks and publishes byte progress once per second.
# For uploading, limit is the exact Content-Length; otherwise it is a ceiling.
sub transfer
{
my ($self, $job, $input, $limit, $state) = @_;
sysopen(my $out, $self->path($job->{'id'}, 'part'), O_WRONLY|O_CREAT|O_EXCL,
	0600)
	|| die "Cannot create staging file: $!\n";
binmode($out);
$job->{'state'} = $state;
$job->{'bytes'} = 0;
$self->save($job->{'id'}, $job);
my $last = 0;
my $checked = 0;
while (1) {
	$self->checkpoint($job);
	# HTTP request bodies end at Content-Length, not at socket EOF.
	last if ($state eq 'uploading' && $job->{'bytes'} == $limit);
	my $count = 1024*1024;
	# Do not read beyond this request's body on a persistent HTTP
	# connection.
	$count = $limit - $job->{'bytes'}
		if ($state eq 'uploading' && $count > $limit - $job->{'bytes'});
	my $buffer = '';
	my $n = read($input, $buffer, $count, 0);
	# A failed read must not look like successful end-of-file.
	die "Cannot read image data: $!\n" if (!defined($n));
	# Stop at EOF, then check the promised length below for
	# truncated uploads.
	last if (!$n);
	$job->{'bytes'} += $n;
	# Enforce the limit on received bytes, independently of header
	# validation.
	die "Image exceeds the available staging limit.\n"
		if ($job->{'bytes'} > $limit);
	if ($job->{'bytes'} - $checked >= 64 * 1024**2) {
		# Recheck during large transfers when other jobs may consume
		# space.
		die "Image staging is running out of free space.\n"
			if ($self->staging_limit() < $n);
		$checked = $job->{'bytes'};
		}
	print($out $buffer) || die "Cannot write image data: $!\n";
	if (time() != $last) {
		# Avoid a status-file rewrite for every chunk on a fast
		# connection.
		$self->save($job->{'id'}, $job);
		$last = time();
		}
	}
close($out) || die "Cannot finish staging image: $!\n";
# Empty files cannot contain a usable disk image.
die "The image is empty.\n" if (!$job->{'bytes'});
# EOF before Content-Length is a failed upload, not a smaller image.
die "The upload was interrupted.\n"
	if ($state eq 'uploading' && $job->{'bytes'} != $limit);
}

# checkpoint(self, job)
# Checks the cancellation flag without signalling a possibly reused process ID.
sub checkpoint
{
my ($self, $job) = @_;
die "Image import cancelled.\n" if (-e $self->path($job->{'id'}, 'cancel'));
}

# cleanup_staging(self, id)
# Stops any orphaned sandbox and removes only this job's staged data.
sub cleanup_staging
{
my ($self, $id) = @_;
$self->path($id, 'part');
my $job = $self->get($id);
# A controller crash can leave a worker running after its import
# disappears.
Cloudmin::Worker->new()->cleanup($job->{'worker'}) if ($job->{'worker'});
opendir(my $dh, $self->{'directory'}) || die "Cannot list staging files: $!\n";
my @files = grep { /^\Q$id\E\.(?:checked|part(?:\.webmintmp\.\d+\.\d+)?)$/ }
	readdir($dh);
closedir($dh);
foreach my $file (@files) {
	unlink("$self->{directory}/$file") ||
		die "Cannot remove staged image: $!\n";
	}
}

1;
