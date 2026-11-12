# Remove the CLI, collector and cron callbacks when uninstalling this module.
use strict;
use warnings;
require 'server-manager-lib.pl';

# module_uninstall() stops statistics and removes the CLI and cron callbacks.
sub module_uninstall
{
# Stop the collector before deleting its executable or module state.
require './cloudmin-statistics-lib.pl';
install_statistics_service(1);
# Do not leave a scheduled callback pointing at a removed module.
foreign_require('webmincron');
foreach my $cron (webmincron::list_webmin_crons()) {
	webmincron::delete_webmin_cron($cron)
		if ($cron->{'module'} eq 'server-manager' &&
		    $cron->{'func'} =~ /\A(?:check_cloudmin_license|run_cloudmin_notifications)\z/);
	}
my $path = '/usr/sbin/cloudmin';
# Leave absent commands, nonregular files and administrator-created links alone.
return if (!-f $path || -l $path);
my $contents = read_file_contents($path);
# Remove only a file carrying this installer's exact ownership marker.
unlink_file($path)
	if (
		$contents =~ /^# Cloudmin command-line wrapper; installed by server-manager\/postinstall\.pl$/m);
}

1;
