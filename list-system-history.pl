#!/usr/local/bin/perl

=head1 list-system-history.pl

Lists the values of some statistic on one or more systems.

Cloudmin collects numerous statistics about each system that it manages, such
as CPU load, memory used and disk space free. This command outputs some or all
data samples for one or more systems, selected using the standard flags like
C<--host> or C<--type>. You must use the C<--stat> flag followed by a statistic
name to select the information to display.

By default all historic stats are shown, but you can select a different 
ime range with the C<--start> and C<--end> flags. Each must be followed
by either a date in I<yyyy-mm-dd> format, or a number of days into the
past from the current date like I<-5>. To switch the output to a more easily
parsed format, use the C<--multiline> flag.

=head1 Example usage

  cloudmin list-system-history --host xencentos.home
  xencentos.home
  Time                 Value                                   
  -------------------- ----------------------------------------
  06/Oct/2008 13:55    0.25 cores used                         
  06/Oct/2008 14:00    0.07 cores used                         
  06/Oct/2008 14:01    0.10 cores used                         
  06/Oct/2008 14:05    0.01 cores used                         
  06/Oct/2008 14:10    0.49 cores used                         
  06/Oct/2008 14:15    0.01 cores used                         
  06/Oct/2008 14:20    0.01 cores used                     

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
$0 = "$pwd/list-system-history.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";

# Parse command line for hosts
while(@ARGV > 0) {
	my $a = shift(@ARGV);
	if ($a eq "--all-hosts") { $all = 1; }
	elsif ($a eq "--host") { push(@hosts, shift(@ARGV)); }
	elsif ($a eq "--group") { push(@groups, shift(@ARGV)); }
	elsif ($a eq "--os") { push(@types, shift(@ARGV)); }
	elsif ($a eq "--type") { push(@managers, shift(@ARGV)); }
        elsif ($a eq "--owner") { push(@owners, shift(@ARGV)); }
	elsif ($a eq "--start") {
		$start = &date_to_time(shift(@ARGV));
		}
	elsif ($a eq "--end") {
		$end = &date_to_time(shift(@ARGV));
		}
	elsif ($a eq "--multiline") {
		$multi = 1;
		}
	elsif ($a eq "--stat") {
		$stat = shift(@ARGV);
		}
	else {
		&usage();
		}
	}

# Work out who to list
@servers = &find_managed_servers($all, \@hosts, \@groups, \@managers, \@types, \@owners);
@servers = sort { $a->{'host'} cmp $b->{'host'} } @servers;
@servers || &usage("No systems specified");
&can_action(\@servers, "edit") || &can_action_usage(\@servers, "view");

# Validate stat
$stat || &usage("Missing --stat parameter");
@stats = &list_historic_stats(\@servers);
&indexof($stat, @stats) >= 0 || &usage("Invalid --stat value - options are : ".join(" ", @stats));

$fmt = "%-20.20s %-40.40s\n";
$now = time();
foreach $s (@servers) {
	print $s->{'host'},"\n";
	@history = &list_historic_collected_info($stat, $s,
						$start || undef, $end || undef);
	if ($multi) {
		# In multi-line format
		foreach my $h (@history) {
			print "    Time: ",&make_date($h->[0]),"\n";
			print "    Value: ",$h->[1],"\n";
			}
		}
	else {
		# As columns
		printf $fmt, "Time", "Value";
		printf $fmt, ("-" x 20), ("-" x 40);
		foreach my $h (@history) {
			($val, $units) = &make_value_nice($stat, $h->[1]);
			$val .= " ".$units if ($units);
			printf $fmt, &make_date($h->[0]), $val;
			}
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
print "Lists the values of some statistic on one or more systems.\n";
print "\n";
print "cloudmin list-system-history --stat name\n";
print "                             [--start yyyy-mm-dd]\n";
print "                             [--end yyyy-mm-dd]\n";
print "                             [--all-hosts] | [--host name]*\n";
print "                             [--group name]*\n";
my $types = join("|", @server_management_types);
print "                             [--type $types]*\n";
print "                             [--os oscode]*\n";
print "                             [--owner name]*\n";
print "                             [--multiline]\n";
exit(1);
}


