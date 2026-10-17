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

1;
