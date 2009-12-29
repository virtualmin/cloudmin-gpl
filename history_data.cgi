#!/usr/local/bin/perl
# Output the CSV for some stat over some time, possibly for multiple systems

$trust_unknown_referers = 1;
require './server-manager-lib.pl';
&ReadParse();
use POSIX;

# Get the servers we need
@allservers = &list_available_managed_servers_sorted();
@servers = &apply_search_form(\%in, \@allservers);
&can_action_error(\@servers, "graph");

# Get the stat for each server, and fill in missing section to the left. All
# servers need to have the same time range.
$first = undef;
foreach $s (@servers) {
	my @info = &list_historic_collected_info($in{'stat'}, $s,
			$in{'start'} || undef, $in{'end'} || undef);
	if ($in{'start'} && scalar(@info) > 1) {
		# Extend data range from the left until it reaches the
		# requested start time
		$gap = $info[1]->[0] - $info[0]->[0];
		while($info[0]->[0] > $in{'start'}+$gap) {
			unshift(@info, [ $info[0]->[0]-$gap, 0 ]);
			}
		}
	$infomap{$s->{'id'}} = \@info;
	if (@info > 1) {
		# Find first with some data
		$first ||= $infomap{$s->{'id'}};
		}
	}

# Find the shortest range
$shortest = $shortserver = undef;
foreach $s (@servers) {
	$info = $infomap{$s->{'id'}};
	if (scalar(@$info) > 1 &&
	    (scalar(@$info) < $shortest || !defined($shortest))) {
		$shortest = scalar(@$info);
		$shortserver = $s;
		}
	}

# Chop off any ranges longer than the shortest
# XXX not perfect - should really re-sample
foreach $s (@servers) {
        $info = $infomap{$s->{'id'}};
	if (scalar(@$info) > $shortest) {
		splice(@$info, $shortest, scalar(@$info)-$shortest);
		}
	}

# If there is too much data to reasonably display, reduce the number of points
# to approx 1024
$first ||= $infomap{$servers[0]->{'id'}};
if (scalar(@$first) > 1024) {
	$step = int(scalar(@$first) / 1024);
	foreach $s (@servers) {
		my @newinfo;
		for($i=0; $i<scalar(@$first); $i+=$step) {
			push(@newinfo, $infomap{$s->{'id'}}->[$i]);
			}
		if ($infomap{$s->{'id'}} eq $first) {
			$first = \@newinfo;
			}
		$infomap{$s->{'id'}} = \@newinfo;
		}
	}

print "Content-type: text/plain\n\n";
for($i=0; $i<scalar(@$first); $i++) {
	@values = ( );
	foreach $s (@servers) {
		$v = $infomap{$s->{'id'}}->[$i]->[1];
		if ($in{'nice'} && $v ne '0') {
			# Scale to something more easily readable
			if ($in{'stat'} eq 'memused' ||
			    $in{'stat'} eq 'swapused') {
				$v /= 1024*1024;
				}
			elsif ($in{'stat'} eq 'quotalimit' ||
			       $in{'stat'} eq 'quotaused') {
				$v /= 1024*1024;
				}
			elsif ($in{'stat'} eq 'diskused') {
				$v /= 1024*1024*1024;
				}
			}
		if ($v ne '0' && $v ne int($v)) {
			# Two decimal places only
			$v = sprintf("%.2f", $v);
			}
		push(@values, $v);
		}
	if ($in{'mode'} eq 'total' || $in{'mode'} eq 'average') {
		# Convert to sum total
		my $total;
		foreach my $v (@values) {
			$total += $v;
			}
		if ($in{'mode'} eq 'total') {
			@values = ( $total );
			}
		else {
			@values = ( $total / scalar(@values) );
			}
		}
	print strftime("%Y-%m-%d %H:%M:%S", localtime($first->[$i]->[0])),",",
	      join(",", @values),"\n";
	}

