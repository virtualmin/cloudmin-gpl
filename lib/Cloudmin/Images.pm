package Cloudmin::Images;

# Durable image imports. Libvirt owns destination volumes; staging files and job
# records are private to Cloudmin and never live in the module's web root.
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

# import_limit_bytes([gib]) Converts the administrator's whole-GiB setting;
# absent or zero uses space.

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
#     [uri => URI], [worker => runner], [pool_lock => callback], [max_bytes =>
#     n])
# Opens the private job store with the module's Webmin locking and logging APIs.
# uri defaults to qemu:///system; worker defaults to an isolated task runner.
# pool_lock(uuid, callback, creating) coordinates reservations and deletion with
# pool lifecycle changes; creating requests an active-pool recheck. max_bytes
# optionally caps image files; zero or absent uses available space.

sub new
{
my ($class, %opts) = @_;
# Callers must choose storage outside the module's public directory.
die "Image job directory is required\n" if (!$opts{'directory'});
Cloudmin::Worker::byte_limit($opts{'max_bytes'}) if ($opts{'max_bytes'});
make_dir($opts{'directory'}, 0700, 1) ||
	die "Cannot create image job directory: $!\n";
return bless({ %opts, uri => $opts{'uri'} || 'qemu:///system' }, $class);
}

# with_lock(self, file, nodiff, callback) Releases Webmin locks even when an
# operation returns early or throws an error. nodiff suppresses file-content
# logging; callback() returns the result.

sub with_lock
{
my ($self, $file, $nodiff, $code) = @_;
$self->{'lock_file'}->($file, 0, 0, $nodiff) ||
	die "Cannot lock $file\n";
my $result;
my $ok = eval { $result = $code->(); 1 };
my $error = $@;
$self->{'unlock_file'}->($file);
# Propagate callback failures only after releasing the Webmin lock.
die $error if (!$ok);
return $result;
}

# log_action(self, action, job, [error]) Flushes metadata diffs with the action;
# never passes form tokens or disk data.

sub log_action
{
my ($self, $action, $job, $error) = @_;
$self->{'log'}->($action, 'image', $job->{'id'}, {
	name => $job->{'name'}, state => $job->{'state'},
	pool => $job->{'pool_name'}, error => $error || $job->{'error'} ||
					      '',
});
}

# with_job_lock(self, id, action, callback) Skips busy jobs, locks their
# metadata and staging data, and logs after unlock. callback(job) receives the
# record read under the lock.

sub with_job_lock
{
my ($self, $id, $action, $code) = @_;
my $file = $self->path($id, 'json');
# A running import owns this lock; do not block another HTTP request on it.
return if ($self->{'test_lock'}->($file));
my ($job, $result);
my $ok = eval {
	$result = $self->with_lock($file, 0, sub {
		# Re-read under the lock in case another
		# request completed first.
		$job = $self->get($id);
		# Staged images can be gigabytes; never capture them for diffs.
		return $self->with_lock($self->path($id, 'part'), 1,
					sub { $code->($job) });
		});
	1;
	};
my $error = $@;
# No-op callbacks skip audit entries, but completed and failed actions log.
$self->log_action($action, $job, $error)
	if ($job && (!$ok || defined($result)));
# Return the original operation error after lock and audit handling.
die $error if (!$ok);
return $result;
}

# generate_id() Returns an unpredictable identifier for form
# tokens and private files.

sub generate_id
{
open(my $fh, '<', '/dev/urandom') || die "Cannot open random source: $!\n";
read($fh, my $bytes, 32) == 32 || die "Cannot read random source\n";
close($fh);
return unpack('H*', $bytes);
}

# key(self) Loads or creates the module-local CSRF signing
# key under a file lock.

sub key
{
my ($self) = @_;
my $file = "$self->{directory}/form-key";
# The signing key must never enter Webmin's file-change log.
return $self->with_lock($file, 1, sub {
	my $key = read_file_contents($file);
	# A read failure must not replace the key and invalidate existing forms.
	die "Cannot read form key: $!\n" if (!defined($key) && -e $file);
	if (!$key) {
		# Only the lock holder initializes an empty key file.
		$key = generate_id();
		write_private_file($file, $key);
		}
	return $key;
	});
}

# form_token(self, owner) Signs a one-day form token, also used to make double
# submissions idempotent.

sub form_token
{
my ($self, $owner) = @_;
my $value = time().'.'.generate_id();
return $value.'.'.hmac_sha256_hex("$owner:$value", $self->key());
}

# check_token(self, owner, token) Requires a token issued to this authenticated
# Webmin user within one day.

sub check_token
{
my ($self, $owner, $token) = @_;
my ($stamp, $nonce, $signature) = ($token || '') =~
				  /\A(\d+)\.([a-f0-9]{64})\.([a-f0-9]{64})\z/;
# Allow small clock skew, but reject stale, malformed or foreign-user tokens.
die "This form has expired. Reload the page and try again.\n"
	if (!$stamp || $stamp > time() + 300 || $stamp < time() - 86400 ||
	    $signature ne hmac_sha256_hex("$owner:$stamp.$nonce",
					  $self->key()));
}

# path(self, id, suffix) Validates the job ID; suffix is a fixed extension
# supplied by internal callers.

sub path
{
my ($self, $id, $suffix) = @_;
die "Invalid image job\n" if (($id || '') !~ /\A[a-f0-9]{32}\z/);
return "$self->{directory}/$id.$suffix";
}

# save(self, id, record) Atomically replaces the status file so readers
# never see partial JSON.

sub save
{
my ($self, $id, $record) = @_;
$record->{'updated'} = time();
write_private_file($self->path($id, 'json'), convert_to_json($record, 0, 1));
}

# write_private_file(file, data) Uses Webmin's atomic writer with private
# permissions and catchable errors.

sub write_private_file
{
my ($file, $data) = @_;
no warnings 'once';
local $main::error_must_die = 1;
my $mask = umask(0077);
my $ok = eval { write_file_contents($file, $data); 1 };
my $error = $@;
umask($mask);
# Restore the caller's permissions policy even when the atomic write fails.
die $error if (!$ok);
}

# get(self, id, [owner]) Reads a job, optionally restricting access to its
# initiating Webmin user.

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

# list(self, [owner], [active_only], [strict]) Returns jobs newest first,
# optionally filtering by owner and working imports. Strict reads refuse
# incomplete ownership information before storage deletion.

sub list
{
my ($self, $owner, $active, $strict) = @_;
# Read-only users can view a fresh host before any job store is created.
die "Cannot read image job directory\n"
	if ($strict && (-e $self->{'directory'} || -l $self->{'directory'}) &&
	    !-d $self->{'directory'});
return [ ] if (!-d $self->{'directory'});
opendir(my $dh, $self->{'directory'}) || die "Cannot list image jobs: $!\n";
my @ids = map { /\A([a-f0-9]{32})\.json\z/ ? $1 : () } readdir($dh);
closedir($dh);
# A concurrent deletion may remove an entry after directory enumeration.
my @jobs = grep { $_ && $_->{'state'} ne 'deleted' }
	   map { $strict ? $self->get($_) : eval { $self->get($_) } } @ids;
# A supplied owner narrows the result without changing shared store contents.
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

# staging_limit(self) Reserves space on the actual staging filesystem, not
# only the target pool.

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

# import_pool(self, uuid, [connection]) Rechecks the current destination before
# accepting or processing image data.

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

# pool_limit(pool) Leaves a filesystem reserve and rejects unknown
# destination capacity.

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

# validate_url(url) Accepts HTTPS downloads only, without embedded
# credentials or control bytes.

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
return { source => 'download', pool => $pool->{'id'}, pool_name =>
							      $pool->{'name'},
	 slug => $image->{'id'},
	 (map { $_ =>
		$image->{$_} } qw(name format url checksum_url checksum_algorithm
		architecture firmware cloud_init guest_agent min_disk_bytes)),
	 checksum_source => ($image->{'catalogue_origin'} || '') eq 'bundled'
		 ? 'vendor'
		 : 'catalogue' };
}

# matches_download(job, request) compares assets without trusting display names.
# The destination pool is checked separately when joining an unfinished import.

sub matches_download
{
my ($job, $request) = @_;
# Only catalogue downloads can match a reusable source.
return 0 if (($job->{'source'} || '') ne 'download');
# Require the exact asset and checksum source, not merely the same release ID.
foreach my $field (
	qw(slug url format architecture checksum_url checksum_algorithm)) {
	return 0
		if (($job->{$field} || '') ne ($request->{$field} || ''));
	}
return 1;
}

# create(self, owner, token, request, [selection], [attempt]) Records a
# validated import once. Repeated submission returns the same job. selection
# distinguishes images submitted together with one form token. attempt permits a
# fresh submission while preserving the signed token.

sub create
{
my ($self, $owner, $token, $request, $selection, $attempt) = @_;
$self->check_token($owner, $token);
$self->prune_deleted();
my $id =
	substr(sha256_hex(Cloudmin::Attempts::key($token,
						  $attempt).(defined($selection) ? ':'.$selection : '')),
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
# A repeated form submission only reads an existing job, so it must not wait for
# that job's download or upload to release its write lock.
return $existing->() if (-f $self->path($id, 'json'));
# create(): reserve and audit the import while its pool is locked.
my $create = sub {
	my $created;
	my $job = $self->with_lock($self->path($id, 'json'), 0, sub {
		# Another submitter may have created the record while we waited.
		return $existing->() if (-f $self->path($id, 'json'));
		my $job =
			{ %$request, id => $id, owner => $owner,
			  created => time(),
			  request_fingerprint => $fingerprint,
			  state => $request->{'source'}
				   eq 'upload' ? 'waiting' : 'queued',
			  bytes => 0,
			  volume =>
				  'cloudmin-'.($request->{'slug'} || 'image').
				  '-'.substr($id, 0, 12).'.'.
				  $request->{'format'} };
		$self->save($id, $job);
		$created = 1;
		return $job;
		});
	# A repeated form submission reuses its job without
	# duplicating the audit.
	$self->log_action('create', $job) if ($created);
	return $job;
	};
return $self->{'pool_lock'}
	? $self->{'pool_lock'}->($request->{'pool'}, $create, 1)
	: $create->();
}

# prune_deleted(self) Discards deletion markers after their one-day submission
# tokens have expired. A second day covers allowed clock skew and leaves
# retries time to finish.

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
		 ($job->{'updated'} || 0) >= time() - 172800 ||
		 $self->{'test_lock'}->($file));
	$self->with_lock($file, 1, sub {
		# Another import request may have pruned this
		# record while we waited.
		return if (!-f $file);
		my $current = $self->get($id);
		return if ($current->{'state'} ne 'deleted' ||
			   ($current->{'updated'} || 0) >= time() - 172800);
		foreach my $path ( $self->path($id, 'cancel'), $file ) {
			unlink($path) ||
				die "Cannot remove expired image job: $!\n"
				if (-e $path);
			}
		});
	}
}

# start(self, id) Detaches a bounded worker; a per-job lock prevents
# duplicate execution.

sub start
{
my ($self, $id) = @_;
my $pid = fork();
# A failed fork leaves the queued job available for a later retry.
die "Cannot start image import: $!\n" if (!defined($pid));
# Return control to the request while the child performs the import.
return $pid if ($pid);
# Detach from the request; run() opens its own libvirt connection.
setsid();
untie(*STDIN);
untie(*STDOUT);
untie(*STDERR);
$SIG{'CHLD'} = 'DEFAULT';
umask(0077);
open(STDIN, '<', '/dev/null');
open(STDOUT, '>', '/dev/null');
open(STDERR, '>', '/dev/null');
my $ok = eval { $self->run($id); 1 };
# Webmin removes its per-process lock directory only from the request process.
my $links = get_lock_links_dir();
rmdir($links) if ($links);
_exit($ok ? 0 : 1);
}

# receive(self, id, owner, input, length) Streams an authenticated browser
# upload to a fixed private file, not memory. input is a readable handle; length
# is the complete HTTP body size in bytes.

sub receive
{
my ($self, $id, $owner, $input, $length) = @_;
my $job = $self->get($id, $owner);
# Only an unfilled upload job may accept a request body.
die "This job is not waiting for an upload.\n"
	if ($job->{'state'} ne 'waiting');
# Require a bounded Content-Length before consuming any browser data.
Cloudmin::Worker::byte_limit($length);
die "Image exceeds the configured maximum file size.\n"
	if ($self->{'max_bytes'} && $length > $self->{'max_bytes'});
# The shared staging filesystem may have less space than the size cap.
die "Not enough free space to stage this upload.\n"
	if ($length > $self->staging_limit());
my $received = $self->with_job_lock($id, 'upload', sub {
	my ($current) = @_;
	# Another request may have finished this upload before we took its lock.
	die "This upload has already finished.\n"
		if ($current->{'state'} ne 'waiting');
	# Reject insufficient destination space before
	# receiving a large HTTP body.
	die "The storage pool does not have enough free space for this upload.\n"
		if (
			$length > pool_limit(
				$self->import_pool($current->{'pool'})));
	return $self->receive_locked($current, $input, $length);
	});
# A busy job must not spawn another importer for incomplete input.
die "This upload is already running.\n" if (!$received);
# The detached worker must start after the upload releases its Webmin locks.
$self->start($id);
}

# receive_locked(self, job, input, length) Receives an upload while the caller
# holds its metadata and staging locks.

sub receive_locked
{
my ($self, $job, $input, $length) = @_;
my $id = $job->{'id'};
my $ok = eval {
	local $SIG{'ALRM'} =
		sub { die "Upload timed out. Please try again.\n" };
	alarm(3600);
	$self->transfer($job, $input, $length, 'uploading');
	$self->checkpoint($job);
	$job->{'state'} = 'queued';
	$self->save($id, $job);
	alarm(0);
	1;
	};
alarm(0);
if (!$ok) {
	# A partial upload must never become an importable disk.
	my $error = "$@";
	$job->{'failure_state'} = $job->{'state'};
	my $cleaned = eval { $self->cleanup_staging($id); 1 };
	# Keep cleanup failures alongside the reason the upload stopped.
	$error .= " Staging cleanup failed: $@" if (!$cleaned);
	$job->{'state'} = $cleaned &&
			  -e $self->path($id, 'cancel') ? 'deleted' : 'failed';
	$job->{'error'} = $error;
	# Staging cleanup must finish before a replacement import is allowed.
	$job->{'cleanup_pending'} = $cleaned ? 0 : 1;
	$self->save($id, $job);
	die $error;
	}
return 1;
}

# transfer(self, job, input, limit, state) Copies bounded binary chunks and
# publishes byte progress once per second. For uploading, limit is the exact
# Content-Length; otherwise it is a ceiling.

sub transfer
{
my ($self, $job, $input, $limit, $state) = @_;
sysopen(my $out, $self->path($job->{'id'}, 'part'), O_WRONLY | O_CREAT | O_EXCL,
	0600) ||
	die "Cannot create staging file: $!\n";
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
	my $count = 1024 * 1024;
	# Do not read beyond this request's body on a
	# persistent HTTP connection.
	$count = $limit - $job->{'bytes'}
		if ($state eq 'uploading' && $count > $limit - $job->{'bytes'});
	my $buffer = '';
	my $n = read($input, $buffer, $count, 0);
	# A failed read must not look like successful end-of-file.
	die "Cannot read image data: $!\n" if (!defined($n));
	# Stop at EOF, then check the promised length below
	# for truncated uploads.
	last if (!$n);
	$job->{'bytes'} += $n;
	# Enforce the limit on received bytes, independently
	# of header validation.
	die "Image exceeds the available staging limit.\n"
		if ($job->{'bytes'} > $limit);
	if ($job->{'bytes'} - $checked >= 64 * 1024**2) {
		# Recheck during large transfers when other
		# jobs may consume space.
		die "Image staging is running out of free space.\n"
			if ($self->staging_limit() < $n);
		$checked = $job->{'bytes'};
		}
	print($out $buffer) || die "Cannot write image data: $!\n";
	if (time() != $last) {
		# Avoid a status-file rewrite for every chunk
		# on a fast connection.
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

# checkpoint(self, job) Checks the cancellation flag without signalling a
# possibly reused process ID.

sub checkpoint
{
my ($self, $job) = @_;
die "Image import cancelled.\n" if (-e $self->path($job->{'id'}, 'cancel'));
}

# cleanup_staging(self, id) Stops any orphaned sandbox and removes only
# this job's staged data.

sub cleanup_staging
{
my ($self, $id) = @_;
$self->path($id, 'part');
my $job = $self->get($id);
# A controller crash can leave a worker running after its import disappears.
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

# cancel(self, id) Requests worker cleanup without waiting, so a batch can
# stop every download.

sub cancel
{
my ($self, $id) = @_;
sysopen(my $cancel, $self->path($id, 'cancel'), O_WRONLY | O_CREAT, 0600) ||
	die "Cannot cancel image import: $!\n";
close($cancel) || die "Cannot close image cancellation request: $!\n";
}

# remove(self, id) Cancels an active import, or deletes its own unused volume
# under the job lock. Returns false while the worker is still cleaning up;
# callers may poll again.

sub remove
{
my ($self, $id) = @_;
my $job = $self->get($id);
# Keep delete requests idempotent after the first cleanup has succeeded.
return 1 if ($job->{'state'} eq 'deleted');
$self->cancel($id);
# remove(): wait for the import worker to release its metadata before deletion.
my $remove = sub {
	return $self->with_job_lock($id, 'delete', sub {
		return $self->remove_locked($_[0]);
		}) || 0;
	};
return $self->{'pool_lock'}
	? $self->{'pool_lock'}->($job->{'pool'}, $remove, 0)
	: $remove->();
}

# remove_locked(self, job) Deletes only this job's unused volume while its
# Webmin locks are held.

sub remove_locked
{
my ($self, $job) = @_;
my $id = $job->{'id'};
if ($job->{'state'} ne 'deleted' && ($job->{'volume_path'} || $job->{'pid'})) {
	# Inventory errors must block deletion, never imply
	# that a disk is unused.
	require Sys::Virt;
	my $conn = Sys::Virt->new(uri => $self->{'uri'}, readonly => 0);
	my $pool = eval { $conn->get_storage_pool_by_uuid($job->{'pool'}) };
	if (!$pool) {
		# Forget a removed pool's record only if its local file is also
		# gone. A local path check cannot establish
		# absence on a remote host.
		my $error = $@;
		my $missing = ref($error) &&
			      eval { $error->code() ==
			      Sys::Virt::Error::ERR_NO_STORAGE_POOL() };
		die $error if (!$missing || $self->{'uri'}
			       ne 'qemu:///system' ||
			       !$job->{'volume_path'} || -e $job->{'volume_path'} ||
			       -l $job->{'volume_path'});
		}
	else {
		# An existing pool may already have lost this import's volume.
		my ($volume) = grep { $_->get_name() eq $job->{'volume'} }
			       $pool->list_all_volumes();
		if ($volume) {
			# A reused name must not authorize deleting
			# a replacement volume.
			die "The image volume has changed; it was not deleted.\n"
				if ($job->{'volume_key'} && $job->{'volume_key'}
				    ne $volume->get_key());
			$self->assert_unused($conn, $pool, $volume);
			Cloudmin::Libvirt::log_call(
				'Sys::Virt::StorageVol::delete', {
					pool => $job->{'pool'},
					volume => $job->{'volume'},
					flags => 0 });
			$volume->delete(0);
			}
		}
	}
$self->cleanup_staging($id);
# Keep a tombstone so the same attempt cannot recreate the image.
$job->{'state'} = 'deleted';
$job->{'cleanup_pending'} = 0;
delete($job->{'error'});
$self->save($id, $job);
return 1;
}

# xml_uses_volume(xml, path, pool, volume, [base]) Checks libvirt-generated XML
# for file, pool-volume and backing-store refs. base resolves relative backing
# paths when scanning another storage volume.

sub xml_uses_volume
{
my ($xml, $path, $pool, $volume, $base) = @_;
# decode(value) restores XML attribute text before comparing filesystem paths.
my $decode = sub {
	my ($v) = @_;
	$v =~ s/&#x([0-9a-f]+);/chr(hex($1))/gei;
	$v =~ s/&#(\d+);/chr($1)/ge;
	$v =~ s/&quot;/"/g; $v =~ s/&apos;/'/g;
	$v =~ s/&lt;/</g; $v =~ s/&gt;/>/g; $v =~ s/&amp;/&/g;
	return $v;
	};
my @paths;
# Sources may identify a file directly or refer to a named pool volume.
while ($xml =~ /<source\b([^>]*)>/g) {
	my $attrs = $1;
	my %attrs;
	while ($attrs =~ /\b(\w+)\s*=\s*(['"])(.*?)\2/g) {
		$attrs{$1} = $decode->($3);
		}
	# Managed-volume references do not need an explicit filesystem path.
	return 1 if (($attrs{'pool'} || '') eq $pool &&
		     ($attrs{'volume'} || '') eq $volume);
	push(@paths, grep { defined } @attrs{qw(file dev)});
	}
push(@paths, map { $decode->($_) } $xml =~ m{<path>(.*?)</path>}sg);
my $real = abs_path($path) || $path;
my @target_stat = stat($path);
foreach my $ref (@paths) {
	# Storage-volume backing paths can be relative to their containing disk.
	$ref = "$base/$ref" if ($ref !~ m{^/} && $base);
	# Compare both literal and resolved paths to catch
	# aliases to the volume.
	return 1 if ($ref eq $path || (abs_path($ref) || $ref) eq $real);
	# Hard-linked disks share data even when both paths
	# are already canonical.
	my @ref_stat = stat($ref);
	return 1 if (@target_stat && @ref_stat &&
		     $target_stat[0] == $ref_stat[0] &&
		     $target_stat[1] == $ref_stat[1]);
	}
return 0;
}

# volume_references(connection, [excluded_uuid]) Reads libvirt references once
# for a picker or an exclusive-use check.

sub volume_references
{
my ($conn, $excluded) = @_;
my @refs;
foreach my $domain ($conn->list_all_domains()) {
	# The caller checks the excluded guest's saved state and snapshots.
	next if (defined($excluded) && $domain->get_uuid_string() eq $excluded);
	my @xml = ($domain->get_xml_description(0));
	push(@xml,
	     $domain->get_xml_description(Sys::Virt::Domain::XML_INACTIVE()))
		if ($domain->is_persistent());
	push(@xml,
	     map { $_->get_xml_description(0) } $domain->list_all_snapshots());
	push(@refs, map { { xml => $_,
			    reason => "Image is used by virtual machine ".
				      $domain->get_name()."." } } @xml);
	}
foreach my $p ($conn->list_all_storage_pools()) {
	# Inactive pools do not expose a volume inventory.
	next if (!$p->is_active());
	# Discard cached entries for files removed outside
	# libvirt before scanning.
	Cloudmin::Libvirt::refresh_pool($p);
	foreach my $v ($p->list_all_volumes()) {
		my $ref =
			eval { { xml => $v->get_xml_description(0), key =>
									    $v->get_key(),
				 path => $v->get_path(),
				 base => dirname($v->get_path()),
				 reason => "Image is a backing file for volume ".
					   $v->get_name()."." } };
		if (!$ref) {
			# A volume may disappear after listing. Only libvirt's
			# missing-volume error (50) establishes absence; other
			# failures must block deletion.
			my $error = $@;
			next
				if (ref($error) &&
				    $error->isa('Sys::Virt::Error') &&
				    $error->code() == 50);
			die $error;
			}
		push(@refs, $ref);
		}
	}
return \@refs;
}

# volume_use(references, path, pool_name, volume_name, key) Returns the first
# use of a volume, including aliases and backing files.

sub volume_use
{
my ($refs, $path, $pool, $name, $key) = @_;
foreach my $ref (@$refs) {
	# The volume's own XML is not a dependency from another disk.
	next if (defined($ref->{'key'}) && $ref->{'key'} eq $key);
	# Native libvirt and Cloudmin use different keys for the same LVM
	# volume. Exclude the same volume's native record without hiding
	# other backing disks.
	next if (($key || '') =~ /^lvm:/ && $ref->{'path'} &&
		 (abs_path($ref->{'path'}) ||
		  $ref->{'path'}) eq (abs_path($path) || $path));
	return $ref->{'reason'} if (xml_uses_volume($ref->{'xml'},
						    $path, $pool, $name,
						    $ref->{'base'}));
	}
return;
}

# assert_unused(self, connection, pool, volume, [excluded_uuid]) Rechecks live,
# persistent, snapshot and backing references before mutation.

sub assert_unused
{
my ($self, $conn, $pool, $volume, $excluded) = @_;
my $reason = volume_use(volume_references($conn, $excluded),
			$volume->get_path(), $pool->get_name(),
			$volume->get_name(),
			$volume->get_key());
die "$reason\n" if ($reason);
}

# checksum(manifest, filename, algorithm) Reads named GNU/BSD entries or a
# single digest from a per-image sidecar.

sub checksum
{
my ($manifest, $filename, $algorithm) = @_;
# Digest length and manifest matching support only these hash algorithms.
die "Unsupported checksum algorithm\n" if ($algorithm !~ /\Asha(?:256|512)\z/);
my $length = $algorithm eq 'sha512' ? 128 : 64;
# Alpine publishes one bare SHA-512 digest at image.qcow2.sha512.
return lc($1) if ($manifest =~ /\A\s*([a-fA-F0-9]{$length})\s*\z/);
for my $line (split(/\n/, $manifest)) {
	# GNU manifests place the digest before the exact image filename.
	return lc($1)
		if ($line =~ /^([a-fA-F0-9]{$length})\s+\*?\Q$filename\E\s*$/);
	# BSD manifests spell out the algorithm and parenthesized filename.
	return lc($1)
		if (
			$line =~ /^\Q$algorithm\E\s+\(\Q$filename\E\)\s*=\s*([a-fA-F0-9]{$length})\s*$/i);
	}
die "No checksum entry for this image. Check the image and checksum URLs.\n";
}

# run(self, id) Acquires, checks and uploads one image through Sys::Virt. On
# failure, cleanup attempts to delete only this import's new volume and
# reports deletion errors.

sub run
{
my ($self, $id) = @_;
return $self->with_job_lock($id, 'import', sub {
	return $self->run_locked($_[0]);
	});
}

# run_locked(self, job) Imports a queued image while the caller
# holds its Webmin locks.

sub run_locked
{
my ($self, $job) = @_;
my $id = $job->{'id'};
# Replayed starts must not re-import an active or completed job.
return if ($job->{'state'} ne 'queued');
my ($volume, $stream);
my $ok = eval {
	local $SIG{'ALRM'} =
		sub { die "Image import timed out. Please retry.\n" };
	local $SIG{'TERM'} = sub { die "Image import was interrupted.\n" };
	alarm(3600);
	# Resolve current pool state inside this process, after
	# acquiring job locks.
	require Sys::Virt;
	my $conn = Sys::Virt->new(uri => $self->{'uri'}, readonly => 0);
	my $pool = $self->import_pool($job->{'pool'}, $conn);
	# Both the destination pool and private staging area must have room.
	my $limit = pool_limit($pool);
	my $staging_limit = $self->staging_limit();
	# Use the smaller budget across staging and destination filesystems.
	$limit = $staging_limit if ($limit > $staging_limit);
	$job->{'pid'} = $$;
	$self->save($id, $job);
	$self->checkpoint($job);

	my $path = $self->path($id, 'part');
	my %files;
	my $request = { format => $job->{'format'}, limit => $limit,
			sha256 => $job->{'sha256'} };
	if ($job->{'source'} eq 'download' || $job->{'source'} eq 'url') {
		# The HTTPS client and vendor manifest parser run
		# without host privileges.
		$job->{'state'} = 'downloading';
		$request->{'url'} = $job->{'url'};
		if ($job->{'source'} eq 'download') {
			# Catalogue downloads require the
			# publisher's matching checksum.
			$request->{'checksum_url'} = $job->{'checksum_url'};
			$request->{'checksum_algorithm'} =
				$job->{'checksum_algorithm'} || 'sha256';
			}
		}
	else {
		# Local paths and uploads supply file data instead of HTTPS
		# URLs. Host path access is checked by the
		# worker's unprivileged UID.
		if ($job->{'source'} eq 'local') {
			$request->{'path'} = $job->{'path'};
			$job->{'state'} = 'copying';
			}
		elsif ($job->{'source'} eq 'upload') {
			# The upload receiver has already staged the
			# request body privately.
			$files{'image'} = $path;
			$job->{'state'} = 'verifying';
			}
		# Unknown sources must not reach the disk
		# parser or storage pool.
		else { die "Unknown image source\n"; }
		}
	$self->save($id, $job);
	my $checked = $self->path($id, 'checked');
	my $worker = $self->{'worker'} || Cloudmin::Worker->new();
	# started(unit_id) journals the sandbox for recovery after a crash.
	# progress(event) checks cancellation and validates
	# reported byte counts.
	my $info = $worker->run($job->{'source'}
				eq 'local' ? 'local_image' : 'image',
				$request, files => \%files, output => $checked,
				started => sub { $job->{'worker'} = $_[0];
			$self->save($id, $job); },
				progress => sub {
			$self->checkpoint($job);
			my $event = $_[0];
			# Ticks check cancellation without
			# rewriting unchanged progress.
			return if ($event->{'type'} eq 'tick');
			# Workers report progress, never replacement
			# job records or paths.
			if (($event->{'phase'} ||
			     '') =~ /\A(?:downloading|copying)\z/) {
				my $value = $event->{'value'};
				# The worker cannot raise its
				# controller-assigned byte budget.
				die "Invalid download progress\n"
					if (!defined($value) || ref($value) ||
					    $value !~ /\A\d+\z/ || $value > $limit);
				$job->{($event->{'mode'} || 0) == 2
					? 'total'
					: 'bytes'} = 0 + $value;
				}
			elsif (($event->{'phase'} || '') eq 'verifying') {
				# Verification begins only after the worker
				# has acquired the image.
				$job->{'state'} = 'verifying';
				# Ignore unusable optional byte counts while
				# retaining the phase.
				$job->{'bytes'} = $event->{'bytes'}
					if (defined($event->{'bytes'}) &&
					    !ref($event->{'bytes'}) &&
					    $event->{'bytes'} =~ /\A\d+\z/ &&
					    $event->{'bytes'} <= $limit);
				}
			# Only the expected import phases may
			# change the root-owned job.
			else { die "Invalid image worker progress\n"; }
			$self->save($id, $job);
			});
	# Treat worker output as data: only bounded sizes and known checksum
	# names may enter root-owned metadata or the libvirt volume definition.
	# ISO capacity must equal its file size because the
	# bytes are stored as raw.
	die "Invalid checked image metadata\n"
		if (($info->{'format'} || '') ne $job->{'format'} ||
		    !defined($info->{'virtual-size'}) ||
		    ref($info->{'virtual-size'}) ||
		    $info->{'virtual-size'} !~ /\A[1-9]\d*\z/ ||
		    $info->{'virtual-size'} > 16 * 1024**4 ||
		    !defined($info->{'bytes'}) || ref($info->{'bytes'}) ||
		    $info->{'bytes'} !~ /\A[1-9]\d*\z/ ||
		    $info->{'bytes'} > $limit ||
		    $info->{'bytes'} != -s $checked ||
		    ($job->{'format'} eq 'iso' &&
		     $info->{'virtual-size'} != $info->{'bytes'}));
	# Accept the digest algorithm required by this request,
	# not a worker choice.
	my $verified = $info->{'verified'} || '';
	my $expected_algorithm = $job->{'source'} eq 'download'
		? ($job->{'checksum_algorithm'} || 'sha256')
		: $job->{'sha256'} ? 'sha256' : '';
	my $digest_length = $verified eq 'sha512' ? 128 : 64;
	die "Invalid checksum result\n" if ($verified ne $expected_algorithm ||
					    ($verified &&
					     ($info->{'checksum_digest'} ||
					      '') !~ /\A[a-f0-9]{$digest_length}\z/));
	# Replace staging input with the checked file before
	# recording verified metadata.
	unlink($path) || die "Cannot remove unchecked staging file: $!\n"
		if (-e $path);
	rename($checked, $path) || die "Cannot claim checked image: $!\n";
	delete($job->{'worker'});
	# Record verification only when this request required a checksum.
	$job->{'verified'} = $verified if ($verified);
	# Retain the checked digest for later custom catalogue promotion.
	$job->{'checksum_digest'} = $info->{'checksum_digest'} if ($verified);
	$job->{'virtual_size'} = $info->{'virtual-size'};
	$job->{'bytes'} = $info->{'bytes'};
	$self->save($id, $job);
	$self->checkpoint($job);
	# Other operations may have consumed storage while
	# inspection was running.
	Cloudmin::Libvirt::refresh_pool($pool);
	die "The storage pool does not have enough free space.\n"
		if ($job->{'bytes'} > pool_limit($pool));

	# Libvirt stores ISO bytes as raw; the import keeps its
	# ISO type and suffix.
	my $storage_format = $job->{'format'} eq 'iso'
		? 'raw'
		: $job->{'format'};
	$job->{'state'} = 'importing';
	$job->{'transferred'} = 0;
	$self->save($id, $job);
	# Unique volume names and libvirt's create operation prevent overwrite.
	Cloudmin::Libvirt::log_call('Sys::Virt::StoragePool::create_volume', {
		pool => $job->{'pool'}, volume => $job->{'volume'},
		capacity_bytes => $job->{'virtual_size'}, format =>
								  $storage_format });
	$volume = $pool->create_volume("<volume><name>$job->{volume}</name>".
				       "<capacity unit='bytes'>$job->{virtual_size}</capacity>".
				       "<allocation>0</allocation><target><format type='$storage_format'/>".
				       "</target></volume>");
	$job->{'volume_key'} = $volume->get_key();
	$job->{'volume_path'} = $volume->get_path();
	$self->save($id, $job);
	$stream = $conn->new_stream();
	Cloudmin::Libvirt::log_call('Sys::Virt::StorageVol::upload', {
		pool => $job->{'pool'}, volume => $job->{'volume'},
		bytes => $job->{'bytes'}, offset => 0, flags => 0 });
	$volume->upload($stream, 0, $job->{'bytes'}, 0);
	open(my $fh, '<', $path) || die "Cannot open staged image: $!\n";
	binmode($fh);
	my $last = 0;
	# send_all(stream, buffer, length) fills the aliased buffer for libvirt.
	$stream->send_all(sub {
		$self->checkpoint($job);
		# Sys::Virt expects the data in its aliased second argument.
		my $n = read($fh, $_[1], $_[2]);
		# Do not let libvirt finish a stream after a
		# staging-file read error.
		die "Cannot read staged image: $!\n" if (!defined($n));
		$job->{'transferred'} += $n;
		if (time() != $last) {
			# Keep polling useful without rewriting
			# metadata for every chunk.
			$self->save($id, $job);
			$last = time();
			}
		return $n;
		});
	close($fh);
	$stream->finish();
	$stream = undef;
	$self->checkpoint($job);
	Cloudmin::Libvirt::refresh_pool($pool);
	$job->{'volume_key'} = $volume->get_key();
	$job->{'volume_path'} = $volume->get_path();
	$self->cleanup_staging($id);
	$job->{'state'} = 'ready';
	$self->save($id, $job);
	alarm(0);
	1;
	};
alarm(0);
if (!$ok) {
	# Roll back only resources created by this worker, even on timeout.
	my $error = "$@";
	$job->{'failure_state'} = $job->{'state'};
	# Close an incomplete stream before deleting its destination volume.
	eval { $stream->abort() } if ($stream);
	my $removed = 1;
	if ($volume) {
		# Keep deletion failures in the job so the
		# leftover volume is visible.
		$removed = eval {
			Cloudmin::Libvirt::log_call(
				'Sys::Virt::StorageVol::delete', {
					pool => $job->{'pool'},
					volume => $job->{'volume'},
					flags => 0 });
			$volume->delete(0);
			1;
			};
		# Report a leftover volume instead of
		# claiming rollback succeeded.
		$error .= " Failed to remove partial volume $job->{volume}: $@"
			if (!$removed);
		}
	my $cleaned = eval { $self->cleanup_staging($id); 1 };
	# A failed staging cleanup must remain visible for a later delete retry.
	$error .= " Staging cleanup failed: $@" if (!$cleaned);
	$error =~ s/\s+at \S+ line \d+\.?\s*$//;
	$job->{'state'} = $removed && $cleaned &&
			  -e $self->path($id, 'cancel') ? 'deleted' : 'failed';
	$job->{'error'} = $error;
	# Retry only after removing the allocated volume and staging files.
	$job->{'cleanup_pending'} = $removed && $cleaned ? 0 : 1;
	$self->save($id, $job);
	}
return $ok ? 1 : 0;
}

1;
