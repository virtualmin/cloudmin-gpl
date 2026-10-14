# Guest consoles use Webmin's session-bound WebSocket proxy.
use strict;
use warnings;
use File::Basename ();
use Cwd ();
# Load ACL helpers once, even when callers use different paths.
require(Cwd::abs_path(File::Basename::dirname(__FILE__).'/cloudmin-access-lib.pl'));
our (%config, %text, $remote_user, $module_name, $module_config_directory,
     $module_var_directory, $module_root_directory);

# build_console_command(id, credential_path, [mode])
# Returns systemd-run arguments for a relay with a listener, guest byte socket
# and private session credential. id is a generated 32-character hex token.
# mode defaults to graphical; serial uses a shorter browser connection deadline.
sub build_console_command
{
my ($id, $credential, $mode) = @_;
# Reject unknown console modes before building the service command.
$mode = console_mode($mode);
# Reject invalid unit names or missing credentials before constructing the unit.
die "Invalid console identifier\n" if ($id !~ /\A[a-f0-9]{32}\z/);
die "Console session credential is required\n" if (!$credential);
# Keep guest traffic away from host credentials and management sockets.
my @properties = (
	'DynamicUser=yes', 'NoNewPrivileges=yes', 'UMask=0077',
	'CapabilityBoundingSet=', 'AmbientCapabilities=',
	'ProtectSystem=strict', 'ProtectHome=yes', 'PrivateTmp=yes',
	'PrivateDevices=yes', 'PrivateNetwork=yes', 'ProtectProc=invisible',
	'ProtectKernelTunables=yes', 'ProtectKernelModules=yes',
	'ProtectKernelLogs=yes', 'ProtectControlGroups=yes',
	'RestrictNamespaces=yes', 'RestrictSUIDSGID=yes',
	'RestrictRealtime=yes', 'LockPersonality=yes', 'KeyringMode=private',
	'TemporaryFileSystem=/run:ro',
	'InaccessiblePaths=-/etc/webmin -/var/webmin -/etc/libvirt -/var/lib/libvirt',
	'KillMode=control-group', 'TimeoutStopSec=5', 'RuntimeMaxSec=8h',
	'TasksMax=8', 'MemoryMax=256M', 'LimitCORE=0', 'LimitFSIZE=1048576',
	'LoadCredential=session:'.$credential,
);
# Pass the mode so the relay can apply the serial startup deadline.
return ('/usr/bin/systemd-run', '--quiet', '--wait', '--collect', '--pipe',
	'--no-ask-password', '--service-type=exec', "--unit=cloudmin-console-$id",
	(map { ('--property', $_) } @properties), '--setenv=PATH=/usr/bin:/bin',
	'/usr/bin/python3', "$module_root_directory/relay-sockets.py",
	'receive', 2, $^X, "$module_root_directory/console-relay.pl", $mode);
}

# console_mode([mode]) validates the console type, defaulting to graphical.
sub console_mode
{
my ($mode) = @_;
# Existing links and API callers omit the mode and still open VNC.
$mode = 'graphical' if (!defined($mode) || $mode eq '');
# Accept only the two supported backends before constructing a launch command.
die "Invalid console type\n" if ($mode !~ /\A(?:graphical|serial)\z/);
return $mode;
}

# check_console(vm, [mode])
# Checks interactive access and the selected device before allocating a route.
# mode defaults to graphical; both modes use the same console grant.
sub check_console
{
my ($vm, $mode) = @_;
# Keyboard access requires its own VM grant and is blocked in read-only mode.
die "$text{'console_readonly'}\n" if (is_readonly_mode());
require_access('console', $vm->{'uuid'});
$mode = console_mode($mode);
# Webmin's proxy requires the Terminal module; the relay matches its key check.
die "$text{'terminal_unavailable'}\n" if (!foreign_check('xterm'));
# The proxy opens guest devices through this host's libvirt connection.
die "$text{'console_local'}\n" if ($config{'libvirt_uri'} ne 'qemu:///system');
# A stopped domain has no live console stream to attach to.
die "$text{'console_stopped'}\n" if (!$vm->{'active'});
if ($mode eq 'serial') {
	# A serial connection needs a PTY device, but no display or guest network.
	die "$text{'console_serial_missing'}\n" if (!$vm->{'serial_console'});
	}
else {
	# The graphical browser client speaks VNC, not other display protocols.
	die "$text{'console_missing'}\n"
		if (($vm->{'graphics'}->{'type'} || '') ne 'vnc');
	}
}

1;
