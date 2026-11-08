use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";
use CloudminTest;
use Test::More;
use Cloudmin::Libvirt;
use Cloudmin::Status;

my $id = '11111111-2222-3333-4444-555555555555';
my $vm = { uuid => $id, active => 1, state => 'running', vcpus => 2,
	   memory_kib => 1024 * 1024, disk_targets => [ 'vda', 'vdc' ] };
my $stats = { 'cpu.time' => 1_000_000_000, 'vcpu.current' => 2,
	      'balloon.current' => 1024 * 1024, 'balloon.available' => 1000000,
	      'balloon.usable' => 685427.2, 'balloon.last-update' => 100,
	      'block.count' => 3, 'block.0.name' => 'vda',
	      'block.0.capacity' => 8 * 1024**3,
	      'block.1.name' => 'vdb', 'block.1.capacity' => 1024**2,
	      'block.2.name' => 'vdc', 'block.2.capacity' => 2 * 1024**3,
	      'block.0.rd.bytes' => 1000, 'block.1.rd.bytes' => 0,
	      'block.2.rd.bytes' => 0,
	      'net.count' => 1, 'net.0.rx.bytes' => 1000 };
my $metrics = Cloudmin::Metrics->new();
# CPU and I/O rates need two samples; memory usage uses current counters.
my $sample = $metrics->sample($vm, $stats, 1, 100);
ok(!defined($sample->{cpu_percent}), 'CPU needs two samples');
is($sample->{memory_percent}, 30,
   'RAM excludes reclaimable cache and uses assigned capacity');
is($sample->{disk_capacity_bytes}, 10 * 1024**3,
   'writable disk capacities total correctly, excluding the seed');
$stats = { %$stats, 'cpu.time' => 1_160_000_000, 'net.0.rx.bytes' => 11240,
	   'block.0.rd.bytes' => 21480 };
$sample = $metrics->sample($vm, $stats, 11, 110);
is($sample->{cpu_percent}, 0.8, 'CPU is normalized to both assigned CPUs');
is($sample->{network_rx_bytes_sec}, 1024,
   'network counters become a per-second rate');
is($sample->{disk_read_bytes_sec}, 2048,
   'disk counters become a per-second rate');
# Counter resets, stale balloon data and partial disks must stay unavailable.
$sample = $metrics->sample($vm,
			   { %$stats, 'cpu.time' => 5, 'net.0.rx.bytes' => 0 },
			   21, 120);
ok(!defined($sample->{cpu_percent}),
   'reset CPU counters never produce negative usage');
ok(!defined($sample->{network_rx_bytes_sec}),
   'reset network counters stay unavailable');
$sample = $metrics->sample($vm, $stats, 31, 170);
ok(!defined($sample->{memory_percent}),
   'stale balloon reports are not current usage');
$sample = $metrics->sample($vm, { 'balloon.rss' => 1048576 }, 41, 180);
ok(!defined($sample->{memory_percent}),
   'host RSS never stands in for guest RAM usage');
ok(!defined($sample->{disk_capacity_bytes}),
   'missing disk statistics never look like zero-sized disks');
$sample = $metrics->sample($vm, { %$stats, 'block.2.capacity' => undef }, 51,
			   110);
ok(!defined($sample->{disk_capacity_bytes}),
   'partial disk totals stay unavailable');
$metrics->forget($id);
$sample = $metrics->sample($vm, $stats, 61, 110);
ok(!defined($sample->{cpu_percent}),
   'lifecycle invalidation resets the CPU baseline');
$sample = $metrics->sample($vm, $stats, 161, 110);
ok(!defined($sample->{cpu_percent}),
   'resuming after a long pause starts a fresh baseline');

# Guest filesystem fixtures include repeated mounts, a second disk
# and read-only media.
{
	package ResourceDomain;

	# get_name(self) supplies a fixed guest name for adapter lookup.

	sub get_name
	{
	return 'resource-fixture';
	}

	# get_uuid_string(self) returns the same identity as
	# the sampled counters.

	sub get_uuid_string
	{
	return $_[0]->{uuid};
	}

	# is_active(self) permits guest-agent sampling in this fixture.

	sub is_active
	{
	return 1;
	}

	# get_xml_description(self, [flags]) maps two writable disks
	# and read-only media.

	sub get_xml_description
	{
	return q{<domain><devices>
		<disk device='disk'><target dev='vda'/><alias name='disk0'/></disk>
		<disk device='disk'><target dev='vdc'/><alias name='disk2'/></disk>
		<disk device='disk'><target dev='vdb'/><alias name='seed'/><readonly/></disk>
		</devices></domain>};
	}

	# set_agent_response_timeout(self, seconds, flags) records
	# timeout restoration.

	sub set_agent_response_timeout
	{
	push(@{$_[0]->{timeouts}}, $_[1]);
	}

	# get_guest_info(self, types, flags) returns data or
	# simulates agent failure.

	sub get_guest_info
	{
	die "Agent unavailable\n" if ($_[0]->{fail});
	return $_[0]->{info};
	}
	package ResourceConnection;

	# list_all_domains(self, [flags]) supplies the single sampled domain.

	sub list_all_domains
	{
	return $_[0]->{domain};
	}

	# get_domain_by_uuid(self, uuid) resolves the fixture without libvirt.

	sub get_domain_by_uuid
	{
	return $_[0]->{domain};
	}

	# get_all_domain_stats(self, mask, domains, flags)
	# records batch selection.

	sub get_all_domain_stats
	{
	my ($self, $mask, $domains, $flags) = @_;
	push(@{$self->{calls}}, [ $mask, $domains, $flags ]);
	return ({ dom => $self->{domain}, data => $self->{stats} });
	}
	}
my $info = { 'fs.count' => 5, 'os.pretty-name' => '<Guest Linux>',
	     'hostname' => 'guest.test',
	     'os.kernel-release' => '6.12' };
for my $entry ( [ 0, 'vda1', '/', 1000, 300, 'disk0' ],
		[ 1, 'vdc1', '/data', 2000, 400, 'disk2' ],
		[ 2, 'vda1', '/bind', 1000, 300, 'disk0' ],
		[ 3, 'vdb', '/seed', 100, 100, 'seed' ],
		[ 4, 'tmpfs', '/run', 100, 100, undef ] ) {
	my ($i, $name, $mount, $total, $used, $alias) = @$entry;
	$info->{"fs.$i.$_"} = { name => $name, mountpoint => $mount,
				'total-bytes' => $total,
				'used-bytes' => $used, fstype => 'ext4',
				'disk.count' => defined($alias) ? 1 : 0,
				'disk.0.alias' => $alias }->{$_}
		for qw(name mountpoint total-bytes used-bytes fstype disk.count
		       disk.0.alias);
	}
my $domain = bless { uuid => $id, info => $info }, 'ResourceDomain';
my $connection = bless { domain => $domain, stats => $stats, calls => [ ] },
		 'ResourceConnection';
my $adapter = Cloudmin::Libvirt->new(connection_factory => sub { $connection });
my $guest = $adapter->get_guest_resources($id);
is($guest->{filesystem_used_bytes}, 700,
   'both writable filesystems count once; seed and tmpfs do not');
is($guest->{filesystem_total_bytes}, 3000,
   'filesystem size is distinct from raw disk capacity');
is(scalar(@{$guest->{filesystems}}), 3,
   'details retain mounted disk filesystems, deduplicated by device');
is($guest->{os}, '<Guest Linux>', 'OS text is retained for safe rendering');
ok(!@{$domain->{timeouts} || [ ]},
   'resource reads do not change the shared domain agent timeout');
$info->{'fs.1.disk.0.alias'} = undef;
$guest = $adapter->get_guest_resources($id);
ok(!defined($guest->{filesystem_used_bytes}),
   'unknown disk mappings do not invent an aggregate');
$info->{'fs.1.disk.0.alias'} = 'disk2';
$info->{'fs.1.used-bytes'} = undef;
$guest = $adapter->get_guest_resources($id);
ok(!defined($guest->{filesystem_used_bytes}),
   'partial filesystem reports cannot understate usage');
$domain->{fail} = 1;
ok(!eval { $adapter->get_guest_resources($id); 1 },
   'missing guest agent is an explicit failure');
ok(!@{$domain->{timeouts} || [ ]},
   'agent failures leave the shared domain timeout unchanged');
is_deeply($adapter->get_resource_stats(), { $id => $stats },
	  'bulk API return shape is decoded');
is($connection->{calls}->[-1]->[2], 1 << 29, 'bulk statistics use NOWAIT');
ok(!defined($connection->{calls}->[-1]->[1]),
   'overview uses a single host-wide call');
$adapter->get_resource_stats([ $id ]);
is(scalar(@{$connection->{calls}->[-1]->[1]}), 1,
   'detail-only viewers query their VM subset');

# One collector scales by VMs, not viewer count, and stops
# work for hidden pages.
my $cache = Cloudmin::Status->new();
my @clients = map { { id => 'overview' } } 1 .. 10;
my @ids = map { sprintf('00000000-0000-0000-0000-%012d', $_) } 1 .. 100;
$cache->record({ %$vm, uuid => $_ }) for @ids;
is(scalar(@{$cache->resource_ids(\@clients)}), 100,
   'ten viewers share one set of 100 targets');
my $first = $cache->next_guest_probe(\@clients, 100);
$cache->guest_checked($first, { filesystem_used_bytes => 1 }, 100);
ok(!defined($cache->next_guest_probe(\@clients, 100.5)),
   'slow queries are capped at one per second');
isnt($cache->next_guest_probe(\@clients, 101), $first,
     'slow checks move to the next guest fairly');
$_->{paused} = 1 for @clients;
is_deeply($cache->resource_ids(\@clients), [ ],
	  'hidden viewers need no resource batch');
ok(!defined($cache->next_guest_probe(\@clients, 102)),
   'hidden overview does not probe filesystems');
$cache->sampled([ $first ], { $first => $stats }, 1, 100);
my $client = { id => $first };
my $message = $cache->message($client);
ok(exists($message->{changed}->{$first}->{resources}),
   'resource metrics travel on the existing socket');
$cache->sampled([ $first ], { }, 11, 401);
ok(!exists($cache->{guest}->{$first}),
   'old guest data expires even when the worker cannot refresh it');
$cache->invalidate($first);
ok(!exists($cache->{resources}->{$first}), 'reboot drops prior resource usage');
$cache->remove($first);
$cache->guest_checked($first, { filesystem_used_bytes => 1 }, 402);
ok(!exists($cache->{guest}->{$first}),
   'late guest data cannot resurrect a deleted VM');

done_testing();
