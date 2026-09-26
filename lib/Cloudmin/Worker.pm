package Cloudmin::Worker;

# The controller retains job records and libvirt access. A fresh systemd service
# processes each task under its own temporary UID, with no inherited
# credentials.
use strict;
use warnings;
use JSON::PP qw(encode_json decode_json);
use File::Path qw(make_path remove_tree);
use File::Basename qw(dirname);
use Cwd qw(abs_path);
use Fcntl qw(:DEFAULT O_NOFOLLOW);
use Errno qw(EEXIST EXDEV);
use IPC::Open3;
use IO::Select;
use Symbol qw(gensym);
use POSIX qw(WNOHANG);
use Time::HiRes qw(time);

my $ROOT = '/var/lib/private/cloudmin-workers';
my $PUBLIC = '/var/lib/cloudmin-workers';
my %TIMEOUT = (image => 3600, local_image => 3600, convert => 3600, inspect => 180, clone_prepare => 900,
	backup_archive => 7200, backup_transfer => 7200, backup_host_key => 30,
	seed => 60, keys => 30, keypair => 30, size => 20, software => 7500);
my $SMALL_FILE = 16 * 1024**2;
my $RESERVE_BYTES = 256 * 1024**2;

# byte_limit(value)
# Accepts positive byte budgets representable exactly in controller and UI JSON.
sub byte_limit
{
my ($value) = @_;
die "Invalid image byte limit\n" if (!defined($value) || ref($value) ||
	$value !~ /\A[1-9]\d{0,15}\z/ || $value > 9007199254740991);
return 0 + $value;
}

# new(class)
# Creates a runner without touching the host during ordinary page rendering.
sub new
{
return bless({}, $_[0]);
}

# generate_id()
# Allocates a private task identifier independent of all user input.
sub generate_id
{
open(my $fh, '<', '/dev/urandom') || die "Cannot allocate image worker\n";
read($fh, my $bytes, 16) == 16 || die "Cannot allocate image worker\n";
return unpack('H*', $bytes);
}

# path(id)
# Checks a task ID's format before deriving its private directory path.
sub path
{
my ($id) = @_;
# Reject traversal and arbitrary service names before using the
# identifier.
die "Invalid image worker identifier\n" if (($id || '') !~ /\A[a-f0-9]{32}\z/);
return "$ROOT/$id";
}

# private_root()
# Requires root-owned, private parents before preparing input for a worker.
sub private_root
{
# The isolation policy depends on Linux service and namespace support.
die "Image workers require Linux and systemd\n"
	if ($^O ne 'linux' || !-x '/usr/bin/systemd-run');
# Unprivileged callers must not prepare directories for privileged
# claims.
die "Only the Cloudmin controller may start image workers\n"
	if ($< != 0 || $> != 0);
for my $path ('/var/lib/private', $ROOT) {
	# Concurrent imports may both initialize these shared parents.
	mkdir($path, 0700) || $! == EEXIST ||
		die "Cannot create worker directory: $!\n" if (!-e $path);
	my @s = lstat($path);
	# Existing parents are trusted only if other users cannot
	# replace inputs.
	die "Unsafe worker directory: $path\n"
		if (!@s || !-d _ || -l _ || $s[4] != 0 || ($s[2] & 0077));
	}
}

# command(self, task, id, [limit])
# Builds a fixed sandbox policy. Requests cannot choose users or unit
# properties. limit is the controller's byte budget, defaulting to 16 MiB.
sub command
{
my ($self, $task, $id, $limit) = @_;
path($id);
my $file_limit = byte_limit(defined($limit) ? $limit : $SMALL_FILE);
# Small images still need space for bounded logs, manifests and request data.
$file_limit = $SMALL_FILE if ($file_limit < $SMALL_FILE);
# Resource limits exist only for the supported task types.
die "Unknown image worker task\n" if (!exists($TIMEOUT{$task}));
my $helper = abs_path(dirname(__FILE__).'/../../worker.pl');
# Resolve the packaged worker before handing its path to systemd.
die "Image worker program is missing\n" if (!$helper);
my $guestfs = $task eq 'inspect' || $task eq 'clone_prepare';
my @properties = (
	'DynamicUser=yes', "StateDirectory=cloudmin-workers/$id",
	'StateDirectoryMode=0700',
	"WorkingDirectory=$PUBLIC/$id", 'UMask=0077', 'NoNewPrivileges=yes',
	'CapabilityBoundingSet=', 'AmbientCapabilities=',
	'ProtectSystem=strict',
	'ProtectHome=yes', 'PrivateTmp=yes', 'ProtectProc=invisible',
	# Supermin reads module files to build its appliance; loading modules
	# stays forbidden.
	'ProtectKernelTunables=yes',
	'ProtectKernelModules='.($guestfs ? 'no' : 'yes'),
	'SystemCallFilter=~@module', 'ProtectKernelLogs=yes',
	'ProtectControlGroups=yes', 'RestrictNamespaces=yes',
	'RestrictSUIDSGID=yes',
	'LockPersonality=yes', 'RestrictRealtime=yes', 'KeyringMode=private',
	'TemporaryFileSystem=/run:ro',
	# Keep user lookup and resolver data available, without host control
	# sockets.
	'BindReadOnlyPaths=-/run/systemd/userdb -/run/systemd/resolve/resolv.conf '.
		'-/run/systemd/resolve/stub-resolv.conf -/run/NetworkManager/resolv.conf '.
		'-/run/NetworkManager/no-stub-resolv.conf',
	'InaccessiblePaths=-/etc/webmin -/var/webmin -/etc/libvirt -/var/lib/libvirt',
	'StandardInput=null', "StandardOutput=append:$ROOT/$id/events",
	"StandardError=append:$ROOT/$id/errors",
	'KillMode=control-group', 'TimeoutStopSec=5',
	"RuntimeMaxSec=$TIMEOUT{$task}",
	'TasksMax=64', 'MemoryMax='.($guestfs ? '2G' : '512M'), 'LimitCORE=0',
	'LimitFSIZE='.$file_limit,
	# Network tasks include downloads, guest setup and backup
	# transfers/probes.
	'PrivateNetwork='.($task eq 'image' || $task eq 'size' || $task eq 'software' || $task eq 'backup_transfer' || $task eq 'backup_host_key' ? 'no' : 'yes'),
	'PrivateDevices='.($guestfs ? 'no' : 'yes'),
);
# DynamicUser always isolates /tmp. Give host-file imports read-only views
# at fixed paths; ordinary Unix permissions still apply to every component.
push(@properties,
	'BindReadOnlyPaths=/tmp:/run/cloudmin-host-tmp /var/tmp:/run/cloudmin-host-var-tmp')
	if ($task eq 'local_image');
# The inspection appliance gets KVM access, but no libvirt group or sockets.
push(@properties, 'DevicePolicy=closed', 'DeviceAllow=/dev/kvm rw',
	'SupplementaryGroups=kvm') if ($guestfs);
# GNU tar can need openat2 calls blocked by this sandbox's SUID
# protection.
# Use bsdtar for supermin's extraction without changing the host's tar.
push(@properties, 'BindReadOnlyPaths=/usr/bin/bsdtar:/usr/bin/tar')
	if ($guestfs);
my @environment;
# Ubuntu protects /boot kernels from ordinary users. Point supermin at the
# staged copy of the running kernel and its matching installed modules.
if ($guestfs) {
	my $release = kernel_release();
	@environment = ("--setenv=SUPERMIN_KERNEL=$PUBLIC/$id/appliance-kernel",
		"--setenv=SUPERMIN_MODULES=/lib/modules/$release",
		"--setenv=SUPERMIN_KERNEL_VERSION=$release");
	}
return ('/usr/bin/systemd-run', '--quiet', '--wait', '--collect',
	'--no-ask-password',
	'--service-type=exec', "--unit=cloudmin-worker-$id",
	(map { ('--property', $_) } @properties),
	'--setenv=PATH=/usr/sbin:/usr/bin:/sbin:/bin', '--setenv=LANG=C',
	'--setenv=HOME='.$PUBLIC.'/'.$id, @environment, '/usr/bin/perl',
	$helper);
}

# kernel_release()
# Uses the host kernel identity, never a guest image or request parameter.
sub kernel_release
{
my $release = (POSIX::uname())[2];
# The release becomes a path component and a service environment value.
die "Cannot determine the host kernel version\n"
	if ($release !~ /\A[a-zA-Z0-9._+-]+\z/);
return $release;
}

# stage_kernel(directory)
# Gives the temporary worker its own kernel without changing host permissions.
sub stage_kernel
{
my ($work) = @_;
my $release = kernel_release();
# Supermin needs modules that match the appliance kernel.
die "Install modules for the running kernel $release, or reboot after updating the kernel\n"
	if (!-d "/lib/modules/$release");
my ($source) = grep { -f $_ && !-l $_ }
	("/boot/vmlinuz-$release", "/lib/modules/$release/vmlinuz");
# An upgrade may remove the running kernel before reboot.
die "Install the running kernel $release, or reboot after updating the kernel\n"
	if (!$source);
my @s = lstat($source);
# The appliance must not boot a kernel writable by an unprivileged user.
die "Unsafe host kernel permissions\n" if ($s[4] != 0 || ($s[2] & 0022));
copy_file($source, "$work/appliance-kernel");
}

# write_data(path, data)
# Creates input files privately before systemd gives this directory to the
# worker.
sub write_data
{
my ($path, $data) = @_;
sysopen(my $fh, $path, O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW, 0600) ||
	die "Cannot prepare worker input: $!\n";
binmode($fh);
print($fh $data) && close($fh) || die "Cannot write worker input: $!\n";
}

# copy_file(source, destination, [limit])
# Copies regular files or managed LVM bytes without parsing disk formats.
# Regular files use reflinks/sparse copying; LVs become private sparse files.
# limit optionally bounds inputs or outputs to their controller-issued budget.
sub copy_file
{
my ($source, $destination, $limit) = @_;
byte_limit($limit) if (defined($limit));
# Managed block disks are copied as bytes before entering the sandbox.
if (-b $source) {
	require(dirname(__FILE__).'/LVM.pm');
	return Cloudmin::LVM::copy_to_file($source, $destination, $limit);
	}
my @s = lstat($source);
# Reject special files before applying the separate byte budget.
die "Worker input must be a regular file\n"
	if (!@s || !-f _ || -l _);
# The worker and Webmin stores can live on different filesystems. Reserve
# space for a full copy before cp can consume the host's remaining storage.
# Report a storage shortage before a budget clamped to that same free space.
die "Not enough free space for private image processing\n"
	if (free_space(dirname($destination)) < $s[7] + $RESERVE_BYTES);
die "Worker input exceeds the image byte limit\n"
	if (defined($limit) && $s[7] > $limit);
system('/usr/bin/cp', '--reflink=auto', '--sparse=always', '--', $source,
	$destination) == 0
	|| die "Cannot copy image into the private worker directory\n";
chmod(0600, $destination) || die "Cannot protect worker input\n";
}

# free_space(directory)
# Reads filesystem capacity without loading Webmin configuration or parsing a
# disk.
sub free_space
{
open(my $fh, '-|', '/usr/bin/stat', '-f', '-c', '%a:%S', '--', $_[0])
	|| die "Cannot check worker staging space\n";
my $space = <$fh>;
close($fh) || die "Cannot check worker staging space\n";
my ($blocks, $size) = ($space || '') =~ /\A(\d+):(\d+)\s*\z/;
# An unreadable capacity must not be mistaken for enough free space.
die "Invalid worker staging space\n" if (!defined($blocks));
return $blocks * $size;
}

1;
