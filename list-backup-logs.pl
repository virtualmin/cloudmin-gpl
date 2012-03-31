#!/usr/local/bin/perl

=head1 list-backup-logs.pl

Output a list of previously run backups.

Every time Cloudmin runs a backup (either on schedule, via the command line
or via the web UI), it is logged. This command allows you to display entries
from the backup log for either a single system (selected with the C<--host>
flag followed by a hostname), backups made by some system owner (using the
C<--owner> flag), or all backups.

Output can be further limited using the C<--start> and C<--end> flags, followed
by either a date formatted like yyyy-mm-dd, or a number of days in the past
like I<-7>. 

By default, the output is in a human-readable table format. However, you can
switch to a more parsable format with the C<--multiline> flag.

=head1 Example usage

  cloudmin list-backup-logs --start -1
  Date/time         Destination                                      Status    
  ----------------- ------------------------------------------------ --------
  21/Aug/2009 14:00 master:/backup/cloudmin/openvzgpl.home.tar.gz    160.42 MB 
  21/Aug/2009 13:56 master:/backup/cloudmin/openvzgpl.home.tar.gz    FAILED    
  21/Aug/2009 13:47 master:/backup/cloudmin/openvzgpl.home.tar.gz    FAILED    
  21/Aug/2009 13:43 master:/backup/cloudmin/openvzgpl.home.tar.gz    160.42 MB 
  21/Aug/2009 13:42 ftp:user:pass@backup.home/backup/cloudmin/ope    78.83 MB  
  20/Aug/2009 23:38 ftp:user:pass@backup.home/backup/cloudmin/ope    160.30 MB 
  20/Aug/2009 23:32 master:/backup/cloudmin/openvzgpl.home.tar.gz    160.42 MB 

=cut

package server_manager;
$main::no_acl_check++;
$ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
$ENV{'WEBMIN_VAR'} ||= "/var/webmin";
if ($0 =~ /^(.*)\/[^\/]+$/) {
	chdir($pwd = $1);
	}
else {
	chop($pwd = `pwd`);
	}
$0 = "$pwd/list-backup-logs.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";

# Parse command line
while(@ARGV > 0) {
	my $a = shift(@ARGV);
	if ($a eq "--multiline") {
		$multi = 1;
		}
	elsif ($a eq "--host") {
		$servername = shift(@ARGV);
		$server = &get_managed_server_by("host", $servername);
		$server || &usage("No system with hostname $servername found");
		}
	elsif ($a eq "--owner") {
		$ownername = shift(@ARGV);
		}
	elsif ($a eq "--start") {
		$start = &date_to_time(shift(@ARGV));
		}
	elsif ($a eq "--end") {
		$end = &date_to_time(shift(@ARGV));
		}
	else {
		&usage("Unknown parameter $a");
		}
	}

# Get matching backup logs
%servermap = map { $_->{'id'}, $_ } &list_managed_servers();
if ($server) {
	# One specific server
	&can_action_usage($server, "backup");
	@logs = &list_backup_logs($server);
	}
else {
	# All servers the user can manage
	&can_action_usage(undef, "backup");
	@logs = &list_backup_logs();
	if ($ownername) {
		@logs = grep { $_->{'owner'} eq $ownername } @logs;
		}
	if ($access{'owner'}) {
		@logs = grep { my $s = $servermap{$_->{'server'}};
			       $s && &can_action($s, "backup") } @logs;
		}
	}

# Limit by time range
if ($start) {
	@logs = grep { $_->{'time'} >= $start } @logs;
	}
if ($end) {
	@logs = grep { $_->{'time'} < $end } @logs;
	}
@logs = sort { $b->{'time'} <=> $a->{'time'} } @logs;

if ($multi) {
	# Show in a parsable format
	foreach $log (@logs) {
		$server = $servermap{$log->{'server'}};
		print $log->{'id'},"\n";
		print "    Date and time: ",&make_date($log->{'time'}),"\n";
		print "    Destination: ",$log->{'dest'},"\n";
		@dests = split(/\s+/, $log->{'dests'});
		@dests = ( $log->{'dest'} ) if (!@dests);
		foreach $d (@dests) {
			print "    File: $d\n";
			}
		if ($log->{'base_dest'}) {
			print "    Base destination: ",
			      $log->{'base_dest'},"\n";
			}
		print "    System: ",($server ? $server->{'host'} :
				      $log->{'host'} ? $log->{'host'} :
						       "UNKNOWN"),"\n";
		print "    System state: ",
		      ($server ? "Exists" : "Deleted"),"\n";
		if ($log->{'owner'}) {
			print "    Owner: ",$log->{'owner'},"\n";
			}
		print "    Status: ",$log->{'ok'} ? "OK" : "FAILED","\n";
		if ($log->{'ok'}) {
			print "    Size: ",&nice_size($log->{'size'}),"\n";
			print "    Size in bytes: ",$log->{'size'},"\n";
			}
		else {
			print "    Error message: ",$log->{'msg'},"\n";
			}
		}
	}
else {
	# Show in a table
	$fmt = "%-17.17s %-50.50s %-10.10s\n";
	printf $fmt, "Date/time", "Destination", "Status";
	printf $fmt, ("-" x 17), ("-" x 50), ("-" x 10);
	foreach $log (@logs) {
		printf $fmt, &make_date($log->{'time'}),
			     $log->{'dest'},
			     $log->{'ok'} ? &nice_size($log->{'size'})
					  : 'FAILED';
		}
	}

# date_to_time(date-string)
# Convert a date string like YYYY-MM-DD or -5 to a Unix time
sub date_to_time
{
my ($date) = @_;
my $rv;
if ($date =~ /^(\d{4})-(\d+)-(\d+)$/) {
	# Date only
	$rv = timelocal(0, 0, 0, $3, $2-1, $1-1900);
	}
elsif ($date =~ /^\-(\d+)$/) {
	# Some days ago
	$rv = time()-($1*24*60*60);
	}
$rv || &usage("Date spec must be like 2007-01-20 or -5 (days ago)");
return $rv;
}

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Lists logs for previous virtual system backups.\n";
print "\n";
print "cloudmin list-backup-logs [--multiline]\n";
print "                          [--owner name | --host name]\n";
print "                          [--start yyyy-mm-dd]\n";
print "                          [--end yyyy-mm-dd]\n";
exit(1);
}

