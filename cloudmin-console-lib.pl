# Guest consoles use Webmin's session-bound WebSocket proxy.
use strict;
use warnings;
use File::Basename ();
use Cwd ();
# Load ACL helpers once, even when callers use different paths.
require(Cwd::abs_path(File::Basename::dirname(__FILE__).'/cloudmin-access-lib.pl'));
our (%config, %text, $remote_user, $module_name, $module_config_directory,
     $module_var_directory, $module_root_directory);

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

1;
