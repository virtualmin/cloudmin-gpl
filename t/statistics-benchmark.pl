#!/usr/bin/perl
# Synthetic storage benchmark with no Webmin initialization or host changes.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use Cloudmin::Statistics;
use File::Temp qw(tempdir);
use Getopt::Long qw(GetOptions);
use Time::HiRes qw(time);
# Bound synthetic load to catch accidental out-of-range arguments.
my ($vms, $devices, $ticks, $interval) = ( 100, 3, 120, 10 );
GetOptions('vms=i' => \$vms, 'devices=i' => \$devices, 'ticks=i' => \$ticks,
	   'interval=i' => \$interval) or die "Invalid arguments\n";
die "Invalid benchmark size\n" unless $vms > 0 && $vms <= 10000 &&
	$devices >= 0 && $devices <= 8 &&
	$ticks > 0 && $ticks <= 600 && $interval >= 5 && $interval <= 60;
# Use a temporary database and a deterministic sample clock for repeatability.
my $dir = tempdir(CLEANUP => 1);
my $store =
	Cloudmin::Statistics->new(directory => $dir, write => 1, host_id =>
									 Cloudmin::Statistics::uuid());
my $start = time();
my @times;
for my $tick (1 .. $ticks) {
	my @rows;
	my $now = 1700000000 + $tick * $interval;
	# Generate each guest aggregate and its disk rows within the same tick.
	for my $n (1 .. $vms) {
		my $id = sprintf('%08x-1111-4111-8111-111111111111', $n);
		push @rows,
			{ entity => $id, owner => $id, kind => 'vm', label =>
									     "Guest $n", start => $now - $interval,
			  end => $now,
			  values =>
				  { cpu => ($n + $tick) % 100, vcpus => 2,
				    memory_allocated => 2147483648,
				    memory_used =>
					    1073741824,
				    disk_read => 102400, disk_write => 51200,
				    network_receive => 10240,
				    network_transmit => 5120 } };
		for my $d (1 .. $devices) {
			push @rows,
				{ entity => "$id/disk/vd$d", owner => $id,
				  kind =>
					  'disk', label => "vd$d",
				  start => $now - $interval,
				  end => $now,
				  values => { disk_read => 102400,
					      disk_write => 51200,
					      disk_capacity => 21474836480 } };
			}
		}
	# Measure the database write separately from fixture row construction.
	my $at = time();
	$store->record(\@rows, [ ], $now);
	push @times, time() - $at;
	}
# Time representative chart and export reads after collecting the samples.
my $elapsed = time() - $start;
my $at = time();
my $result =
	$store->query('00000001-1111-4111-8111-111111111111', 1700000000,
		      1700000000 + $ticks * $interval, 600);
my $query = time() - $at;
$at = time();
my $export = $store->export(60, undef, 1000);
my $export_time = time() - $at;
# Checkpoint before measuring size so WAL data is included in the main file.
$store->{db}->do('PRAGMA wal_checkpoint(TRUNCATE)');
my $bytes = -s "$dir/metrics.sqlite";
my @sorted = sort { $a <=> $b } @times;
printf "VMs=%d devices/VM=%d ticks=%d interval=%ds rows=%d bytes=%d elapsed=%.3fs tick_p95=%.4fs query=%.4fs export1000=%.4fs points=%d\n",
	$vms, $devices, $ticks, $interval,
	$store->{db}->selectrow_array('SELECT count(*) FROM samples'), $bytes,
	$elapsed,
	$sorted[int(.95 * $#sorted)], $query, $export_time,
	scalar(@{$result->{series}});
