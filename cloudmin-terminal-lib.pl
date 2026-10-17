# Browser SSH terminals share Webmin's PTY and authenticated WebSocket APIs.
use strict;
use warnings;
use File::Basename ();
use Cwd ();
# Load ACL helpers once, even when callers use different paths.
require(Cwd::abs_path(File::Basename::dirname(__FILE__).'/cloudmin-access-lib.pl'));
use Digest::SHA qw(sha256_hex);
our (%text, %config, $remote_user, $module_root_directory,
     $module_var_directory, $module_config_directory, $module_name);

# terminal_port_key(uuid) validates and normalizes the saved port's guest ID.
sub terminal_port_key
{
my ($uuid) = @_;
# Restrict keys to UUIDs before using them in preference files or paths.
die "Invalid virtual machine ID\n" if (!defined($uuid) || ref($uuid) ||
	$uuid !~ /\A[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}\z/i);
return lc($uuid);
}

# get_terminal_port(uuid) returns the port from the last successful SSH login.
# Defaults to 22. Ports are shared by all users and keyed by guest UUID.
sub get_terminal_port
{
my ($uuid) = @_;
my $key = terminal_port_key($uuid);
my %ports;
read_file("$module_var_directory/ssh-ports", \%ports);
my $port = $ports{$key} || '';
# Invalid or missing saved values must not become SSH arguments.
return $port =~ /\A\d{1,5}\z/ && $port > 0 && $port <= 65535 ? 0+$port : 22;
}

# save_terminal_port(uuid, port) remembers a port after SSH authenticates.
# The supervisor supplies its validated destination, never guest output.
sub save_terminal_port
{
my ($uuid, $port) = @_;
# Saving a successful login still requires the caller's current terminal grant.
die "$text{'terminal_readonly'}\n" if (is_readonly_mode());
require_access('terminal', $uuid);
my $key = terminal_port_key($uuid);
# Reject invalid ports even when the caller already parsed the form.
die "Invalid SSH port\n" if (!defined($port) || ref($port) ||
	$port !~ /\A\d{1,5}\z/ || $port < 1 || $port > 65535);
my $file = "$module_var_directory/ssh-ports";
# Catch native file errors so cleanup runs and callers can report the failure.
local $main::error_must_die = 1;
my $locked;
my $ok = eval {
	$locked = lock_file($file);
	# A failed or nested lock must not permit a write to shared state.
	die "Cannot lock saved SSH ports: $!\n" if (!$locked);
	# Preserve other guests' ports when simultaneous logins finish.
	my %ports;
	read_file($file, \%ports);
	$ports{$key} = 0+$port;
	write_file($file, \%ports);
	chmod(0600, $file) || die "Cannot protect saved SSH ports: $!\n";
	1;
	};
my $error = $@;
# Release the shared file before reporting a write or permission failure.
unlock_file($file) if ($locked);
die $error if (!$ok);
}

# terminal_login_file(uuid) returns the current Webmin user's attempt file.
# Escape the username so it cannot add path components.
sub terminal_login_file
{
my ($uuid) = @_;
return "$module_var_directory/ssh-login-".terminal_port_key($uuid).
	'-'.urlize($remote_user);
}

# get_terminal_login(uuid) reads this user's last login settings and outcome.
# Returns an empty hash reference when no attempt has been saved.
sub get_terminal_login
{
my ($uuid) = @_;
require_access('terminal', $uuid);
my %login;
read_file(terminal_login_file($uuid), \%login);
return \%login;
}

# save_terminal_login(uuid, attempt, state, [request]) starts or updates a login.
# Pending and failed attempts pause automatic connection on later visits.
# request is required for pending and must come from parse_terminal_request.
# connected and failed update only the matching attempt for this Webmin user.
sub save_terminal_login
{
my ($uuid, $attempt, $state, $request) = @_;
# Detached callbacks must not save settings after the grant is removed.
die "$text{'terminal_readonly'}\n" if (is_readonly_mode());
require_access('terminal', $uuid);
# Only generated attempt IDs and known states belong in this file.
die "Invalid SSH connection state\n" if (
	($attempt || '') !~ /\A[a-f0-9]{32}\z/ ||
	($state || '') !~ /\A(?:pending|connected|failed)\z/);
my $file = terminal_login_file($uuid);
# Lock this account's guest state while starting or updating an attempt.
local $main::error_must_die = 1;
my $locked;
my $ok = eval {
	$locked = lock_file($file);
	# Failed acquisition leaves the caller's lock and saved state untouched.
	die "Cannot lock SSH connection settings: $!\n" if (!$locked);
	my %login;
	read_file($file, \%login);
	if ($state eq 'pending') {
		# Store only connection fields, never keys, passwords or session cookies.
		%login = (map { $_ => $request->{$_} } qw(username auth address port));
		$login{'attempt'} = $attempt;
		}
	if ($login{'attempt'} && $login{'attempt'} eq $attempt) {
		# Late results from an older terminal cannot change a newer attempt.
		$login{'state'} = $state;
		write_file($file, \%login);
		chmod(0600, $file) || die "Cannot protect SSH connection settings: $!\n";
		}
	1;
	};
my $error = $@;
# Failed writes must not leave later attempts waiting for this file's lock.
unlock_file($file) if ($locked);
die $error if (!$ok);
}

# list_terminal_addresses(vm)
# Returns usable guest addresses, excluding loopback and unscoped link-local
# IPs.
sub list_terminal_addresses
{
my ($vm) = @_;
return unique(grep {
	(check_ipaddress($_) && $_ !~ /\A(?:0\.|127\.|169\.254\.)/ &&
		$_ ne '255.255.255.255') ||
	(/:/ && check_ip6address($_) &&
	$_ !~ /\A(?:::1|::|fe[89ab][0-9a-f]:.*)\z/i)
	} map { $_->{'address'} || '' } @{$vm->{'addresses'} || []});
}

# get_terminal_key(vm)
# Finds only the key belonging to this guest's recorded creation job.
sub get_terminal_key
{
my ($vm) = @_;
# A remote libvirt connection must not borrow this host's local VM keys.
return undef if (($config{'libvirt_uri'} ||
	'qemu:///system') ne 'qemu:///system');
# Imported or externally created guests may have no managed key record.
return undef if (!$vm->{'cloudmin'}->{'job'});
return get_ssh_keys()->find($vm->{'uuid'}, $vm->{'cloudmin'}->{'job'});
}

# parse_terminal_request(vm, input)
# Limits SSH to a running guest's current IPs; form values cannot add SSH
# options.
sub parse_terminal_request
{
my ($vm, $input) = @_;
# SSH requires its own VM grant; read-only mode blocks interactive sessions.
die "$text{'terminal_readonly'}\n" if (is_readonly_mode());
require_access('terminal', $vm->{'uuid'});
# Only running states can answer a new SSH connection.
die "$text{'terminal_stopped'}\n"
	if ($vm->{'state'} !~ /\A(?:running|blocked)\z/);
my @addresses = list_terminal_addresses($vm);
my $address = $input->{'address'} || '';
my $username = $input->{'username'} || '';
my $port = $input->{'port'} || '';
# Constrain the destination to this guest and reject injected SSH options.
die "$text{'terminal_invalid'}\n" if (
	!check_vm_username($username) ||
	$port !~ /\A\d{1,5}\z/ || $port < 1 || $port > 65535 ||
	!grep { $_ eq $address } @addresses);
my $auth = $input->{'auth'} || 'password';
# The form may choose only the two authentication modes exposed in the UI.
die "$text{'terminal_auth_invalid'}\n"
	if (ref($auth) || $auth !~ /\A(?:key|password)\z/);
# Password sessions never need access to the guest's stored private key.
my $key = get_terminal_key($vm) if ($auth eq 'key');
# Do not silently fall back to passwords after selecting a missing key.
die "$text{'terminal_key_missing'}\n" if ($auth eq 'key' && !$key);
return { uuid => $vm->{'uuid'}, username => $username, auth => $auth,
	key => $key,
	address => $address, port => 0 + $port };
}

# build_terminal_command(request, unit_id, webmin_user, credential_path)
# Returns a command that runs SSH under a temporary user ID. Each Webmin
# user/guest pair retains its own known host keys. Command escapes, forwarding
# and host credentials are unavailable; the login marker runs in this sandbox.
sub build_terminal_command
{
my ($request, $id, $user, $credential) = @_;
# Unit names come from generated identifiers, never terminal form fields.
die "Invalid terminal identifier\n" if ($id !~ /\A[a-f0-9]{32}\z/);
die "Terminal session credential is required\n" if (!$credential);
my $identity = substr(sha256_hex($user.':'.$request->{'uuid'}), 0, 24);
# Retain accepted guest host keys separately for each Webmin user and guest.
my $home = '/var/lib/cloudmin-ssh/'.$identity;
my @properties = (
	'DynamicUser=yes', "User=cmssh-$identity",
	"StateDirectory=cloudmin-ssh/$identity",
	'StateDirectoryMode=0700', "WorkingDirectory=$home", 'UMask=0077',
	'NoNewPrivileges=yes', 'CapabilityBoundingSet=', 'AmbientCapabilities=',
	'ProtectSystem=strict', 'ProtectHome=yes', 'PrivateTmp=yes',
	'PrivateDevices=yes',
	'ProtectProc=invisible', 'ProtectKernelTunables=yes',
	'ProtectKernelModules=yes',
	'ProtectKernelLogs=yes', 'ProtectControlGroups=yes',
	'RestrictNamespaces=yes',
	'RestrictSUIDSGID=yes', 'RestrictRealtime=yes', 'LockPersonality=yes',
	'RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX',
	'KeyringMode=private',
	'TemporaryFileSystem=/run:ro',
	# OpenSSH needs the dynamic user's passwd entry, not host control
	# sockets.
	'BindReadOnlyPaths=-/run/systemd/userdb',
	'InaccessiblePaths=-/etc/webmin -/var/webmin -/etc/libvirt -/var/lib/libvirt',
	'KillMode=control-group', 'TimeoutStopSec=5', 'RuntimeMaxSec=8h',
	'TasksMax=16', 'MemoryMax=256M', 'LimitCORE=0', 'LimitFSIZE=1048576',
	'LoadCredential=session:'.$credential,
);
# systemd exposes only this VM's private key inside the terminal sandbox.
my $key = ($request->{'auth'} || 'password') eq 'key';
# Recheck the credential before constructing a service that would lack it.
die "$text{'terminal_key_missing'}\n" if ($key && !$request->{'key'});
# systemd copies the selected key into the service's credential directory.
push(@properties, 'LoadCredential=ssh-key:'.$request->{'key'}) if ($key);
# Keep key and password authentication separate; neither borrows host identities.
my @auth = $key
	? ('-o', 'PubkeyAuthentication=yes', '-o', 'IdentitiesOnly=yes',
	   '-o', 'PreferredAuthentications=publickey', '-o',
	'PasswordAuthentication=no',
	   '-o', 'KbdInteractiveAuthentication=no')
	: ('-o', 'PubkeyAuthentication=no', '-o',
	'PreferredAuthentications=keyboard-interactive,password');
return ('/usr/bin/systemd-run', '--quiet', '--wait', '--collect', '--pipe',
	'--no-ask-password', '--service-type=exec',
	"--unit=cloudmin-terminal-$id",
	(map { ('--property', $_) } @properties),
	'--setenv=PATH=/usr/bin:/bin', '--setenv=TERM=xterm-256color',
	"--setenv=HOME=$home",
	($key ? ('--setenv=CLOUDMIN_TERMINAL_KEY=1') : ()),
	# Both WebSocket parsing and the SSH PTY live inside the same sandbox.
	'/usr/bin/python3', "$module_root_directory/relay-sockets.py",
	'receive', 1, $^X, "$module_root_directory/terminal-relay.pl",
	'/usr/bin/ssh', '-F', '/dev/null', '-tt', '-o', 'EscapeChar=none',
	'-o', 'ClearAllForwardings=yes', '-o', 'ForwardAgent=no', '-o',
	'ForwardX11=no',
	'-o', 'IdentityAgent=none', @auth,
	'-o', 'StrictHostKeyChecking=ask', '-o',
	'GlobalKnownHostsFile=/dev/null',
	'-o', "UserKnownHostsFile=$home/known_hosts", '-o',
	"HostKeyAlias=cloudmin-$request->{uuid}",
	'-o', 'ConnectTimeout=15', '-o', 'ServerAliveInterval=30', '-o',
	'ServerAliveCountMax=3',
	'-p', $request->{'port'}, '-l', $request->{'username'},
	$request->{'address'});
}

1;
