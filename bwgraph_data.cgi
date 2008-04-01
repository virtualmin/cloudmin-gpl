#!/usr/local/bin/perl
# Output data for a graph

require './server-manager-lib.pl';
&ReadParse();
print "Content-type: text/plain\n\n";
use POSIX;

# Work out range size
$range = $end - $start;
if ($range > 1024*60) {
	# By hour
	$step = 3600;
	$prefix = "hour";
	}
else {
	$step = 60;
	$prefix = "min";
	}

# Scale down step so that we aren't showing more than 1k points
if ($in{'mode'} ne 'system') {
	$count = int($range / $step);
	while($count > 1024) {
		$step *= 2;
		$count /= 2;
		}
	}

if ($in{'mode'} eq 'server') {
	# Show points for one server (in, out and total)
	($server) = grep { $_->{'id'} eq $in{'id'} } &list_managed_servers();
	$bwinfo = &get_bandwidth($server);
	for($i=$start; $i<=$end; $i+=$step) {
		@tm = localtime($i);
		$total = $config{'bw_dir_in'} && $config{'bw_dir_out'} ?
			$bwinfo->{$prefix."_in_".$i} +
			$bwinfo->{$prefix."_out_".$i} : undef;
		print strftime("%Y-%m-%d %H:%M:%S", @tm).",".
		      $bwinfo->{$prefix."_in_".$i}.",".
		      $bwinfo->{$prefix."_out_".$i}.
		      (defined($total) ? ",".$total : "")."\n";
		}
	}

elsif ($in{'mode'} eq 'total') {
	# Show sum of all servers
	}

elsif ($in{'mode'} eq 'system') {
	# Show per-server for period
	# XXX cannot skip step
	}

