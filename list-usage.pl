#!/usr/local/bin/perl

=head1 list-usage.pl

Lists uptime, memory and CPU usage samples for some system.

Cloudmin collects information about the up or down status, CPU and memory use
of all systems it manages, stored as usage samples. Each sample has a time
range, status (up or down), memory and CPU information, which remained the same
over that period. If anything changes (such as system being shut down or 
having its memory increased), a new usage sample is generated.

This command lists usage samples for one or more managed systems, selected
using standard flags like C<--host> or C<--type>. By default only usage that
falls within the current account period is shown, but you can select a different
time range with the C<--start> and C<--end> flags. Each must be followed by
either a date in I<yyyy-mm-dd> format, or a number of days into the past from
the current date like I<-5>.

=head1 Example usage

  cloudmin list-usage --host xencentos.home
  Start              End                Up?  Memory     CPU   CPU time
  09/May/2009 14:50  09/May/2009 14:55  Yes  -          100%  -
  09/May/2009 14:55  09/May/2009 14:58  No   -          -     -
  09/May/2009 14:58  09/May/2009 14:59  Yes  640 MB     100%  -
  09/May/2009 14:59  09/May/2009 17:04  Yes  640 MB     100%  -
  09/May/2009 17:04  09/May/2009 17:10  Yes  640 MB     50%   -

=cut

package server_manager;
$main::no_acl_check++;
$ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
$ENV{'WEBMIN_VAR'} ||= "/var/webmin";
if ($0 =~ /^(.*\/)[^\/]+$/) {
	chdir($1);
	}
chop($pwd = `pwd`);
$0 = "$pwd/list-usage.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";

# Parse command line for hosts
while(@ARGV > 0) {
	local $a = shift(@ARGV);
	if ($a eq "--all-hosts") { $all = 1; }
	elsif ($a eq "--host") { push(@hosts, shift(@ARGV)); }
	elsif ($a eq "--group") { push(@groups, shift(@ARGV)); }
	elsif ($a eq "--os") { push(@types, shift(@ARGV)); }
	elsif ($a eq "--type") { push(@managers, shift(@ARGV)); }
	elsif ($a eq "--start") {
		$start = int(&date_to_time(shift(@ARGV)) / (24*60*60));
		}
	elsif ($a eq "--end") {
		$end = int(&date_to_time(shift(@ARGV)) / (24*60*60));
		}
	else {
		&usage();
		}
	}

# Work out who to list
@servers = &find_managed_servers($all, \@hosts, \@groups, \@managers, \@types);
@servers = sort { $a->{'host'} cmp $b->{'host'} } @servers;
@servers || &usage("No systems specified");

$fmt = " %-18.18s %-18.18s %-4.4s %-10.10s %-10.10s %-10.10s\n";
$now = time();
foreach $s (@servers) {
	print $s->{'host'},"\n";
	@usage = &get_server_usage($s);

	# Work out start and end time, if not given
	($mystart, $myend) = ($start, $end);
	if (!$mystart) {
		$mystart = &bandwidth_period_start();
		if (@usage && $mystart < $usage[0]->{'start'}) {
			$mystart = $usage[0]->{'start'};
			}
		}
	$myend ||= time();

	# Show samples that fill into the period
	printf $fmt, "Start", "End", "Up?", "Memory", "CPU alloc", "CPU load";
	foreach my $u (@usage) {
		next if ($u->{'end'} < $mystart ||
			 $u->{'start'} > $myend);
		printf $fmt, &make_date($u->{'start'}),
			     &make_date($u->{'end'}),
			     $u->{'up'} ? "Yes" : "No",
			     $u->{'mem'} ? &nice_size($u->{'mem'}) : "-",
			     $u->{'cpu'} ne '' ? int($u->{'cpu'})."%" : "-",
			     $u->{'load'} ne '' ? int($u->{'load'})."%" : "-";
		}
	}

# date_to_time(date-string)
# Convert a date string like YYYY-MM-DD or -5 to a Unix time
sub date_to_time
{
local ($date) = @_;
local $rv;
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
print "Shows uptime, CPU and memory use by some virtual systems\n";
print "\n";
print "cloudmin list-usage [--start yyyy-mm-dd]\n";
print "                    [--end yyyy-mm-dd]\n";
print "                    [--all-hosts] | [--host name]*\n";
print "                    [--group name]*\n";
local $types = join("|", @server_management_types);
print "                    [--type $types]*\n";
print "                    [--os oscode]*\n";
exit(1);
}


