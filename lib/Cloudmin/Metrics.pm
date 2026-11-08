package Cloudmin::Metrics;

# Convert libvirt counters into guest resource usage shared by all viewers.
use strict;
use warnings;

# new(class) retains the preceding sample for CPU and I/O rates.

sub new
{
return bless { previous => { } }, $_[0];
}

# forget(self, uuid) prevents counter deltas from crossing a reboot or deletion.

sub forget
{
delete $_[0]->{'previous'}->{$_[1]};
}

# percent(used, total) returns a bounded percentage with one decimal place.

sub percent
{
my ($used, $total) = @_;
# Missing totals and reset counters cannot produce a meaningful percentage.
return undef if (!defined($used) || !$total || $used < 0);
my $value = 100 * $used / $total;
return 0 + sprintf('%.1f', $value > 100 ? 100 : $value);
}

# sample(self, vm, stats, monotonic_seconds, epoch_seconds) Normalizes one
# sample. Missing or stale guest counters stay unavailable; host RSS
# is never guest usage.

sub sample
{
my ($self, $vm, $stats, $now, $wall) = @_;
my $id = $vm->{'uuid'};
my $previous = $self->{'previous'}->{$id};
my $elapsed = $previous ? $now - $previous->{'time'} : 0;
my %result;
my $cpus = $stats->{'vcpu.current'} || $vm->{'vcpus'};
my $memory = $stats->{'balloon.current'} || $vm->{'memory_kib'};
$result{'vcpus'} = $cpus;
# Keep an unknown capacity absent rather than turning it into zero bytes.
$result{'memory_bytes'} = $memory * 1024 if (defined($memory));
# CPU time includes the VM's host threads; normalize to its assigned CPUs.
if ($vm->{'active'} && $cpus && $elapsed > 0 && $elapsed <= 30 &&
    defined($stats->{'cpu.time'}) &&
    defined($previous->{'stats'}->{'cpu.time'})) {
	$result{'cpu_percent'} =
		percent(
			$stats->{'cpu.time'} -
			$previous->{'stats'}->{'cpu.time'},
			$elapsed * 1_000_000_000 * $cpus);
	}
# Usable memory includes reclaimable cache; available is the guest's total RAM.
my ($total, $usable,
    $updated) = @{$stats}{qw(balloon.available balloon.usable
				 balloon.last-update)};
if ($vm->{'active'} && $total && defined($usable) && $usable >= 0 &&
    $usable <= $total &&
    $updated && $wall >= $updated && $wall - $updated <= 60) {
	$result{'memory_used_bytes'} = ($total - $usable) * 1024;
	$result{'memory_percent'} = percent($total - $usable, $memory);
	}
# Index block measurements by target before selecting the VM's data disks.
my %disks;
for my $i (0 .. ($stats->{'block.count'} || 0) - 1) {
	my $name = $stats->{"block.$i.name"};
	# Ignore unnamed entries and repeated targets in the bulk statistics.
	next if (!defined($name) || exists($disks{$name}));
	$disks{$name} = { map { $_ => $stats->{"block.$i.$_"} }
			  qw(capacity physical) };
	}
my @targets = @{$vm->{'disk_targets'} || [ ]};
# Report total writable disk capacity only when every target has a sample.
if (@targets && !grep { !defined($disks{$_}->{'capacity'}) } @targets) {
	$result{'disk_capacity_bytes'} += $disks{$_}->{'capacity'} for @targets;
	}
$result{'disks'} = \%disks;
# Rates use complete counters and reject reset counters or long sampling gaps.
for my $group ( [ 'net', 'rx.bytes', 'network_rx_bytes_sec' ],
		[ 'net', 'tx.bytes', 'network_tx_bytes_sec' ],
		[ 'block', 'rd.bytes', 'disk_read_bytes_sec' ],
		[ 'block', 'wr.bytes', 'disk_write_bytes_sec' ] ) {
	my ($prefix, $field, $key) = @$group;
	my @keys = map { "$prefix.$_.$field" }
		   0 .. ($stats->{"$prefix.count"} || 0) - 1;
	# Do not compare inactive guests, stale samples or
	# changed device counts.
	next if (!$vm->{'active'} || !$previous || $elapsed <= 0 ||
		 $elapsed > 30 || !@keys ||
		 ($previous->{'stats'}->{"$prefix.count"} ||
		  0) != ($stats->{"$prefix.count"} || 0));
	my $delta = 0;
	my $valid = 1;
	for my $key (@keys) {
		my ($value, $old) = ( $stats->{$key},
				      $previous->{'stats'}->{$key} );
		# One missing or reset counter invalidates the aggregate rate.
		if (!defined($value) || !defined($old) ||
		    $value < $old) { $valid = 0; last; }
		$delta += $value - $old;
		}
	# Unavailable rates stay absent so the UI cannot confuse them with zero.
	$result{$key} = int($delta / $elapsed) if ($valid);
	}
$self->{'previous'}->{$id} = { time => $now, stats => $stats };
return \%result;
}

1;
