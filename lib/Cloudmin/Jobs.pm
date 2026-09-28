package Cloudmin::Jobs;

# Transactional controller jobs. Webmin owns resource locks and audit logging;
# SQLite records intentions before libvirt changes and results after them.
use strict;
use warnings;
use WebminCore qw(make_dir convert_to_json convert_from_json
		 get_lock_links_dir);
use POSIX qw(setsid _exit);
use Time::HiRes ();
use Fcntl qw(O_RDWR O_NOFOLLOW LOCK_EX LOCK_NB);

# new(class, directory => path, lock_file => callback, unlock_file => callback,
#     test_lock => callback, log => callback, [host_guard => callback],
#     [admit => callback])
# Constructs a lazy store; reading a fresh host creates no files.
# admit() may reject new submissions; existing IDs and worker updates skip it.
sub new
{
my ($class, %options) = @_;
# Keep job state in a caller-selected private module directory.
die "Job directory is required\n" if (!$options{'directory'});
return bless(\%options, $class);
}

# dependencies()
# Loads the SQLite driver only when the controller job store is used.
sub dependencies
{
require DBI;
require DBD::SQLite;
}

# lock(self, resource, callback, [nonblocking], [waiting])
# Holds a named Webmin resource lock and always releases it after the callback.
# callback() supplies the scalar return value; resource is a safe lock basename.
# nonblocking refuses a held lock; waiting() checks cancellation between disk
# queue attempts and may throw to stop waiting.
sub lock
{
my ($self, $resource, $callback, $nonblocking, $waiting) = @_;
# Resource names become lock basenames and must not contain traversal.
die "Invalid job resource\n" if ($resource !~ /\A[a-z0-9._-]+\z/);
make_dir($self->{'directory'}, 0700, 1) || die "Cannot create job directory\n";
my $file = "$self->{directory}/$resource";
$self->clear_dead_lock($file);
if ($resource eq 'vm-work' || $nonblocking) {
	# Serialize the check and acquisition under a short lock, so workers that
	# wake together cannot enter Webmin's five-minute blocking lock wait.
	my $deadline = time()+86400;
	# Check and claim the resource while the short queue lock is held.
	while (!$self->lock('vm-queue', sub {
		# Another worker still owns the resource; leave it for a later attempt.
		$self->clear_dead_lock($file);
		return 0 if ($self->lock_pid($file));
		$self->{'lock_file'}->($file, 0, 0, 1) || die "Cannot lock job resource\n";
		return 1;
		})) {
		if ($nonblocking) {
			# Schedules must skip overlapping runs instead of queuing them.
			die $resource eq 'vm-work'
				? "Another disk operation is running; try again when it finishes\n"
				: "Another operation is running; try again when it finishes\n";
			}
		$waiting->() if ($waiting);
		die "Timed out waiting for another disk operation\n" if (time() >= $deadline);
		Time::HiRes::sleep(1);
		}
	}
else {
	# Short controller transactions use Webmin's ordinary blocking resource lock.
	$self->{'lock_file'}->($file, 0, 0, 1) || die "Cannot lock job resource\n";
	}
my ($result, $ok);
$ok = eval {
	# Check host-wide network transactions after acquiring the same lock used
	# by bridge setup, closing the gap between form validation and execution.
	$self->{'host_guard'}->() if ($resource eq 'create-host' && $self->{'host_guard'});
	$result = $callback->();
	1;
	};
my $error = $@;
$self->{'unlock_file'}->($file);
# Release the resource before returning the callback's original error.
die $error if (!$ok);
return $result;
}

# busy(self, id)
# Reports a live worker through Webmin's lock API, excluding exited Linux
# processes that still have a PID while waiting to be reaped.
sub busy
{
my ($self, $id) = @_;
validate_id($id);
return $self->lock_pid("$self->{directory}/worker-$id") ? 1 : 0;
}

# zombie(pid) recognizes an exited Linux process that its parent has not reaped.
# Missing or unreadable process data never authorizes breaking a live lock.
sub zombie
{
my ($pid) = @_;
# Only Linux exposes the process state used to distinguish zombies here.
return 0 if ($^O ne 'linux' || !$pid || $pid !~ /\A[0-9]+\z/);
open(my $fh, '<', "/proc/$pid/stat") || return 0;
my $stat = <$fh>;
close($fh);
return $stat && $stat =~ /\A\d+ \(.*\) [ZX] / ? 1 : 0;
}

# lock_pid(self, file) excludes zombies from Webmin's PID-existence check.
sub lock_pid
{
my ($self, $file) = @_;
my $pid = $self->{'test_lock'}->($file);
return $pid && !zombie($pid) ? $pid : 0;
}

# clear_dead_lock(self, file) releases only a lock still owned by a zombie.
# The file lock and inode check protect a replacement written by another worker.
sub clear_dead_lock
{
my ($self, $file) = @_;
my $path = "$file.lock";
# Open the existing lock without following a replacement symlink.
sysopen(my $fh, $path, O_RDWR | O_NOFOLLOW) || return;
# Another inspector may be checking or replacing the same lock.
return if (!flock($fh, LOCK_EX | LOCK_NB));
my $pid = <$fh>;
# A missing, malformed or live owner never authorizes removing the file.
return if (!defined($pid) || $pid !~ /\A([0-9]+)\s*\z/ || !zombie($1));
my @opened = stat($fh);
my @current = lstat($path);
# Leave a new owner's replacement in place even if the old owner has exited.
return if (!@current || $opened[0] != $current[0] || $opened[1] != $current[1]);
unlink($path) || die "Cannot release exited job worker lock: $!\n";
}

# connect(self, write)
# Opens a short-lived SQLite connection; only writers initialize its schema.
# Readers open the existing file read-write without creating it, because a
# read-only connection cannot roll back the hot journal left by a writer that
# was killed mid-transaction, and every later read would fail until a writer
# ran.
sub connect
{
my ($self, $write) = @_;
my $path = "$self->{directory}/jobs.sqlite";
# Inventory reads must not initialize a database on a fresh host.
return undef if (!$write && !-f $path);
dependencies();
my $mask = umask(0077);
my $db = eval { DBI->connect("dbi:SQLite:dbname=$path", '', '', {
	RaiseError => 1, PrintError => 0, AutoCommit => 1, sqlite_unicode => 0,
	sqlite_open_flags => $write ? 6 : 2,
}) };
my $error = $@;
umask($mask);
# Restore the permission mask before reporting a connection failure.
die $error if (!$db);
$db->do('PRAGMA busy_timeout = 5000');
if ($write) {
	# Refuse unknown schemas instead of silently opening an incompatible
	# store.
	my ($version) = $db->selectrow_array('PRAGMA user_version');
	die "Unsupported controller job schema\n" if ($version > 2);
	$db->do('PRAGMA synchronous = FULL');
	# Erase removed provisioning credentials from freed database pages.
	$db->do('PRAGMA secure_delete = ON');
	$db->do('CREATE TABLE IF NOT EXISTS jobs (id TEXT PRIMARY KEY,
			owner TEXT NOT NULL, resource TEXT NOT NULL, state TEXT NOT NULL,
			created INTEGER NOT NULL, updated INTEGER NOT NULL, record TEXT NOT NULL)');
	$db->do("CREATE UNIQUE INDEX IF NOT EXISTS active_resource ON jobs(resource)
			WHERE state NOT IN ('complete', 'failed', 'cancelled')");
	# Stored password hashes are bound to the form owner and guest username.
	$db->do('CREATE TABLE IF NOT EXISTS credentials (id TEXT PRIMARY KEY,
			owner TEXT NOT NULL, username TEXT NOT NULL, expires INTEGER NOT NULL,
			hash TEXT NOT NULL)');
	$db->do('PRAGMA user_version = 2');
	}
return $db;
}

# write_data(self, callback)
# Serializes SQLite writers with Webmin; binary database contents never enter
# diffs.
# callback(database) runs in a transaction and supplies the scalar return value.
sub write_data
{
my ($self, $callback) = @_;
return $self->lock('jobs.sqlite', sub {
	my $db = $self->connect(1);
	$db->begin_work();
	my $result;
	my $ok = eval { $result = $callback->($db); $db->commit(); 1 };
	my $error = $@;
	# Discard partial updates while preserving the callback's
	# failure message.
	eval { $db->rollback() } if (!$ok);
	$db->disconnect();
	# The connection is closed before the enclosing Webmin lock is released.
	die $error if (!$ok);
	return $result;
	});
}

# save_credential(self, id, owner, username, hash)
# Stores a draft hash with a one-day expiry, without logging its value.
# Later saves purge expired drafts; reads reject them even before removal.
sub save_credential
{
my ($self, $id, $owner, $username, $hash) = @_;
validate_id($id);
return $self->write_data(sub {
	my ($db) = @_;
	$db->do('DELETE FROM credentials WHERE expires < ?', undef, time());
	$db->do('INSERT OR REPLACE INTO credentials VALUES (?, ?, ?, ?, ?)',
		undef, $id, $owner, $username, time()+86400, $hash);
	return 1;
	});
}

# credential(self, id, owner, username)
# Returns a matching unexpired draft, or undef before credentials are
# initialized.
sub credential
{
my ($self, $id, $owner, $username) = @_;
validate_id($id);
my $db = $self->connect(0) || return undef;
my ($exists) = $db->selectrow_array("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'credentials'");
my ($hash) = $exists ? $db->selectrow_array('SELECT hash FROM credentials
		WHERE id = ? AND owner = ? AND username = ? AND expires >= ?',
			undef,
	$id, $owner, $username, time()) : ();
$db->disconnect();
return $hash;
}

# delete_credential(self, id, owner)
# Removes a draft after its hash has been handed to a durable creation job.
sub delete_credential
{
my ($self, $id, $owner) = @_;
validate_id($id);
return $self->write_data(sub {
	$_[0]->do('DELETE FROM credentials WHERE id = ? AND owner = ?', undef,
		$id, $owner);
	return 1;
	});
}

# reserved_resources(job) returns the destination and related reservations.
# Clones reserve the source UUID; restores reserve the preserved UUID and cached
# inspection as well as the destination name. All come from validated requests.
sub reserved_resources
{
my ($job) = @_;
return ($job->{'resource'},
	($job->{'request'}->{'operation'} || '') eq 'restore'
		? ('guest:'.lc($job->{'request'}->{'uuid'} || ''), 'backup-inspect:'.$job->{'request'}->{'inspection'}) : (),
	($job->{'request'}->{'operation'} || '') eq 'clone'
		? ('guest:'.lc($job->{'request'}->{'source_uuid'} || '')) : ());
}

# assert_guest_available(self, uuid, [power_action])
# Unfinished changes block power and further edits until recovery completes.
# power_action defaults to ''; named stop/resume actions allow limited recovery.
sub assert_guest_available
{
my ($self, $uuid, $power_action) = @_;
$power_action ||= '';
my $db = $self->connect(0) || return;
my $rows = $db->selectall_arrayref(
	"SELECT record FROM jobs WHERE resource = ? OR resource LIKE 'vm:%'",
	undef, 'guest:'.lc($uuid));
$db->disconnect();
foreach my $row (@$rows) {
	my $job = convert_from_json($row->[0]);
	# Creation reservations use names; compare their recorded guest UUIDs too.
	next if (lc($job->{'request'}->{'uuid'} || '') ne lc($uuid) &&
		!(($job->{'request'}->{'operation'} || '') eq 'clone' &&
		lc($job->{'request'}->{'source_uuid'} || '') eq lc($uuid)));
	# Failed thaw or pending shutdown recovery may need the user to stop a guest.
	# Active workers and unrelated unfinished operations still block it.
	next if ($power_action =~ /\A(?:shutdown|force_off)\z/ && $job->{'state'} eq 'failed' &&
		($job->{'request'}->{'operation'} || '') =~ /\A(?:snapshot_create|clone|capture_image|backup)\z/ &&
		($job->{'resources'}->{'quiescing'} ||
			($job->{'request'}->{'operation'} || '') =~ /\A(?:clone|capture_image|backup)\z/ &&
			$job->{'resources'}->{'shutdown_requested'} && !$job->{'resources'}->{'shutdown_complete'}) &&
		!$self->busy($job->{'id'}));
	# A guest paused during hotplug may need resuming to acknowledge removal or
	# ballooning. Stopping it also lets recovery finish the saved definition.
	next if ($power_action =~ /\A(?:resume|shutdown|force_off)\z/ &&
		$job->{'state'} eq 'failed' && $job->{'resources'}->{'live'} &&
		!$self->busy($job->{'id'}));
	die "Another operation on this virtual machine is unfinished; open Active Jobs for progress or recovery\n"
		if ($job->{'cleanup_pending'} ||
		$job->{'state'} !~ /\A(?:complete|failed|cancelled)\z/);
	}
}

# get(self, id, [owner])
# Returns a job, or undef if absent; optional ownership limits apply before
# returning.
sub get
{
my ($self, $id, $owner) = @_;
validate_id($id);
my $db = $self->connect(0) || return undef;
my ($json) = $db->selectrow_array('SELECT record FROM jobs WHERE id = ?', undef,
	$id);
$db->disconnect();
# An absent row is distinct from a job hidden by the optional owner filter.
return undef if (!$json);
my $job = convert_from_json($json);
# Do not expose another user's job details through a guessed identifier.
die "Job not found\n" if (defined($owner) && $job->{'owner'} ne $owner);
return $job;
}

# update(self, id, callback)
# Applies a small atomic change while preserving concurrent cancellation
# requests.
# callback(job) edits the current record in place; its return value is ignored.
sub update
{
my ($self, $id, $callback) = @_;
validate_id($id);
return $self->write_data(sub {
	my ($db) = @_;
	my ($json) =
		$db->selectrow_array('SELECT record FROM jobs WHERE id = ?',
		undef, $id);
	# Updates never create a job implicitly or run against an empty record.
	die "Job not found\n" if (!$json);
	my $job = convert_from_json($json);
	$callback->($job);
	$job->{'updated'} = time();
	# Moving committed creation to software setup releases its old reservation.
	$db->do('UPDATE jobs SET resource = ?, state = ?, updated = ?, record = ? WHERE id = ?',
		undef, $job->{'resource'}, $job->{'state'}, $job->{'updated'},
		convert_to_json($job, 0, 1), $id);
	return $job;
	});
}

# list(self, [owner], [active_only])
# Lists recent jobs, or all unfinished jobs for recovery after a restart.
sub list
{
my ($self, $owner, $active) = @_;
my $db = $self->connect(0) || return [];
my @where;
my @args;
if (defined($owner)) {
	# Restrict ordinary users to their own jobs before applying the row
	# limit.
	push(@where, 'owner = ?');
	push(@args, $owner);
	}
# Recovery needs every unfinished job, including old ones outside history.
push(@where, "state NOT IN ('complete', 'failed', 'cancelled')") if ($active);
my $sql = 'SELECT record FROM jobs'.
	(@where ? ' WHERE '.join(' AND ', @where) : '').
	' ORDER BY created DESC'.($active ? '' : ' LIMIT 50');
my $rows = $db->selectall_arrayref($sql, undef, @args);
$db->disconnect();
return [ map { convert_from_json($_->[0]) } @$rows ];
}

# list_recovery(self, [owner])
# Lists failed jobs still holding a reservation, including older history.
sub list_recovery
{
my ($self, $owner) = @_;
my $db = $self->connect(0) || return [];
my $rows = $db->selectall_arrayref("SELECT record FROM jobs WHERE state = 'failed'".
	(defined($owner) ? ' AND owner = ?' : ''), undef,
	(defined($owner) ? ($owner) : ()));
$db->disconnect();
return [ grep { $_->{'cleanup_pending'} }
	map { convert_from_json($_->[0]) } @$rows ];
}

# list_pending(self, [owner])
# Includes retained failures even when they are older than recent job history.
sub list_pending
{
my ($self, $owner) = @_;
return [sort { $b->{'created'} <=> $a->{'created'} }
	@{$self->list($owner, 1)}, @{$self->list_recovery($owner)}];
}

# validate_id(id)
# Keeps identifiers safe for SQLite lookups and Webmin lock filenames.
sub validate_id
{
die "Invalid job ID\n" if (($_[0] || '') !~ /\A[a-f0-9]{32}\z/);
}

1;
