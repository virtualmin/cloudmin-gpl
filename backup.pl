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
($backup) = grep { $_->{'id'} eq $backupid } &list_backups();
$backup || &usage("No backup with ID $backupid found");
@servers = &get_backup_servers($backup);

# Execute it, capturing the output
$capture_print = undef;
&set_all_capture_text_print();
&obtain_lock_server(\@servers);
$rv = &execute_backup($backup);
&release_lock_server(\@servers);

# Check if any failed
$failcount = 0;
foreach $s (@servers) {
	if (!$rv->{$s->{'id'}} ||
	    !$rv->{$s->{'id'}}->{'ok'}) {
		$failcount++;
		}
	}

# Create status summary
$fmt = "%-20.20s %-45.45s %-10.10s\n";
$report = sprintf($fmt, "System", "Result", "Size");
$report .= sprintf($fmt, "-" x 20, "-" x 45, "-" x 10);
foreach $s (@servers) {
	$r = $rv->{$s->{'id'}};
	if (!$r) {
		$report .= sprintf($fmt, $s->{'host'}, "UNKNOWN", "-");
		}
	elsif ($r->{'ok'}) {
		$report .= sprintf($fmt, $s->{'host'}, "OK",
					 &nice_size($r->{'size'}));
		}
	else {
		$report .= sprintf($fmt, $s->{'host'}, $r->{'msg'}, "-");
		}
	}

# Send email with results
if ($backup->{'email'} &&
    ($failcount || $backup->{'always'})) {
	&foreign_require("mailboxes");
	$dstr = $backup->{'dest'} ?
			&nice_backup_destination($backup->{'dest'}) :
			$text{'brun_hostdest'};
	&mailboxes::send_text_mail(
		&get_global_from_address($servers[0]),
		$backup->{'email'},
		undef,
		&text($failcount ? 'brun_fsubject' : 'brun_subject',
		      scalar(@servers), $dstr),
		$report."\n".$capture_print,
		);
	}

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Executes a single scheduled backup.\n";
print "\n";
print "backup.pl --id number\n";
exit(1);
}

