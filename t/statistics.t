use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Encode qw(encode);
use Cloudmin::Statistics;
use Cloudmin::StatsCollector;

# Opening an empty store must preserve identity without creating a database.
my $dir = tempdir(CLEANUP => 1);
my $host = Cloudmin::Statistics::host_id($dir);
is(Cloudmin::Statistics::host_id($dir), $host,
   'host identity survives reopening');
my $empty = Cloudmin::Statistics->new(directory => $dir);
ok(!-e "$dir/metrics.sqlite", 'reader does not create history');
is_deeply($empty->query('vm', 0, 60, 60)->{series}, [ ],
	  'new host has no history');

# Weighted math must preserve independent coverage for each metric.
for my $case (
	[ { cpu => 20 }, 10, { cpu => 80 }, 20, 60, 30 ],
	[ { cpu => 0 }, 10, { }, 20, 0, 10 ],
	[ { cpu => 90 }, 5, { cpu => 30 }, 15, 45, 20 ],
) {
	my ($a, $ad, $b, $bd, $expected, $seconds) = @$case;
	my $merged =
		Cloudmin::Statistics::merge(Cloudmin::Statistics::summary($a,
									  $ad),
					    Cloudmin::Statistics::summary($b,
									  $bd));
	is($merged->{cpu_sum} / $merged->{cpu_duration}, $expected,
	   'average is weighted by valid time');
	is($merged->{cpu_duration}, $seconds,
	   'missing interval does not count toward coverage');
	}
my $store =
	Cloudmin::Statistics->new(directory => $dir, write => 1,
				  host_id => $host);
my $vm = '11111111-1111-4111-8111-111111111111';

# sample(start,end,values) produces a normalized VM interval for storage tests.
sub sample
{
my ($a, $b, $v) = @_;
return { entity => $vm, owner => $vm, kind => 'vm', label => 'Example',
	 start => $a, end => $b, values => $v };
}
# A zero-duration baseline must not occupy the first measured interval.
$store->record([ sample(0, 0, { cpu => 0 }) ], [ ], 0);
$store->record([ sample(0, 10,
			{ cpu => 20, memory_allocated => 1024,
			  disk_read => 100 }) ], [ ], 10);
is(
	$store->{db}->selectrow_array(
		'SELECT cpu_sum FROM samples WHERE entity=? AND step=0 AND t=0',
		undef,
		$vm), 200,
	'initial baseline does not hide the first real interval');
# Unequal intervals and missing metrics exercise independent weighted totals.
$store->record([ sample(10, 30,
			{ cpu => 80, memory_allocated => 1024,
			  memory_used => 512,
			  disk_read =>
				  200 }) ], [ ], 30);
$store->record([ sample(30, 60, { memory_allocated => 1024 }) ], [ ], 60);
$store->record([ sample(60, 70, { cpu => 40 }) ], [ ], 70);
my $row =
	$store->{db}->selectrow_hashref(
		'SELECT * FROM samples WHERE entity=? AND step=60 AND t=0',
		undef,
		$vm);
is($row->{cpu_sum}, 1800, 'minute retains weighted sum');
is($row->{cpu_duration}, 30, 'minute CPU coverage excludes unavailable half');
is($row->{memory_used_duration}, 20, 'balloon usage has independent validity');
is($row->{memory_allocated_duration}, 60,
   'allocated memory remains valid throughout');
is($row->{disk_read_sum}, 5000,
   'counter summary retains actual byte increment');
is($row->{disk_read_max}, 200, 'summary retains peak interval rate');
ok($row->{closed}, 'completed minute sealed');
# Replaying an interval must not merge its contribution into summaries twice.
my $before =
	$store->{db}->selectrow_array(
		'SELECT cpu_sum FROM samples WHERE entity=? AND step=60 AND t=60',
		undef, $vm);
$store->record([ sample(60, 70, { cpu => 40 }) ], [ ], 70);
is(
	$store->{db}->selectrow_array(
		'SELECT cpu_sum FROM samples WHERE entity=? AND step=60 AND t=60', undef,
		$vm), $before, 'retry does not duplicate summary');

# Query, device scope and export use independent bounded read connections.
my $read = Cloudmin::Statistics->new(directory => $dir);
my $query = $read->query($vm, 0, 120, 60);
is(scalar(@{$query->{series}}), 60, 'chart point limit honored');
is($query->{series}->[20]->{values}->{cpu}, undef,
   'missing CPU interval stays null');
is_deeply($read->query('another-vm', 0, 120, 60, $vm)->{series}, [ ],
	  'owner cannot select another VM entity');
# A retry returns the same sealed row, and its cursor advances to the next row.
my $batch = $read->export(60, undef, 1);
is(scalar(@{$batch->{rows}}), 1, 'completed minute exported');
is_deeply($read->export(60, undef, 1), $batch,
	  'repeated cursor request is idempotent');
is(scalar(@{$read->export(60, $batch->{cursor}, 1)->{rows}}), 0,
   'cursor advances exactly once');
eval { $read->export(300, $batch->{cursor}, 10) };
like($@, qr/cursor/, 'resolution cannot change under an existing cursor');
# Bounded periods and point counts protect readers from oversized queries.
eval { $read->query($vm, 0, 400 * 86400, 600) };
like($@, qr/range/, 'unbounded history query rejected');
eval { $read->query($vm, 0, 3600, 100000) };
like($@, qr/limit/, 'unbounded point request rejected');

# Device choices follow retained history, not the latest inventory or all time.
for my $scope ( [ 'host', 'block', 'uplink' ], [ 'vm', 'disk', 'nic' ] ) {
	my ($owner, $disk_kind, $network_kind) = @$scope;
	my $devices =
		Cloudmin::Statistics->new(directory => tempdir(CLEANUP => 1),
					  write => 1, host_id => $host);
	for my $interval ( [ 540, 550, 'removed' ], [ 620, 630, 'current' ] ) {
		my ($start, $end, $disk) = @$interval;
		$devices->record([ map { { entity => "$owner/$_->[0]", owner =>
									       $owner, kind => $_->[1], label => $_->[0],
					   start => $start, end => $end,
					   values => { disk_read => 100 } } }
				   [ $disk, $disk_kind ], [ 'network',
							    $network_kind ] ],
				 [ ],
				 $end);
		}
	# Keep owner baselines visible without inventing
	# device or foreign history.
	$devices->record([ { entity => $owner, owner => $owner, kind => $owner,
			     label => $owner,
			     start => 700, end => 700, values => { } } ], [ ],
			 700);
	$devices->record([ { entity => "$owner/baseline", owner => $owner,
			     kind =>
				     $disk_kind, label => 'baseline',
			     start => 700, end => 700, values => { } } ], [ ],
			 700);
	$devices->record([ { entity => 'foreign/disk', owner => 'foreign',
			     kind =>
				     $disk_kind, label => 'foreign',
			     start => 700, end => 710,
			     values => { disk_read => 1 } } ], [ ],
			 710);
	$devices->record([ ], [ ], 1200);
	for my $tier ( 0, 60, 300 ) {
		# Exercise the same windows after finer rows expire. Sealed
		# summary tails must not keep removed devices in a
		# later period's menu.
		$devices->{db}->do('DELETE FROM samples WHERE step<?', undef,
				   $tier);
		for my $case (
			[ 540, 720,
			  [ $owner, "$owner/current", "$owner/network",
			    "$owner/removed" ] ],
			[ 600, 720,
			  [ $owner, "$owner/current", "$owner/network" ] ],
			[ 540, 600,
			  [ $owner, "$owner/network", "$owner/removed" ] ],
			[ 630, 720, [ $owner ] ],
		) {
			my ($from, $to, $expected) = @$case;
			my $choices =
				$devices->query($owner, $from, $to,
						60)->{entities};
			is_deeply([ sort map { $_->{id} } @$choices ],
				  $expected,
				  "$owner devices follow period $from-$to at tier $tier");
			}
		# A removed device remains selectable while its
		# measurements are retained.
		my $removed =
			$devices->query($owner, 540, 720, 60, "$owner/removed");
		ok(grep(defined($_->{values}->{disk_read}),
			@{$removed->{series}}),
		   "$owner removed device remains queryable at tier $tier");
		}
	}

# Boundary splitting preserves increments and duration through larger tiers.
$store->record([ sample(70, 180, { cpu => 60, disk_read => 50 }) ], [ ], 180);
$store->record([ sample(180, 300, { cpu => 60, disk_read => 50 }) ], [ ], 300);
$store->record([ sample(300, 310, { cpu => 40 }) ], [ ], 310);
my $five =
	$store->{db}->selectrow_hashref(
		'SELECT * FROM samples WHERE entity=? AND step=300 AND t=0',
		undef,
		$vm);
is($five->{cpu_duration}, 270, 'five-minute coverage merges minute durations');
is($five->{disk_read_sum}, 16500,
   'five-minute bytes merge without averaging rates');
ok($five->{closed}, 'five-minute bucket sealed after child minutes');
# Compare merged summaries with the same durations accumulated directly.
my $direct = Cloudmin::Statistics::summary({ cpu => 60 }, 230);
Cloudmin::Statistics::merge($direct,
			    Cloudmin::Statistics::summary({ cpu => 40 }, 10));
Cloudmin::Statistics::merge($direct,
			    Cloudmin::Statistics::summary({ cpu => 60 }, 30));
is($five->{cpu_sum}, $direct->{cpu_sum},
   'summary merging equals direct interval math');
# An unfinished bucket measures coverage against elapsed, not future, time.
$store->record([ sample(3600, 3660, { cpu => 60 }) ], [ ], 3660);
$store->record([ sample(3660, 3670, { cpu => 60 }) ], [ ], 3670);
my $partial = $read->query($vm, 0, 3670, 60);
is($partial->{resolution}, 60, 'longer query uses minute summaries');
is($partial->{series}->[-1]->{coverage}->{cpu}, 1,
   'open minute coverage uses elapsed time, not future time');
# Pruning exported rows must tell later clients that their cursor has a gap.
$store->purge(60, 60);
ok($read->export(60, undef, 100)->{retention_gap},
   'expired export reports a retention gap');

# New history must not become coarser just because summaries
# start on boundaries.
for my $offset ( 47, 947, 3547 ) {
	my $fresh_dir = tempdir(CLEANUP => 1);
	my $fresh =
		Cloudmin::Statistics->new(directory => $fresh_dir, write => 1,
					  host_id => $host);
	my $start = 1_800_000_000 + $offset;
	my $end = $start + 600;
	for (my $t = $start ; $t < $end ; $t += 10) {
		$fresh->record([ sample($t, $t + 10,
					{ cpu => 25,
					  memory_allocated => 1024 }) ],
			       [ ], $t + 10);
		}
	for my $case ( [ 3600, 0 ], [ 86400, 60 ] ) {
		my ($period, $resolution) = @$case;
		my $chart = $fresh->query($vm, $end - $period, $end, 600);
		is($chart->{resolution}, $resolution,
		   "recent history keeps requested detail ($offset, $period)");
		cmp_ok(
			scalar(
				grep { defined($_->{values}->{cpu}) } @{
					$chart->{series}}),
			'>', 1,
			'recent samples produce a line, not a single hourly point');
		}
	}

# Expired fine samples still fall back to genuinely older retained summaries.
my $retained_dir = tempdir(CLEANUP => 1);
my $retained =
	Cloudmin::Statistics->new(directory => $retained_dir, write => 1,
				  host_id =>
					  $host);
for (my $t = 1_800_000_047 ; $t < 1_800_007_247 ; $t += 10) {
	$retained->record([ sample($t, $t + 10, { cpu => 25 }) ], [ ], $t + 10);
	}
my $retained_end = 1_800_007_247;
is($retained->query($vm, $retained_end - 3600, $retained_end,
		    600)->{resolution}, 0,
   'complete recent history stays fine when older summaries overlap the range');
for my $case ( [ 0, 60 ], [ 60, 300 ], [ 300, 3600 ] ) {
	my ($expired, $resolution) = @$case;
	$retained->purge($expired, $retained_end - 600);
	my $chart =
		$retained->query($vm, $retained_end - 3600, $retained_end, 600);
	is($chart->{resolution}, $resolution,
	   'older retained data determines fallback after expiry');
	ok(defined($chart->{series}->[0]->{values}->{cpu}),
	   'fallback retains data at the requested start');
	}

# A gap at the start of a range is not evidence that fine history expired.
my $gap_dir = tempdir(CLEANUP => 1);
my $gap_store =
	Cloudmin::Statistics->new(directory => $gap_dir, write => 1, host_id =>
									     $host);
my $gap_start = 1_800_000_000;
for my $span ( [ 0, 1200 ], [ 2400, 7200 ] ) {
	for (my $t =
	     $gap_start + $span->[0] ; $t < $gap_start + $span->[1] ;
	     $t += 10) {
		$gap_store->record([ sample($t, $t + 10, { cpu => 25 }) ], [ ],
				   $t + 10);
		}
	}
# Check raw and minute views that begin inside the collection gap.
for my $points ( 600, 60 ) {
	my $chart =
		$gap_store->query($vm, $gap_start + 1800, $gap_start + 5400,
				  $points);
	is($chart->{resolution}, $points == 600 ? 0 : 60,
	   'collection gap keeps the requested resolution');
	ok(!defined($chart->{series}->[0]->{values}->{cpu}),
	   'collection gap remains blank');
	cmp_ok(scalar(grep { defined($_->{values}->{cpu}) } @{$chart->{series}}),
	       '>', 1,
	       'readings after a gap retain multiple chart points');
	}

# Database recreation changes generation while preserving the host identity.
my $old_cursor = $batch->{cursor};
undef $read;
undef $store;
unlink "$dir/metrics.sqlite";
$store =
	Cloudmin::Statistics->new(directory => $dir, write => 1,
				  host_id => $host);
eval { $store->export(60, $old_cursor, 1) };
like($@, qr/expired/, 'recreated database invalidates old cursors');
is($store->{meta}->{host_id}, $host,
   'DB recreation does not change host identity');

# Names and event details cross both UTF-8 libvirt and SQLite boundaries.
my $unicode = "Caf\x{e9} \x{65e5}\x{672c}";
my $named = sample(100, 110, { cpu => 25 });
$named->{label} = encode('UTF-8', $unicode);
$store->record([ $named ],
	       [ { owner => $vm, t => 105, kind => 'configuration', detail =>
									    encode('UTF-8', $unicode) } ], 110);
my $named_result = $store->query($vm, 100, 120, 60);
is($named_result->{entities}->[0]->{label}, $unicode,
   'UTF-8 entity name survives storage');
is($named_result->{events}->[0]->{detail}, $unicode,
   'UTF-8 event detail survives storage');

# SQLite exhaustion rolls back the whole tick, including inventory metadata.
my $before_rows = $store->{db}->selectrow_array('SELECT count(*) FROM samples');
my $pages = $store->{db}->selectrow_array('PRAGMA page_count');
$store->{db}->do('PRAGMA max_page_count='.$pages);
my @many = map {
	my $r = sample(110, 120, { cpu => 25, memory_allocated => 1024 });
	$r->{entity} = "full-$_";
	$r
	} 1 .. 2000;
eval { $store->record(\@many, [ ], 120) };
like($@, qr/full/i, 'full database reports a recording failure');
is($store->{db}->selectrow_array('SELECT count(*) FROM samples'), $before_rows,
   'failed tick leaves history intact');
is(
	$store->{db}->selectrow_array(
		'SELECT count(*) FROM entities WHERE id LIKE ?', undef,
		'full-%'), 0,
	'failed tick rolls back entity metadata too');
# Restoring capacity permits recording without rebuilding valid history.
$store->{db}->do('PRAGMA max_page_count=1000000');
$store->record([ sample(110, 120, { cpu => 25 }) ], [ ], 120);
is($store->{db}->selectrow_array('SELECT count(*) FROM samples'),
   $before_rows + 1, 'recording resumes after storage is available');

# Sampler fixtures verify exact deltas, unknown memory and mapping changes.
my $collector = Cloudmin::StatsCollector->new(interval => 10);
my $machine =
	{ uuid => $vm, name => 'Example', active => 1, state => 'running',
	  runtime_id => 1,
	  vcpus => 2, memory_kib => 2048, disk_targets => [ 'vda' ],
	  disks => [ { target => 'vda', path => '/pool/a',
		       device => 'disk' } ],
	  interfaces => [ { target => 'vnet4',
			    mac => '52:54:00:00:00:01' } ] };

# stats(counter) changes all counter values while retaining
# names and allocation.
sub stats
{
my ($n) = @_;
return { 'cpu.time' => $n * 1e9, 'balloon.current' => 2048,
	 'block.count' => 1, 'block.0.name' => 'vda', 'block.0.capacity' =>
							      1024**3,
	 'block.0.rd.bytes' => $n * 1000, 'block.0.wr.bytes' => $n * 100,
	 'block.0.rd.reqs' => $n * 10, 'block.0.wr.reqs' => $n,
	 'net.count' => 1, 'net.0.name' => 'vnet4',
	 'net.0.rx.bytes' => $n * 200,
	 'net.0.tx.bytes' => $n * 300 };
}
my ($rows, $live) = $collector->vm($machine, stats(10), undef, 100, 1000);
ok(!defined($rows->[0]->{values}->{cpu}), 'first CPU sample unknown');
($rows, $live) = $collector->vm($machine, stats(20), undef, 110, 1010);
is($rows->[0]->{values}->{cpu}, 50, 'CPU normalized to assigned vCPUs');
is($live->{resources}->{disk_read_bytes_sec}, 1000,
   'live data and stored rates agree');
ok(!defined($rows->[0]->{values}->{memory_used}),
   'missing balloon data does not become zero');
is($rows->[2]->{entity}, "$vm/nic/52:54:00:00:00:01",
   'NIC history uses MAC identity');
# A delayed tick retains current gauges but cannot bridge missing counters.
($rows, $live) = $collector->vm($machine, stats(30), undef, 160, 1060);
ok(!defined($rows->[0]->{values}->{cpu_time}),
   'delayed tick does not invent CPU increments');
is($rows->[0]->{end} - $rows->[0]->{start}, 10,
   'late gauge coverage limited to current interval');
is($rows->[0]->{values}->{memory_allocated}, 2048 * 1024,
   'late gauge is still recorded');
($rows, $live) = $collector->vm($machine, stats(40), undef, 170, 1070);
is($rows->[0]->{values}->{cpu}, 50, 'next tick has a fresh baseline');
# A new disk in the same slot preserves history and resets its rate baseline.
$machine->{disks}->[0]->{path} = '/pool/replacement';
($rows, $live) = $collector->vm($machine, stats(100), undef, 180, 1080);
ok(!defined($live->{resources}->{disk_read_bytes_sec}),
   'same-slot replacement resets rates even if counters grow');
is($rows->[1]->{entity}, "$vm/disk/vda", 'replacement retains slot history');
# NIC identity follows the MAC while a changed host mapping resets rates.
$machine->{interfaces}->[0]->{target} = 'vnet9';
my $moved = stats(110);
$moved->{'net.0.name'} = 'vnet9';
($rows, $live) = $collector->vm($machine, $moved, undef, 190, 1090);
is($rows->[2]->{entity}, "$vm/nic/52:54:00:00:00:01",
   'changed host interface retains NIC history');
ok(!defined($live->{resources}->{network_rx_bytes_sec}),
   'NIC mapping change resets baseline');
ok(@{$collector->events()} >= 2, 'device changes produce events');
# Lifecycle events prevent rates from spanning separate guest runs.
$collector->invalidate($vm, 1100, 'reboot', 'Guest reboot');
($rows, $live) = $collector->vm($machine, $moved, undef, 200, 1100);
ok(!defined($live->{resources}->{cpu_percent}),
   'lifecycle event invalidates CPU');

# Partial NOWAIT results invalidate only the affected group and its baselines.
my $complete = stats(120);
$complete->{'net.0.name'} = 'vnet9';
($rows, $live) = $collector->vm($machine, $complete, undef, 210, 1110);
my $missing = stats(130);
$missing->{'net.0.name'} = 'vnet9';
$missing->{'block.count'} = 0;
($rows, $live) = $collector->vm($machine, $missing, undef, 220, 1120);
ok(!defined($live->{resources}->{disk_read_bytes_sec}),
   'missing disk makes disk total unknown');
is($live->{resources}->{network_rx_bytes_sec}, 200,
   'missing disk does not invalidate network');
# A returning disk needs two complete reads before rates can resume.
$complete = stats(140);
$complete->{'net.0.name'} = 'vnet9';
($rows, $live) = $collector->vm($machine, $complete, undef, 230, 1130);
ok(!defined($live->{resources}->{disk_read_bytes_sec}),
   'returning disk starts a new baseline');
$complete = stats(150);
$complete->{'net.0.name'} = 'vnet9';
($rows, $live) = $collector->vm($machine, $complete, undef, 240, 1140);
is($live->{resources}->{disk_read_bytes_sec}, 1000,
   'disk rate resumes on the following interval');
# Counter rollback must produce unknown rates instead of negative usage.
$complete = stats(1);
$complete->{'net.0.name'} = 'vnet9';
($rows, $live) = $collector->vm($machine, $complete, undef, 250, 1150);
ok(!defined($live->{resources}->{cpu_percent}),
   'decreased CPU counter does not become negative or zero');
ok(!defined($live->{resources}->{disk_read_bytes_sec}),
   'decreased device counter does not create a spike');

# Host uplink selection counts each layer once and rejects unsafe overrides.
my $sys = tempdir(CLEANUP => 1);
make_path(
	map { "$sys/$_" } qw(eth0/device eth1/device bond0/bonding br0 vnet0 lo));
symlink('../bond0', "$sys/eth0/master");
symlink('../eth0', "$sys/bond0/lower_eth0");
symlink('../bond0', "$sys/br0/lower_bond0");
is_deeply(Cloudmin::StatsCollector::uplinks($sys, ''), [ 'bond0', 'eth1' ],
	  'automatic boundary excludes guests and bond members');
is_deeply(Cloudmin::StatsCollector::uplinks($sys, 'br0 eth1'), [ 'br0',
								 'eth1' ],
	  'explicit independent bridge and port allowed');
eval { Cloudmin::StatsCollector::uplinks($sys, 'br0 eth0') };
like($@, qr/Overlapping/,
     'recursive upper and lower interface overlap rejected');
eval { Cloudmin::StatsCollector::uplinks($sys, 'vnet0') };
like($@, qr/Guest/, 'guest tap is not a host uplink');
eval { Cloudmin::StatsCollector::uplinks($sys, 'missing') };
like($@, qr/Unknown/, 'unknown configured uplink is not silently ignored');

# Cache staleness affects readings, not their host identity
# or error diagnostics.
Cloudmin::Statistics::atomic_write("$dir/statistics-latest.json",
				   JSON::PP->new->encode({ version => 1,
							   checked_at => 1000,
							   interval => 10,
							   host_id => $host,
							   vms => { $vm => { resources => { cpu_percent => 90 } } },
							   host => { } }));
ok(Cloudmin::Statistics::latest($dir, 1010)->{vms}->{$vm},
   'fresh cache readable');
is_deeply(Cloudmin::Statistics::latest($dir, 1040)->{vms}, { },
	  'expired cache hides old readings');
is_deeply(Cloudmin::Statistics::latest($dir, 900)->{vms}, { },
	  'clock reversal hides future readings');
# Live-cache UTF-8 decoding must agree with the history reader.
Cloudmin::Statistics::atomic_write("$dir/statistics-latest.json",
				   JSON::PP->new->utf8->encode({
					   version => 1, checked_at => 1000,
					   interval => 10,
					   host => { label => $unicode },
					   vms => { } }));
is(Cloudmin::Statistics::latest($dir, 1010)->{host}->{label}, $unicode,
   'UTF-8 live cache decodes once');

done_testing();
