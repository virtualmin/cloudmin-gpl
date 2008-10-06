#!/usr/local/bin/perl
# Output the CSV for some stat over some time, possibly for multiple systems

require './virtual-server-lib.pl';
&can_show_history() || &error($text{'history_ecannot'});
&ReadParse();
use POSIX;

# Get the servers we need
@allservers = &list_available_managed_servers_sorted();
@servers = &apply_search_form(\%in, \@allservers);

# Get the stat for each server, and fill in missing section to the left. All
# servers need to have the same time range.
foreach $s (@servers) {
	my @info = &list_historic_collected_info($stat, $s,
			$in{'start'} || undef, $in{'end'} || undef);
	if ($in{'start'} && @info > 1) {
		$gap = $info[1]->[0] - $info[0]->[0];
		while($info[0]->[0] > $in{'start'}+$gap) {
			unshift(@info, [ $info[0]->[0]-$gap, undef ]);
			}
		}
	$infomap{$s->{'id'}} = \@info;
	}

# If there is too much data to reasonably display, reduce the number of points
# to approx 1024
$first = $infomap{$servers[0]->{'id'}};
if (scalar(@$first) > 1024) {
	$step = int(scalar(@$first) / 1024);
	foreach $s (@servers) {
		my @newinfo;
		for($i=0; $i<scalar(@$first); $i+=$step) {
			push(@newinfo, $infomap{$s->{'id'}}->[$i]);
			}
		$infomap{$s->{'id'}} = \@newinfo;
		}
	}
$first = $infomap{$servers[0]->{'id'}};

print "Content-type: text/plain\n\n";
for($i=0; $i<scalar(@$first); $i++) {
	@values = ( );
	foreach $s (@servers) {
		$v = $infomap{$->{'id'}}->[$i]->[1];
		if ($in{'nice'}) {
			# Scale to something more easily readable
			if ($stat eq 'memused' || $stat eq 'swapused') {
				$v /= 1024*1024;
				}
			elsif ($stat eq 'quotalimit' || $stat eq 'quotaused') {
				$v /= 1024*1024;
				}
			elsif ($stat eq 'diskused') {
				$v /= 1024*1024*1024;
				}
			elsif ($stat =~ /^load(|5|15)$/) {
				$v *= 100;
				}
			}
		if ($v ne int($v)) {
			# Two decimal places only
			$v = sprintf("%.2f", $v);
			}
		push(@values, $v);
		}
	print strftime("%Y-%m-%d %H:%M:%S", localtime($first->[$i]->[0])),",",
	      join(",", @values),"\n";
	}

