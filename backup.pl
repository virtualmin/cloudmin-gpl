#!/usr/local/bin/perl
# Execute a single backup for multiple virtual systems

$main::no_acl_check++;
require './server-manager-lib.pl';

# Parse command line
while(@ARGV) {
	$a = shift(@ARGV);
	if ($a eq "--id") {
		$backupid = shift(@ARGV);
		}
	else {
		&usage();
		}
	}
$backupid || &usage();
$backup = &get_backup($backupid);
$backup || &usage("No backup with ID $backupid found");

# Execute it, capturing the output
&obtain_lock_server(\@servers);
# XXX
&release_lock_server(\@servers);

# Send email with results
# XXX

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Executes a single scheduled backup.\n";
print "\n";
print "backup.pl --id number\n";
exit(1);
}

