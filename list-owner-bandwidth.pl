#!/usr/local/bin/perl

=head1 list-onwer-bandwidth.pl

Lists bandwidth use for all systems belonging to some owner over some date range

This command outputs hourly or per-minute bandwidth usage stats for selected
owner's systems. It provides the same information as the bandwidth
graphs in the web UI, but in a format that can be parsed or graphed by
other programs. Owners are chosen with the C<--owner> flag, or you can 
select all of them with C<--all-owners>.

The date range to output is selected by the C<--start> and C<--end> flags,
which must be followed by either a date in I<yyyy-mm-dd> format, or a number
of days into the past from the current date like I<-5>. If the start date is
not given, data from the time the system was created is output. If the end
is ommitted, data up to the current time is displayed.

By default, per-hour totals are shown. However, you can switch to per-minute
data with the C<--minute> flag. Also, output is by default rounded to the
nearest MB or GB to make it more readable - but you can switch to showing the
exact number of bytes with the C<--exact> flag.

Note that for data collected before Cloudmin 7.2, the bandwidth used by all
systems managed by the selected owners currently is included - even if they
were not managed at some point in the page. After Cloudmin 7.2, bandwidth
is properly accounted to the owner at the time of measurement.

=head1 Example usage

  cloudmin list-owner-bandwidth --owner bob --start -2
  bob
   Date/time            Data in      Data out     Packets in   Packets out
   23/Jul/2009 18:00    20.45 MB     21.44 MB     46330        45834
   23/Jul/2009 19:00    23.74 MB     25.24 MB     54678        54568
   23/Jul/2009 20:00    42.05 MB     43.64 MB     82733        84325

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
$0 = "$pwd/list-bandwidth.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";
&can_action_usage(undef, "global");

# Parse command line for hosts
while(@ARGV > 0) {
	my $a = shift(@ARGV);
	if ($a eq "--owner") {
		$oname = shift(@ARGV);
		$owner = &get_system_owner($oname);
		$owner || &usage("No system owner named $oname found");
		push(@owners, $owner);
		}
	elsif ($a eq "--all-owners") {
		@owners = &list_system_owners();
		}
	elsif ($a eq "--start") {
		$start = int(&date_to_time(shift(@ARGV)) / (60*60)) *
			 (60*60);
		}
	elsif ($a eq "--end") {
		$end = int(&date_to_time(shift(@ARGV)) / (60*60)) *
		       (60*60);
		}
	elsif ($a eq "--exact") {
		$exact = 1;
		}
	elsif ($a eq "--minute") {
		$minute = 1;
		}
	elsif ($a eq "--multiline") {
		$multiline = 1;
		}
	else {
		&usage("Unknown parameter $a");
		}
	}
@owners || &usage("No system owners specified");

$fmt = " %-20.20s %-12.12s %-12.12s %-12.12s %-12.12s\n";
$now = time();
foreach $o (@owners) {
	print $o->{'name'},"\n";

	# Get systems, bandwidth and date ranges
	$bwinfo = &get_owner_bandwidth($o, $start, $end);
	($mystart, $myend) = ($start, $end);
	if ($minute) {
		# Oldest minute
		if ($mystart < $bwinfo->{'old_min'}) {
			$mystart = $bwinfo->{'old_min'};
			}
		if (!$myend) {
			$myend = $bwinfo->{'new_min'} || int($now/60)*60;
			}
		$step = 60;
		$suffix = "min_";
		}
	else {
		# Oldest hour
		if ($mystart < $bwinfo->{'old_hour'}) {
			$mystart = $bwinfo->{'old_hour'};
			}
		if (!$myend) {
			$myend = $bwinfo->{'new_hour'} || int($now/3600)*3600;
			}
		$step = 3600;
		$suffix = "hour_";
		}
	$mystart = $myend if (!$mystart);

	# Show stats for that range
	printf $fmt, "Date/time", "Data in", "Data out",
		     "Packets in", "Packets out";
	for(my $i=$mystart; $i<=$myend; $i+=$step) {
		my $in = $bwinfo->{$suffix.'in_'.$i};
		my $out = $bwinfo->{$suffix.'out_'.$i};
		my $inp = $bwinfo->{$suffix.'inp_'.$i};
		my $outp = $bwinfo->{$suffix.'outp_'.$i};
		printf $fmt, &make_date($i),
			     &maybe_nice_size($in), &maybe_nice_size($out),
			     int($inp), int($outp);
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

sub maybe_nice_size
{
return $exact ? $_[0] : &nice_size($_[0]);
}

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Shows bandwidth usage by system owner and time\n";
print "\n";
print "cloudmin list-owner-bandwidth [--start yyyy-mm-dd]\n";
print "                              [--end yyyy-mm-dd]\n";
print "                              [--owner name]* | [--all-owners]\n";
print "                              [--minute]\n";
print "                              [--exact]\n";
exit(1);
}


