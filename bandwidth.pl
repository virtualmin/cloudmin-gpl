#!/usr/local/bin/perl
# Fetch bandwidth counts for all managed systems

$main::no_acl_check++;
require './server-manager-lib.pl';

# Parse command line for hosts
if (@ARGV == 0) {
	$all = 1;	# If called with no args, assume all systems
	}
while(@ARGV > 0) {
	local $a = shift(@ARGV);
	if ($a eq "--all-hosts") { $all = 1; }
	elsif ($a eq "--host") { push(@hosts, shift(@ARGV)); }
	elsif ($a eq "--group") { push(@groups, shift(@ARGV)); }
	elsif ($a eq "--os") { push(@types, shift(@ARGV)); }
	elsif ($a eq "--type") { push(@managers, shift(@ARGV)); }
	else {
		&usage();
		}
	}

# Work out who to check
@servers = &find_managed_servers($all, \@hosts, \@groups, \@managers, \@types);
@servers = sort { $a->{'host'} cmp $b->{'host'} } @servers;
@servers || &usage("No systems specified");

# For each system, get it's current counts, compare to old counts, then up
# the total for this hour
foreach $s (@servers) {
	next if ($s->{'status'} eq 'nohost');
	local $bwinfo = &get_bandwidth($s);
	$now = time();
	($in, $out, $inp, $outp) = &get_server_traffic($s);
	print STDERR "for $s->{'host'} in=$in out=$out\n";
	next if (!defined($in));

	# Work out diffs
	$in_diff = $in - $bwinfo->{'last_in'};
	$out_diff = $out - $bwinfo->{'last_out'};
	$inp_diff = $inp - $bwinfo->{'last_inp'};
	$outp_diff = $outp - $bwinfo->{'last_outp'};
	$in_diff = 0 if ($in_diff < 0);
	$out_diff = 0 if ($out_diff < 0);
	$inp_diff = 0 if ($inp_diff < 0);
	$outp_diff = 0 if ($outp_diff < 0);

	# Save new lasts
	$bwinfo->{'last_in'} = $in;
	$bwinfo->{'last_out'} = $out;
	$bwinfo->{'last_inp'} = $inp;
	$bwinfo->{'last_outp'} = $outp;

	# Spread over period between last poll and now
	if ($bwinfo->{'last_time'}) {
		# By hour
		$hours = ($now - $bwinfo->{'last_time'}) / 3600.0;
		$hours = 1 if ($hours < 1);
		print STDERR "hours=$hours\n";
		for(my $h=$bwinfo->{'last_time'}; $h<$now; $h+=3600) {
			$hh = int($h/3600) * 3600;
			$bwinfo->{'hour_in_'.$hh} += $in_diff / $hours;
			$bwinfo->{'hour_out_'.$hh} += $out_diff / $hours;
			$bwinfo->{'hour_inp_'.$hh} += $inp_diff / $hours;
			$bwinfo->{'hour_outp_'.$hh} += $outp_diff / $hours;
			print STDERR "hours for $s->{'host'} at ",
				&make_date($hh)," in=$in_diff out=$out_diff\n";
			}
		$bwinfo->{'old_hour'} ||= int($bwinfo->{'last_time'}/3600)*3600;

		# By minute
		$mins = ($now - $bwinfo->{'last_time'}) / 60.0;
		$mins = 1 if ($mins < 1);
		print STDERR "mins=$mins\n";
		for(my $m=$bwinfo->{'last_time'}; $m<$now; $m+=60) {
			$mm = int($m/60) * 60;
			$bwinfo->{'min_in_'.$mm} += $in_diff / $mins;
			$bwinfo->{'min_out_'.$mm} += $out_diff / $mins;
			$bwinfo->{'min_inp_'.$mm} += $inp_diff / $mins;
			$bwinfo->{'min_outp_'.$mm} += $outp_diff / $mins;
			print STDERR "mins for $s->{'host'} at ",
				&make_date($mm)," in=$in_diff out=$out_diff\n";
			}
		$bwinfo->{'old_min'} ||= int($bwinfo->{'last_time'}/60)*60;

		# Get rid of per-minute stats more than 1 week old
		$weekago = $now - 7*24*60*60;
		$weekago = int($weekago/60) * 60;
		if ($bwinfo->{'old_min'} < $weekago) {
			for(my $mm=$bwinfo->{'old_min'}; $mm<$weekago; $mm+=60){
				delete($bwinfo->{'min_in_'.$mm});
				delete($bwinfo->{'min_out_'.$mm});
				delete($bwinfo->{'min_inp_'.$mm});
				delete($bwinfo->{'min_outp_'.$mm});
				}
			$bwinfo->{'old_min'} = $weekago;
			}
		}
	$bwinfo->{'last_time'} = $now;

	# Write out
	&save_bandwidth($s, $bwinfo);
	}

# For each server, sum up usage over the relevant accounting period, and
# send email or disable if needed
# XXX

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Check for and sum up bandwidth use on managed systems.\n";
print "\n";
print "usage: bandwidth.pl [--all-hosts] | [--host name]*\n";
print "                    [--group name]*\n";
local $types = join("|", @server_management_types);
print "                    [--type $types]*\n";
print "                    [--os oscode]*\n";
exit(1);
}

