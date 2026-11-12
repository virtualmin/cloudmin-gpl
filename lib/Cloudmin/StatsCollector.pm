package Cloudmin::StatsCollector;

# Sampling state is independent of SQLite and of Webmin request lifetimes.
use strict;
use warnings;
use WebminCore qw(convert_to_json);
use List::Util qw(min max sum);
use File::Basename qw(dirname);
require(dirname(__FILE__).'/Metrics.pm');

# new(class, [interval => seconds]) creates fresh counter baselines. The default
# interval is 10 seconds.
sub new
{
my ($class, %args) = @_;
return bless { interval => $args{interval} || 10, previous => { }, signatures =>
									   { },
	       events => [ ], metrics => Cloudmin::Metrics->new() }, $class;
}

# invalidate(self, owner, time, kind, detail) records a baseline boundary.
sub invalidate
{
my ($self, $owner, $wall, $kind, $detail) = @_;
delete $self->{previous}->{$_} for grep { $_ eq $owner ||
	index($_, "$owner/") == 0 }
	keys %{$self->{previous}};
$self->{metrics}->forget($owner);
push @{$self->{events}},
	{ owner => $owner, t => $wall, kind => $kind, detail => $detail };
}

# events(self) drains queued changes for the caller's next history write. The
# queue is cleared even when history recording is disabled or later fails.
sub events
{
my ($self) = @_;
my $events = $self->{events};
$self->{events} = [ ];
return $events;
}

# row(self, identity, gauges, counters, monotonic, wall) converts one entity.
# Counter keys use normalized metric names. Missing, reset or delayed values
# remain absent; current gauges still have a bounded observation interval.
sub row
{
my ($self, $identity, $gauges, $counters, $mono, $wall) = @_;
my $id = $identity->{entity};
my $old = $self->{previous}->{$id};
my $dt = $old ? $mono - $old->{mono} : 0;
# Rates need nearby monotonic samples and a consistent wall clock.
my $valid = $old && $dt > 0 && $dt <= 3 * $self->{interval} &&
	    abs(($wall - $old->{wall}) - $dt) < 2;
my %values = %$gauges;
# Only consecutive valid readings can establish a counter increment.
if ($valid) {
	for my $key (keys %$counters) {
		my ($a, $b) = ( $old->{counters}->{$key}, $counters->{$key} );
		# A missing or decreased counter starts a new baseline
		# rather than a zero rate.
		next if !defined($a) || !defined($b) || $b < $a;
		$values{$key} = ($b - $a) / $dt;
		}
	}
# After a gap, gauges cover at most one tick. Always remember the new baseline.
my $duration = $valid
	? $dt
	: $old ? min($self->{interval}, max(0, $wall - $old->{wall})) : 0;
$self->{previous}->{$id} =
	{ mono => $mono, wall => $wall, counters => $counters };
return { %$identity, start => $wall - $duration, end => $wall, values =>
								       \%values };
}

# vm(self, vm, bulk_stats, guest_cache, monotonic, wall) returns rows and live
# data. XML supplies disk slots and NIC MACs. Runtime names can change between
# boots. Pass undef for guest_cache when no filesystem probe
# result is available.
sub vm
{
my ($self, $vm, $stats, $guest, $mono, $wall) = @_;
my $id = $vm->{uuid};
my $signature = convert_to_json([
	$vm->{active}, $vm->{state}, $vm->{runtime_id},
	[ map { [ @{$_}{qw(target path pool volume)} ] }
	  @{$vm->{disks} || [ ]} ],
	[ map { [ @{$_}{qw(mac target)} ] } @{$vm->{interfaces} || [ ]} ]
], 0, 1, 1);
# Power or device changes invalidate all rates for this guest.
if (defined($self->{signatures}->{$id}) &&
    $self->{signatures}->{$id} ne $signature) {
	$self->invalidate($id, $wall, 'configuration',
			  'Power state or device attachment changed');
	}
my %sources =
	map { $_->{target} => $_->{path} ||
		join('/', $_->{pool} || '', $_->{volume} || '') }
	grep { $_->{target} } @{$vm->{disks} || [ ]};
# Record disk source changes only after an initial mapping has been established.
if ($self->{sources}->{$id}) {
	my %slots = ( %sources, %{$self->{sources}->{$id}} );
	for my $slot (keys %slots) {
		my $old = $self->{sources}->{$id}->{$slot};
		my $new = $sources{$slot};
		# Unchanged slots need no event. Paths describe changes
		# without becoming identity.
		next if defined($old) && defined($new) && $old eq $new;
		my $detail = !defined($old)
			? "Disk $slot attached from $new"
			: !defined($new)
				? "Disk $slot detached from $old"
				: "Disk $slot source changed from $old to $new";
		push @{$self->{events}},
			{ owner => $id, t => $wall, kind => 'disk-source',
			  detail => $detail };
		}
	}
$self->{sources}->{$id} = \%sources;
$self->{signatures}->{$id} = $signature;
my $live = $self->{metrics}->sample($vm, $stats, $mono, $wall);
# Replace the legacy rate fields with rates using these shared baselines.
delete @{
	$live}{qw(cpu_percent network_rx_bytes_sec network_tx_bytes_sec disk_read_bytes_sec disk_write_bytes_sec)};
my %gauges =
	( vcpus => $live->{vcpus}, memory_allocated => $live->{memory_bytes},
	  memory_used => $live->{memory_used_bytes}, disk_capacity =>
							     $live->{disk_capacity_bytes} );
# Expose probe availability separately so notifications need no raw error text.
my $agent_checked = $guest ? $guest->{checked_at} : undef;
my $agent_available = $guest && $agent_checked
	? ($guest->{error} ? 0 : 1) : undef;
# Filesystem gauges expire independently of CPU and disk counter readings.
if ($guest && !$guest->{error} &&
    $wall - ($guest->{checked_at} || 0) <= max(300,
					       2 * ($self->{guest_interval} || 60))) {
	@gauges{qw(filesystem_total filesystem_used)} =
		@{
			$guest}{qw(filesystem_total_bytes filesystem_used_bytes)};
	}
# An expired or failed agent probe cannot remain visible as
# current filesystem data.
else { $guest = undef; }
my %counters;
# Stopped guests cannot supply a running CPU counter.
$counters{cpu_time} = $stats->{'cpu.time'} / 1e9 if $vm->{active} &&
		      defined($stats->{'cpu.time'});
# Per-vCPU delay records time waiting in the host run queue. It can indicate
# host CPU contention. Prefer delay to the older wait counter, which requires
# cgroup v1 and otherwise reports zero.
my @wait = map { $stats->{"vcpu.$_.delay"} // $stats->{"vcpu.$_.wait"} }
	   grep { defined($stats->{"vcpu.$_.delay"}) ||
		defined($stats->{"vcpu.$_.wait"}) }
	   0 .. ($stats->{'vcpu.maximum'} || $stats->{'vcpu.current'} || 0) - 1;
$counters{cpu_wait_time} = sum(@wait) / 1e9 if $vm->{active} && @wait;
my @rows;
my %disk =
	map { $_->{target} => $_ } grep { $_->{target} } @{$vm->{disks} || [ ]};
my %net =
	map { $_->{target} => $_ } grep { $_->{target} &&
		$_->{mac} } @{$vm->{interfaces} || [ ]};
my %aggregates;
my %incomplete;
my $unmapped = 0;
# Match bulk-stat indexes to XML disk slots or NIC MAC addresses before summing.
for my $spec ( [ 'block', \%disk, 'disk',
		 { disk_read => 'rd.bytes', disk_write => 'wr.bytes',
		   disk_reads => 'rd.reqs',
		   disk_writes => 'wr.reqs' } ],
	       [ 'net', \%net, 'nic',
		 { network_receive => 'rx.bytes',
		   network_transmit => 'tx.bytes' } ] ) {
	my ($prefix, $devices, $kind, $fields) = @$spec;
	my %seen;
	for my $i (0 .. ($stats->{"$prefix.count"} ||
			 0) - 1) {
		my $name = $stats->{"$prefix.$i.name"};
		my $device = defined($name) ? $devices->{$name} : undef;
		# Unknown or duplicate mappings make the corresponding
		# guest totals incomplete.
		if (!$device || $seen{$name}++) {
			$unmapped = 1;
			$incomplete{$_} = 1 for keys %$fields;
			next;
			}
		# Optical and read-only seed disks do not
		# contribute to guest data I/O.
		next if $kind eq 'disk' &&
			(($device->{device} || '') ne 'disk' ||
			 $device->{readonly});
		my $slot = $kind eq 'disk' ? $name : lc($device->{mac});
		my %device_counters =
			map { $_ =>
				$stats->{"$prefix.$i.$fields->{$_}"} } keys %$fields;
		# Retain device identity for stopped guests without
		# deriving live rates.
		%device_counters = () unless $vm->{active};
		my $row =
			$self->row({ entity => "$id/$kind/$slot", owner => $id,
				     kind => $kind, label => $slot },
				   $kind eq 'disk'
					   ? {
						   disk_capacity => $stats->{"$prefix.$i.capacity"} }
					   : { }, \%device_counters, $mono,
				   $wall);
		push @rows, $row;
		push @{$aggregates{$_}}, $row->{values}->{$_} for keys %$fields;
		}
	# Missing bulk entries cannot masquerade as complete VM totals.
	my @expected =
		grep { $kind ne 'disk' ||
			(($_->{device} || '') eq 'disk' &&
			 !$_->{readonly}) } values %$devices;
	my @missing =
		grep { !$seen{$_->{target}} } @expected;
	# Incomplete device groups must not publish a partial
	# aggregate as a total.
	if (@missing) {
		$unmapped = 1;
		$incomplete{$_} = 1 for keys %$fields;
		# A reappearing device needs a new baseline. Otherwise its
		# longer rate interval would be combined with shorter VM
		# intervals and lose bytes.
		for my $device (@missing) {
			my $slot = $kind eq 'disk'
				? $device->{target}
				: lc($device->{mac});
			delete $self->{previous}->{"$id/$kind/$slot"};
			}
		}
	}
my $row =
	$self->row({ entity => $id, owner => $id, kind => 'vm', label =>
									$vm->{name} }, \%gauges, \%counters, $mono, $wall);
# Normalize CPU usage across the guest's vCPUs only when a rate is available.
if (defined($row->{values}->{cpu_time}) && $live->{vcpus}) {
	$row->{values}->{cpu} =
		min(100, 100 * $row->{values}->{cpu_time} / $live->{vcpus});
	$live->{cpu_percent} = $row->{values}->{cpu};
	}
# Wait time is also a share of the guest's CPUs, so it reads beside usage.
if (defined($row->{values}->{cpu_wait_time}) && $live->{vcpus}) {
	$row->{values}->{cpu_wait} =
		min(100,
		    100 * $row->{values}->{cpu_wait_time} / $live->{vcpus});
	$live->{cpu_wait_percent} = $row->{values}->{cpu_wait};
	}
# Publish totals only when every contributing device supplied a valid rate.
for my $key (keys %aggregates) {
	my $values = $aggregates{$key};
	next if $incomplete{$key} || !@$values || grep { !defined($_) } @$values;
	$row->{values}->{$key} = sum(@$values);
	}
# Adapt normalized rates to the field names used by existing
# live-status clients.
my %mapping =
	( disk_read => 'disk_read_bytes_sec',
	  disk_write => 'disk_write_bytes_sec',
	  network_receive => 'network_rx_bytes_sec', network_transmit =>
							     'network_tx_bytes_sec' );
for my $key (keys %mapping) {
	$live->{$mapping{$key}} = $row->{values}->{$key}
		if defined($row->{values}->{$key});
	}
unshift @rows, $row;
return ( \@rows,
	 { resources => $live, guest => $guest, name => $vm->{name},
	   agent_available => $agent_available, agent_checked_at => $agent_checked,
	   state => $vm->{state}, active =>
									       $vm->{active}
										       ? 1
										       : 0,
	   checked_at => $wall }, $unmapped );
}

# read_text(path) reads a proc/sysfs counter file or its test fixture.
sub read_text
{
my ($path) = @_;
open(my $fh, '<', $path) or return '';
local $/;
my $value = <$fh>;
close($fh);
return $value || '';
}

# uplinks(sys_net, configured) chooses a non-overlapping physical/bond boundary.
# Bridges do not represent forwarded traffic reliably. Default to physical
# ports, replacing enslaved bond ports with the bond. Explicit
# lists must not overlap.
sub uplinks
{
my ($sys, $configured) = @_;
my @requested = grep { length } split(/[\s,]+/, $configured || '');
die "Invalid uplink name\n" if grep { !/\A[a-zA-Z0-9_.:-]{1,15}\z/ } @requested;
my @names = @requested ? @requested : map { s{.*/}{}r } glob("$sys/*");
my %selected;
for my $name (@names) {
	die "Unknown uplink: $name\n" if @requested && !-d "$sys/$name";
	next unless -d "$sys/$name";
	# Exclude guest-facing and loopback interfaces to avoid
	# counting traffic twice.
	if ($name =~ /\A(?:lo|vnet\d+|tap\w*)\z/) {
		die "Guest and loopback interfaces are not host uplinks\n"
			if @requested;
		next;
		}
	# An explicit list can name supported virtual uplinks as
	# well as physical ports.
	if (@requested) {
		$selected{$name} = 1;
		next;
		}
	# Automatic selection prefers physical ports or their bond master.
	next unless -e "$sys/$name/device" || -d "$sys/$name/bonding";
	my $master = readlink("$sys/$name/master") || '';
	$master =~ s{.*/}{};
	$selected{$master && -d "$sys/$master/bonding" ? $master : $name} = 1;
	}
# Reject both an upper interface and any of its lower devices in the same list.
for my $name (keys %selected) {
	my @pending = map { s{.*/lower_}{}r } glob("$sys/$name/lower_*");
	my %visited;
	while (my $lower = shift @pending) {
		# Avoid revisiting lower interfaces while checking
		# nested interface stacks.
		next if $visited{$lower}++;
		die "Overlapping uplinks: $name and $lower\n"
			if $selected{$lower};
		push @pending,
			map { s{.*/lower_}{}r } glob("$sys/$lower/lower_*");
		}
	}
return [ sort keys %selected ];
}

# host(self, host_id, monotonic, wall, options) reads Linux host counters.
# Options may override proc and sys roots, which default to /proc and /sys. An
# omitted or empty uplinks option uses automatic interface selection. Optional
# guests (the tick's live guest records) and pools (active storage pool records)
# add what running guests hold and how full the pools are.
sub host
{
my ($self, $id, $mono, $wall, $options) = @_;
my $proc = $options->{proc} || '/proc';
my $sys = $options->{sys} || '/sys';
my $hardware = lc(read_text("$sys/class/dmi/id/product_uuid"));
chomp($hardware);
# Malformed hardware metadata is ignored because it is only an inventory hint.
$hardware = undef
	unless $hardware =~ /\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/;
my $stat = read_text("$proc/stat");
my ($cpu) = $stat =~ /^cpu\s+(.+)$/m;
my @cpu = split(/\s+/, $cpu || '');
# Linux guest and guest_nice are already included in user and nice.
my $total = @cpu >= 8 ? sum(@cpu[0 .. 7]) : undef;
my $idle = @cpu >= 8 ? $cpu[3] + $cpu[4] : undef;
my %memory = read_text("$proc/meminfo") =~ /^(\w+):\s+(\d+)\s+kB/gm;
my %gauges;
# Use MemAvailable for host usage. Missing memory fields stay unmeasured.
$gauges{memory_allocated} = $memory{MemTotal} * 1024
	if defined($memory{MemTotal});
$gauges{memory_used} = ($memory{MemTotal} - $memory{MemAvailable}) * 1024
	if defined($memory{MemTotal}) && defined($memory{MemAvailable});
$gauges{vcpus} = scalar(() = $stat =~ /^cpu\d+\s/gm);
# Linux load averages include runnable tasks and tasks in uninterruptible sleep,
# including some I/O waits, over one, five and fifteen minutes.
my @load =
	read_text(
		"$proc/loadavg") =~ /\A\s*(\d+(?:\.\d+)?)\s+(\d+(?:\.\d+)?)\s+(\d+(?:\.\d+)?)\s/;
# Convert captures to numbers so the live cache emits JSON numbers.
@gauges{qw(load_1 load_5 load_15)} = map { 0 + $_ } @load if @load == 3;
# Compare running guests' allocations with host capacity to show overcommit.
if (my $guests = $options->{guests}) {
	my @running = grep { $_->{active} } values %$guests;
	$gauges{guest_vcpus} =
		sum(0, map { $_->{resources}->{vcpus} || 0 } @running);
	$gauges{guest_memory} =
		sum(0, map { $_->{resources}->{memory_bytes} || 0 } @running);
	}
# Pools on one filesystem report the same space, so it counts once.
if (my $pools = $options->{pools}) {
	my %seen;
	my @unique = grep { !$seen{$_->{fsid}
		? "fs:$_->{fsid}"
		: "pool:".($_->{uuid} || $_->{name})}++ } @$pools;
	$gauges{storage_total} = sum(0, map { $_->{capacity} || 0 } @unique);
	$gauges{storage_used} = sum(0, map { $_->{allocation} || 0 } @unique);
	}
my $row =
	$self->row({ entity => $id, owner => $id, kind => 'host',
		     label => 'Host' },
		   \%gauges, { }, $mono, $wall);
my $old = $self->{host_cpu};
# Derive host CPU usage only across increasing counters and a timely interval.
if ($old && defined($total) && $total > $old->{total} &&
    $idle >= $old->{idle} && $mono - $old->{mono} > 0 &&
    $mono - $old->{mono} <= 3 * $self->{interval}) {
	$row->{values}->{cpu} =
		max(0,
		    100 * (1 - ($idle - $old->{idle}) / (
			    $total - $old->{total})));
	}
$self->{host_cpu} = defined($total)
	? { total => $total, idle => $idle, mono => $mono }
	: undef;
my @rows = ($row);
# A bad uplink selection must not prevent CPU, memory or disk collection.
my $uplinks = eval { uplinks("$sys/class/net", $options->{uplinks}) };
my $network_error = $@;
$uplinks ||= [ ];
my %net;
for my $line (split(/\n/, read_text("$proc/net/dev"))) {
	# Skip proc headers and accept only complete interface counter rows.
	next unless $line =~ /^\s*([^:]+):\s*(.+)$/;
	my ($name, $data) = ( $1, $2 );
	my @fields = split(/\s+/, $data);
	$net{$name} =
		{ network_receive => $fields[0],
		  network_transmit => $fields[8] }
		if @fields >= 16;
	}
my @network;
# Keep separate rate baselines for every selected uplink.
for my $name (@$uplinks) {
	my $r =
		$self->row({ entity => "$id/uplink/$name", owner => $id, kind =>
										 'uplink', label => $name }, { }, $net{$name} || { }, $mono,
			   $wall);
	push @rows, $r;
	push @network, $r;
	}
# Missing counters on any uplink make the host traffic total unknown.
for my $key (qw(network_receive network_transmit)) {
	$row->{values}->{$key} =
		sum(map { $_->{values}->{$key} } @network)
		if @network && !grep { !defined($_->{values}->{$key}) } @network;
	}
# Whole physical block devices avoid adding partitions or device-mapper layers.
my @disks;
for my $line (split(/\n/, read_text("$proc/diskstats"))) {
	my @v = split(/\s+/, $line =~ s/^\s+//r);
	next unless @v >= 14;
	my $name = $v[2];
	next unless -e "$sys/class/block/$name/device" &&
		!-e "$sys/class/block/$name/partition";
	my $r =
		$self->row({ entity => "$id/block/$name", owner => $id, kind =>
										'block', label => $name }, { },
			   { disk_read => $v[5] * 512,
			     disk_write => $v[9] * 512,
			     disk_reads => $v[3], disk_writes => $v[7] },
			   $mono,
			   $wall);
	push @rows, $r;
	push @disks, $r;
	}
# Host disk totals need a valid rate from every selected physical disk.
for my $key (qw(disk_read disk_write disk_reads disk_writes)) {
	$row->{values}->{$key} = sum(map { $_->{values}->{$key} } @disks)
		if @disks && !grep { !defined($_->{values}->{$key}) } @disks;
	}
# Report default-route interface names as metadata, not as the uplink selection.
my @routes;
for my $line (split(/\n/, read_text("$proc/net/route"))) {
	my @v = split(/\s+/, $line);
	push @routes, $v[0] if @v > 3 && $v[1] eq '00000000' &&
		(hex($v[3]) & 2);
	}
return ( \@rows,
	 { values => $row->{values}, uplinks => $uplinks,
	   pools => $options->{pools},
	   hardware_uuid => $hardware, default_route => \@routes, error =>
									  $network_error || undef } );
}

1;
