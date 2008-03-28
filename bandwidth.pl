#!/usr/local/bin/perl
# Fetch bandwidth counts for all managed systems

$main::no_acl_check++;
require './server-manager-lib.pl';

# For each system, get it's current counts, compare to old counts, then up
# the total for this hour
foreach $s (&list_managed_servers()) {
	next if ($s->{'status'} eq 'nohost');
	local $bwinfo = &get_bandwidth($s);
	$now = time();
	($in, $out, $inp, $outp) = &get_server_traffic($s);
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
		for(my $h=$bwinfo->{'last_time'}; $h<$now; $h+=3600) {
			$hh = int($h/3600) * 3600;
			$bwinfo->{'hour_in_'.$hh} += $in_diff / $hours;
			$bwinfo->{'hour_out_'.$hh} += $out_diff / $hours;
			$bwinfo->{'hour_inp_'.$hh} += $inp_diff / $hours;
			$bwinfo->{'hour_outp_'.$hh} += $outp_diff / $hours;
			}

		# By minute
		$mins = ($now - $bwinfo->{'last_time'}) / 60.0;
		for(my $m=$bwinfo->{'last_time'}; $m<$now; $m+=60) {
			$mm = int($m/60) * 60;
			$bwinfo->{'min_in_'.$mm} += $in_diff / $mins;
			$bwinfo->{'min_out_'.$mm} += $out_diff / $mins;
			$bwinfo->{'min_inp_'.$mm} += $inp_diff / $mins;
			$bwinfo->{'min_outp_'.$mm} += $outp_diff / $mins;
			}

		# Get rid of per-minute stats more than 1 week old
		$oldmm = int($bwinfo->{'last_time'}/60) * 60;
		$oldmm = $bwinfo->{'old_min'} if ($bwinfo->{'old_min'} <$oldmm);
		$newmm = $now - 7*24*60*60;
		$newmm = int($newmm/60) * 60;
		for(my $mm=$oldmm; $mm<$newmm; $mm+=60) {
			delete($bwinfo->{'min_in_'.$mm});
			delete($bwinfo->{'min_out_'.$mm});
			delete($bwinfo->{'min_inp_'.$mm});
			delete($bwinfo->{'min_outp_'.$mm});
			}
		}
	$bwinfo->{'last_time'} = $now;

	# Write out
	&save_bandwidth($s);
	}

# For each server, sum up usage over the relevant accounting period, and
# send email or disable if needed

