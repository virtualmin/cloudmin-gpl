use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib", "$Bin/../lib";
use CloudminTest;
use Cloudmin::Libvirt;
use Cloudmin::StatsCollector;
use File::Temp qw(tempdir);
use JSON::PP;
use Test::More;
use subs qw(time);

# Exercise the daemon's actual refresh and sampling paths without opening
# libvirt, forking workers or installing a service on the test workstation.
open(my $fh, '<', "$Bin/../statistics-collector.pl") or die $!;
my $source = do { local $/; <$fh> };
my ($functions) =
	$source =~ /(sub collect_domain\n\{.*?)\n# connect_statistics/s;
my ($tick) =
	$source =~ /^([\t ]+my \$ok\s*=\s*eval \{.*?)^[\t ]+my \$host_ok\s*=\s*eval/ms;
die 'Statistics collection sections not found' unless $functions && $tick;
our ($adapter, $connection, $sampler, $settings, %vms, %guests, %due,
     %failures,
     %generation, %dirty, $next_inventory, $pools, $pool_states, $pool_checked_at, $next_pools, $clock,
     $wall_clock);

# time(), clock_gettime(kind) and CLOCK_MONOTONIC() supply a controlled tick.
sub time
{
return $wall_clock;
}

sub clock_gettime
{
return $clock;
}

sub CLOCK_MONOTONIC ()
{
1;
}

# error_message(error) keeps fixture failures readable without Webmin startup.
sub error_message
{
return "$_[0]";
}
eval $functions.'; 1' or die $@;

{
	package CollectorDomain;

	# get_uuid_string(self) simulates an identity read racing with deletion.
	sub get_uuid_string
	{
	die "Guest identity unavailable\n" if $_[0]->{fail} eq 'identity';
	return $_[0]->{id};
	}

	# get_info(self) supplies counters or a failure from
	# a strict record read.
	sub get_info
	{
	$_[0]->{reads}++;
	die "Guest disappeared\n" if $_[0]->{fail} eq 'record';
	return { state => 1, memory => 1048576, maxMem => 1048576, nrVirtCpu =>
									   2 };
	}

	# is_active(self), is_persistent(self) and get_name(self)
	# describe this guest.
	sub is_active
	{
	return 1;
	}

	sub is_persistent
	{
	return 0;
	}

	sub get_name
	{
	return $_[0]->{id};
	}

	# get_xml_description(self, flags) fails after the initial strict read.
	sub get_xml_description
	{
	die "Guest XML unavailable\n" if $_[0]->{fail} eq 'xml' &&
		++$_[0]->{xml_reads} % 2 == 0;
	return '<domain><devices><memballoon><stats period="10"/>'.
	       '</memballoon></devices></domain>';
	}

	# get_id(self) can fail after XML has already been read.
	sub get_id
	{
	die "Guest runtime ID unavailable\n" if $_[0]->{fail} eq 'runtime';
	return 1;
	}

	package CollectorConnection;

	# list_all_domains(self, flags) can fail at the connection level.
	sub list_all_domains
	{
	die "Inventory connection lost\n" if $_[0]->{fail} eq 'inventory';
	return @{$_[0]->{domains}};
	}

	# get_domain_by_uuid(self, id) simulates a guest removed after an event.
	sub get_domain_by_uuid
	{
	my ($self, $id) = @_;
	my ($domain) = grep { $_->{id} eq $id } @{$self->{domains}};
	die "Guest lookup failed\n" if !$domain || $domain->{fail} eq 'lookup';
	return $domain;
	}

	package CollectorAdapter;
	our @ISA = ('Cloudmin::Libvirt');

	# get_resource_stats(self) returns increasing CPU
	# counters for real sampling.
	sub get_resource_stats
	{
	my ($self) = @_;
	$self->{bulk}++;
	die "Bulk connection lost\n" if $self->{connection}->{fail} eq 'bulk';
	return { map { $_->{id} =>
		{ 'cpu.time' => $main::clock * 1e9, 'vcpu.current' => 2,
		  'vcpu.0.delay' => $main::clock * 1e8,
		  'vcpu.1.delay' => $main::clock * 1e8,
		  'vcpu.0.wait' => 0, 'vcpu.1.wait' => 0 } }
		 @{$self->{connection}->{domains}} };
	}

	# disconnect(self) records whether one guest interrupted
	# the shared connection.
	sub disconnect
	{
	$_[0]->{disconnects}++;
	}

	# list_storage_pools(self) returns two pools on one filesystem, a volume
	# group and an inactive pool, without touching libvirt.
	sub list_storage_pools
	{
	$_[0]->{pool_reads}++;
	return [
		{ uuid => 'p1', name => 'default', type => 'dir', target =>
									  '/var/lib/libvirt/images',
		  active => 1, active_known => 1, capacity => 100, allocation => 40,
		  available => 60, fsid => 'f1' },
		{ uuid => 'p2', name => 'iso', type => 'dir', target =>
								      '/var/lib/libvirt/iso',
		  active => 1, active_known => 1, capacity => 100, allocation => 40,
		  available => 60, fsid => 'f1' },
		{ uuid => 'p3', name => 'vg0', type => 'logical', active => 1, active_known => 1,
		  capacity => 50, allocation => 10, available => 40 },
		{ uuid => 'p4', name => 'old', type => 'dir', active => 0, active_known => 1,
		  capacity => 7, allocation => 7, available => 0 },
	];
	}
	}

# fixture() starts with two measured guests and pending data
# for the failing one.
sub fixture
{
%vms = ();
%dirty = ();
%guests = ();
%due = ();
%failures = ();
%generation = ();
$pools = $pool_states = $pool_checked_at = undef;
$next_pools = 0;
$clock = 100;
$wall_clock = 1700000000;
$settings = { interval => 10 };
$sampler = Cloudmin::StatsCollector->new(interval => 10);
$connection = bless { fail => '', domains => [ map {
	bless { id => $_, fail => '', reads => 0, xml_reads =>
							  0 }, 'CollectorDomain'
	} qw(bad healthy) ] }, 'CollectorConnection';
$adapter = bless { connection => $connection, bulk => 0, disconnects => 0 },
	   'CollectorAdapter';
run_tick(0);
# Seed stale probe data so failures must clear it and reject pending replies.
$guests{bad} = { checked_at => $wall_clock, filesystem_used_bytes => 42 };
$due{bad} = $clock + 60;
$failures{bad} = 2;
$generation{bad} = 3;
return ( $connection->{domains}->[0], $adapter );
}

# run_tick(next_inventory) executes the daemon's collection block at this time.
# It returns readings, errors and the next full-inventory deadline.
sub run_tick
{
# The deadline is shared with refresh_domain, which can bring it forward.
($next_inventory) = @_;
my ($mono, $wall) = ( $clock, $wall_clock );
my $next_sample = $mono + 10;
my %config = ( libvirt_uri => 'qemu:///system' );
my @subscriptions;
my $pending = [ 'bad', 3, $clock ];
my ($rows, $live) = ( [ ], { } );
my @errors;
my $complete;
eval $tick.'; $complete=$guests_complete; 1' or die $@;
return { rows => $rows, live => $live, errors => \@errors, next_inventory =>
								   $next_inventory,
	 guests_complete => $complete ? 1 : 0 };
}

# advance() moves both clocks equally, preserving valid counter intervals.
sub advance
{
$clock += 10;
$wall_clock += 10;
}

# Every read stage can fail without erasing healthy guests
# or reusing stale data.
for my $path ( 'inventory', 'event' ) {
	for my $failure ( 'record', 'xml', 'runtime' ) {
		subtest "$path $failure failure" => sub {
			my ($bad, $saved_adapter) = fixture();
			$bad->{fail} = $failure;
			$dirty{bad} = 1;
			advance();
			my $result = run_tick($path eq 'inventory'
				? 0
				: $clock + 60);
			is($saved_adapter->{bulk}, 2,
			   'healthy guests still reach the bulk read');
			is($saved_adapter->{disconnects}, 0,
			   'guest failure keeps the connection');
			is(
				$result->{live}->{healthy}->{resources}->{cpu_percent}, 50,
				'healthy CPU baseline continues across the failed read');
			is(
				$result->{live}->{healthy}->{resources}->{cpu_wait_percent}, 10,
				'vCPU wait is reported as a share of the guest CPUs');
			# Only the failed guest loses its published values
			# and counter baseline.
			ok(!exists($result->{live}->{bad}),
			   'failed guest has no stale readings');
			ok(!$result->{guests_complete},
			   'partial guest inventory cannot publish allocation totals');
			ok(!exists($sampler->{previous}->{bad}),
			   'failed guest baseline discarded');
			ok(!exists($guests{bad}) && !exists($due{bad}),
			   'failed guest loses stale probe data and scheduling');
			# Generation changes reject late worker replies without
			# affecting healthy VMs.
			cmp_ok($generation{bad}, '>', 3,
			       'pending probe reply cannot reappear after recovery');
			ok($dirty{bad}, 'failed guest is queued for retry');
			like(join('', @{$result->{errors}}),
			     qr/Guest bad inventory failed:/,
			     'diagnostics identify the affected guest');
			my $events = $sampler->events();
			is_deeply([ map { $_->{owner} } @$events ], [ 'bad' ],
				  'outage affects only one guest');
			is($bad->{reads}, 2,
			   'failed guest is attempted only once in a tick');

			# Repeated failures do not flood
			# history with outage events.
			advance();
			$result = run_tick($clock + 60);
			is(
				$result->{live}->{healthy}->{resources}->{cpu_percent}, 50,
				'healthy guest continues through repeated failures');
			is_deeply($sampler->events(), [ ],
				  'same outage has no duplicate event');

			# A recovered guest starts fresh while other
			# guests retain their rates.
			$bad->{fail} = '';
			advance();
			$result = run_tick($clock + 60);
			ok(exists($result->{live}->{bad}),
			   'guest recovers on the next retry');
			ok($result->{guests_complete},
			   'complete inventory restores guest allocation totals');
			ok(
				!defined(
					$result->{live}->{bad}->{resources}->{cpu_percent}),
				'recovery does not calculate a rate across the gap');
			ok(!$dirty{bad}, 'successful refresh clears its retry');
			advance();
			$result = run_tick($clock + 60);
			is($result->{live}->{bad}->{resources}->{cpu_percent},
			   50,
			   'next interval restores the recovered guest rate');
			};
		}
	}

# A guest missing after an event is most likely deleted. The next full inventory
# settles it, without a published error, an outage event or an event retry.
{
	my ($bad, $saved_adapter) = fixture();
	$bad->{fail} = 'lookup';
	$dirty{bad} = 1;
	advance();
	my $result = run_tick($clock + 60);
	is($saved_adapter->{bulk}, 2,
	   'healthy guests still reach the bulk read');
	is($result->{live}->{healthy}->{resources}->{cpu_percent}, 50,
	   'healthy CPU baseline continues across the failed lookup');
	ok(!exists($result->{live}->{bad}),
	   'missing guest publishes no stale readings');
	ok(!$result->{guests_complete},
	   'unconfirmed removal cannot lower guest allocation totals');
	is_deeply($result->{errors}, [ ],
		  'a missing guest is not a collection error');
	is_deeply($sampler->events(), [ ],
		  'a missing guest records no outage event');
	is($result->{next_inventory}, 0,
	   'missing guest brings the full inventory forward');
	ok(!$dirty{bad},
	   'missing guest is not retried through the event queue');
	ok(!exists($guests{bad}) && !exists($due{bad}),
	   'missing guest loses stale probe data and scheduling');
	cmp_ok($generation{bad}, '>', 3,
	       'pending probe reply cannot reappear after recovery');
	# A transient lookup failure recovers through the inventory
	# with its rate intact.
	$bad->{fail} = '';
	advance();
	$result = run_tick($result->{next_inventory});
	is($result->{live}->{bad}->{resources}->{cpu_percent}, 50,
	   'inventory restores a surviving guest without a rate gap');
	is_deeply($sampler->events(), [ ],
		  'recovery through inventory records no event');
	}

# Missing identities cannot turn an incomplete inventory into removal events.
{
	my ($bad, $saved_adapter) = fixture();
	$bad->{fail} = 'identity';
	advance();
	my $result = run_tick(0);
	is($result->{live}->{healthy}->{resources}->{cpu_percent}, 50,
	   'unidentified guest does not interrupt known healthy guests');
	is($result->{next_inventory}, $clock + 10,
	   'incomplete inventory is retried next tick');
	is_deeply($sampler->events(), [ ],
		  'incomplete identity list proves no removals');
	is($saved_adapter->{disconnects}, 0,
	   'identity error keeps shared connection');
	}

# A confirmed deletion removes the failed guest and its retry state.
{
	my ($bad, $saved_adapter) = fixture();
	$connection->{domains} =
		[ grep { $_->{id} ne 'bad' } @{$connection->{domains}} ];
	advance();
	run_tick(0);
	ok(!exists($vms{bad}) && !exists($sampler->{signatures}->{bad}),
	   'complete inventory removes absent guest');
	ok(!$dirty{bad}, 'deleted guest is not retried');
	is_deeply([ map { $_->{kind} } @{$sampler->events()} ], [ 'removed' ],
		  'confirmed deletion records removal');
	}

# Failures of shared operations must still reconnect and discard all baselines.
for my $failure ( 'inventory', 'bulk' ) {
	my ($bad, $saved_adapter) = fixture();
	$connection->{fail} = $failure;
	advance();
	my $result = run_tick(0);
	is($saved_adapter->{disconnects}, 1,
	   "$failure failure disconnects libvirt");
	ok(!$connection && !$adapter,
	   "$failure failure permits reconnect next tick");
	is_deeply($result->{live}, { },
		  "$failure failure publishes no stale guest values");
	is_deeply([ sort map { $_->{owner} } @{$sampler->events()} ],
		  [ qw(bad healthy) ],
		  "$failure failure invalidates all affected guests");
	}

# Storage pools follow the inventory cadence: listed once, reused for a minute.
{
	my ($bad, $saved_adapter) = fixture();
	is_deeply([ map { $_->{name} } @$pools ], [ qw(default iso vg0) ],
		  'active storage pools are listed with the inventory');
	is_deeply([ map { [ $_->{name}, $_->{active} ] } @$pool_states ],
		[ [ 'default', 1 ], [ 'iso', 1 ], [ 'vg0', 1 ], [ 'old', 0 ] ],
		'health inventory retains inactive pools separately from usage');
	is($pool_checked_at, $wall_clock, 'health inventory records its own freshness');
	advance();
	run_tick(0);
	is($saved_adapter->{pool_reads}, 1,
	   'pools are not listed again within a minute');
	$next_pools = $clock;
	advance();
	run_tick(0);
	is($saved_adapter->{pool_reads}, 2,
	   'pools are listed again once their minute passes');
	}

# Host readings come from proc files. A fixture tree stands in for the kernel.
{
	my $root = tempdir(CLEANUP => 1);
	mkdir "$root/proc";
	mkdir "$root/sys";
	my %files = ( loadavg => "0.42 0.38 0.35 1/234 5678\n",
		      stat =>
			      "cpu  100 0 50 800 10 0 5 0 0 0\ncpu0 50 0 25 400 5 0 2 0 0 0\ncpu1 50 0 25 400 5 0 3 0 0 0\n",
		      meminfo =>
			      "MemTotal:       8000000 kB\nMemAvailable:   6000000 kB\n" );
	for my $name (keys %files) {
		open(my $out, '>', "$root/proc/$name") or die $!;
		print $out $files{$name};
		close($out);
		}
	# Read real parser output from fixture proc files,
	# including numeric JSON.
	my $reader = Cloudmin::StatsCollector->new(interval => 10);
	my ($rows, $live) =
		$reader->host('host', 100, 1700000000,
			      { proc => "$root/proc", sys => "$root/sys" });
	is_deeply(
		[ @{
			$rows->[0]->{values}}{qw(load_1 load_5 load_15 vcpus memory_used)} ],
		[ 0.42, 0.38, 0.35, 2, 2048000000 ],
		'host load averages are read beside CPU and memory');
	is(JSON::PP->new->encode([ $live->{values}->{load_1} ]), '[0.42]',
	   'live host values carry the one-minute load as a number');
	# A missing kernel reading must remain unknown on the next tick.
	unlink "$root/proc/loadavg";
	($rows) =
		$reader->host('host', 110, 1700000010,
			      { proc => "$root/proc", sys => "$root/sys" });
	ok(!exists($rows->[0]->{values}->{load_1}),
	   'a missing loadavg leaves the load unmeasured');
	# Running guests and active pools add allocation and storage totals; two
	# pools on one filesystem count its space once.
	my $guests =
		{ a =>
			  { active => 1,
			    resources => { vcpus => 2,
					   memory_bytes => 1024 } },
		  b =>
			  { active => 1, resources =>
						 { vcpus => 4,
						   memory_bytes => 4096 } },
		  c =>
			  { active => 0, resources =>
						 { vcpus => 8,
						   memory_bytes => 8192 } } };
	my $listed =
		[ grep { $_->{active} } @{bless({ },
						'CollectorAdapter')->list_storage_pools()} ];
	($rows, $live) =
		$reader->host('host', 120, 1700000020,
			      { proc => "$root/proc", sys => "$root/sys",
				guests => $guests,
				pools => $listed });
	is_deeply(
		[ @{
			$rows->[0]->{values}}{qw(guest_vcpus guest_memory storage_total storage_used)} ],
		[ 6, 5120, 150, 50 ],
		'host totals count running guests and distinct filesystems');
	is_deeply([ map { $_->{name} } @{$live->{pools}} ],
		  [ qw(default iso vg0) ],
		  'live host values carry the active pools');
	# Missing inventory must not publish partial
	# allocation or storage totals.
	($rows) =
		$reader->host('host', 130, 1700000030,
			      { proc => "$root/proc", sys => "$root/sys" });
	ok(!exists($rows->[0]->{values}->{guest_vcpus}) &&
	   !exists($rows->[0]->{values}->{storage_total}),
	   'host totals are unmeasured without guest and pool readings');
	}

done_testing();
