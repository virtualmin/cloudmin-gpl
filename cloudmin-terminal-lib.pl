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

1;
