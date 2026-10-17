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

1;
