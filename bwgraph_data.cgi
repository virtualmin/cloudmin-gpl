#!/usr/local/bin/perl
# Output data for a graph

$trust_unknown_referers = 1;
require './server-manager-lib.pl';
&ReadParse();
print "Content-type: text/plain\n\n";
use POSIX;

# Work out range size - by hour if more than 1 day
$start = $in{'start'};
$end = $in{'end'};
$range = $end - $start;
if ($range > 24*60*60) {
	# By hour
	$step = 3600;
	$prefix = "hour";
	}
else {
	# By minute
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
@servers = &list_managed_servers();

if ($in{'mode'} eq 'server') {
	# Show points for one server (in, out and total)
	($server) = grep { $_->{'id'} eq $in{'id'} } @servers;
	$server || &error($text{'edit_egone'});
	&can_action_error($server, "graph");
	$bwinfo = &get_bandwidth($server);
	for($i=$start; $i<=$end; $i+=$step) {
		@tm = localtime($i);
		$in = $bwinfo->{$prefix."_in_".$i};
		$out = $bwinfo->{$prefix."_out_".$i};
		$in /= $in{'scale'} if ($in{'scale'});
		$out /= $in{'scale'} if ($in{'scale'});
		$total = $in + $out;
		print strftime("%Y-%m-%d %H:%M:%S", @tm).",".
		      int($in).",".int($out).",".int($total)."\n";
		}
	}

elsif ($in{'mode'} eq 'total' || $in{'mode'} eq 'owner') {
	# Show sum of all servers, or those for some owner
	if ($in{'mode'} eq 'owner') {
		&can_action_error(undef, "global");
		$owner = &get_system_owner($in{'owner'});
		@servers = &get_owner_servers($owner);
		}
	&can_action_error(\@servers, "graph");
	@bwinfos = ( );
	foreach $server (@servers) {
		$bwinfo = &get_bandwidth($server);
		push(@bwinfos, $bwinfo) if ($bwinfo);
		}
	for($i=$start; $i<=$end; $i+=$step) {
		@tm = localtime($i);
		$in = $out = 0;
		foreach $bwinfo (@bwinfos) {
			$in += $bwinfo->{$prefix."_in_".$i};
			$out += $bwinfo->{$prefix."_out_".$i};
			}
		$in /= $in{'scale'} if ($in{'scale'});
		$out /= $in{'scale'} if ($in{'scale'});
		$total = $in + $out;
		print strftime("%Y-%m-%d %H:%M:%S", @tm).",".
		      int($in).",".int($out).",".int($total)."\n";
		}
	}

