# Install the host command when Webmin installs or upgrades this module.
use strict;
use warnings;
require 'server-manager-lib.pl';
our ($config_directory, $var_directory, $root_directory,
     $module_root_directory);

# cloudmin_cli_shell_quote(value) quotes configured paths for a POSIX shell.
sub cloudmin_cli_shell_quote
{
my ($value) = @_;
$value =~ s/'/'"'"'/g;
return "'$value'";
}

# cloudmin_cli_wrapper(config, var, root, module, perl) returns a shell wrapper.
# Arguments are Webmin config, state, root and module directories, then the Perl
# path. Generation is separate so tests never install a workstation command.
sub cloudmin_cli_wrapper
{
my ($config, $var, $root, $module, $perl) =
	map { cloudmin_cli_shell_quote($_) } @_;
return <<EOF_WRAPPER;
#!/bin/sh
# Cloudmin command-line wrapper; installed by server-manager/postinstall.pl
WEBMIN_CONFIG=$config
WEBMIN_VAR=$var
PERLLIB=$root
export WEBMIN_CONFIG WEBMIN_VAR PERLLIB
# Reject nonroot use before loading the installed module.
if [ "\$(id -u)" != 0 ]; then
    echo 'cloudmin must be run as root' >&2
    exit 2
fi
# Use the module directory while preserving every argument verbatim.
cd $module || exit 1
exec $perl cli.pl "\$\@"
EOF_WRAPPER
}

# module_install() installs the CLI wrapper, collector and scheduled callbacks.
sub module_install
{
die "Install the Cloudmin command on its Linux host as root\n"
	unless $^O eq 'linux' && $< == 0;
# Replace the wrapper atomically so upgrades cannot leave a partial script.
my $path = '/usr/sbin/cloudmin';
local *CLOUDMIN_CLI;
my $fh = \*CLOUDMIN_CLI;
open_tempfile($fh, '>'.$path);
print_tempfile($fh, cloudmin_cli_wrapper($config_directory, $var_directory,
					 $root_directory,
					 $module_root_directory,
					 get_perl_path()));
close_tempfile($fh);
# Keep the command executable and owned by root after installation.
set_ownership_permissions(0, 0, 0755, $path);
# Install the Pro check once; GPL hosts need no licensing cron.
setup_cloudmin_license_check();
# Keep live collection running even when history recording is turned off.
require "$module_root_directory/cloudmin-statistics-lib.pl";
install_statistics_service();
# Notifications run independently of history and browser sessions.
ensure_notification_schedule();
}

1;
