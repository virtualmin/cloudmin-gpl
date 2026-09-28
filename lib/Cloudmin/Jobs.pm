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

# dependencies()
# Loads the SQLite driver only when the controller job store is used.
sub dependencies
{
require DBI;
require DBD::SQLite;
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

1;
