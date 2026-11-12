package Cloudmin::NotificationSignals;

# Convert current collector readings into values for notification rules.
use strict;
use warnings;
use Scalar::Util qw(looks_like_number);
use POSIX qw(isfinite);

# numeric(value) accepts finite numbers and rejects missing values or objects.
sub numeric
{
my ($v) = @_;
return defined($v) && !ref($v) && looks_like_number($v) && isfinite($v);
}

# percent(used, total) converts nonnegative usage to a percentage.
# Allow usage above 100%; invalid readings or nonpositive totals return undef.
sub percent
{
my ($used, $total) = @_;
return undef unless numeric($used) && numeric($total) &&
	$total > 0 && $used >= 0;
return 100 * $used / $total;
}

# free_gib(used, total) returns free GiB from byte counts.
# Invalid readings or nonpositive totals return undef. Clamp free space to zero.
sub free_gib
{
my ($used, $total) = @_;
return undef unless numeric($used) && numeric($total) &&
	$total > 0 && $used >= 0;
return ($total > $used ? $total - $used : 0) / 1024**3;
}

# observations(rules, snapshot, now, filesystems) returns readings by rule ID.
# rules is an arrayref of saved rules; snapshot is the collector cache and now
# is Unix time. filesystems maps host paths to usage percentages and free GiB. A
# scalar probe value supplies only usage, for callers without free-space data.
sub observations
{
my ($rules, $snapshot, $now, $filesystems) = @_;
my %result;
# Reject stale snapshots and timestamps ahead of the evaluation clock.
my $fresh = !$snapshot->{stale} && $snapshot->{checked_at} &&
	$now >= $snapshot->{checked_at} &&
	$now - $snapshot->{checked_at} <= 3 * ($snapshot->{interval} || 10);
for my $r (@$rules) {
	# Disabled rules and job failure rules take no readings.
	next unless $r->{enabled} && $r->{metric} ne 'job_failed';
	# A guest list, or all guests, gives separate readings for each guest.
	# Other scopes name one owner.
	my @owners = ref($r->{scope}) eq 'ARRAY'
		? @{$r->{scope}}
		: $r->{scope} eq 'guests'
			? sort keys %{$snapshot->{vms} || { }} : ($r->{scope});
	for my $owner (@owners) {
		# Host and guest caches use different names for
		# their resource fields.
		my $host = $owner eq 'host';
		my $live = $host
			? $snapshot->{host}
			: $snapshot->{vms}->{$owner};
		$live ||= { };
		my $v = $host
			? $live->{values} || { }
			: $live->{resources} || { };
		# Guest readings must be current within this
		# snapshot as well as present.
		my $running = ($live->{state} || '') =~ /\A(?:running|blocked)\z/;
		my $known = $fresh && ($host || $live->{checked_at} &&
			$now - $live->{checked_at} <= 3 * ($snapshot->{interval} || 10));
		# Bound guest-supplied labels before they reach
		# event history and messages.
		my $name = $host ? 'Host' : $live->{name} || $owner;
		$name =~ s/[\x00-\x1f\x7f]/ /g;
		$name = substr($name, 0, 200);
		my @values;
		if ($r->{metric} =~ /\Afilesystem(?:_free)?\z/) {
			# Filesystem rules may produce several
			# independent device readings.
			if ($host) {
				# Host probes work even when resource
				# collection is disabled.
				my $probe = $filesystems->{$r->{device}};
				my $key = $r->{metric} eq 'filesystem_free' ? 'free' : 'usage';
				push @values, [ $r->{device}, ref($probe) eq 'HASH'
					? $probe->{$key} : $key eq 'usage' ? $probe : undef ];
				}
			else {
				# Fresh running status gates the cached
				# guest filesystem values.
				for my $fs (@{$live->{guest}->{filesystems} || [ ]}) {
					my $path = $fs->{mountpoint} || $fs->{name};
					# A blank rule device matches
					# every reported filesystem.
					next unless defined($path) &&
						(!$r->{device} || $r->{device} eq $path);
					push @values, [ $path, $known && $running
						? $r->{metric} eq 'filesystem_free'
							? free_gib($fs->{'used-bytes'}, $fs->{'total-bytes'})
							: percent($fs->{'used-bytes'}, $fs->{'total-bytes'})
						: undef ];
					}
				}
			}
		elsif ($r->{metric} =~ /\Apool(?:_free|_inactive)?\z/) {
			# Status rules include inactive pools;
			# usage rules use active pools.
			my $status = $r->{metric} eq 'pool_inactive';
			my $pools = $status ? $live->{pool_states} : $live->{pools};
			# Pool states refresh about once a minute. Accept
			# them for three minutes, or for three collection
			# intervals when those are longer.
			my $pool_fresh = $known && $live->{pool_checked_at} &&
				$now >= $live->{pool_checked_at} &&
				$now - $live->{pool_checked_at} <=
					3 * (($snapshot->{interval} || 10) > 60
						? $snapshot->{interval} : 60);
			for my $pool (@{$pools || [ ]}) {
				my $id = $pool->{name} || $pool->{uuid};
				# A blank rule device matches every pool. A set
				# one matches a pool name or UUID.
				next if $r->{device} && $r->{device} ne $id &&
					$r->{device} ne ($pool->{uuid} || '');
				my $value;
				if ($status) {
					# An absent or stale inventory cannot
					# establish inactivity.
					$value = $pool->{active} ? 0 : 1
						if $pool_fresh && defined($pool->{active});
					}
				elsif ($known) {
					# Capacity is bytes; free-space
					# rules use GiB.
					$value = $r->{metric} eq 'pool_free'
						? numeric($pool->{available}) && numeric($pool->{capacity}) &&
						  $pool->{available} >= 0 && $pool->{capacity} > 0
							? $pool->{available} / 1024**3 : undef
						: percent($pool->{allocation}, $pool->{capacity});
					}
				push @values, [ $id, $value ];
				}
			}
		else {
			# CPU, memory and guest status each produce
			# one reading per owner.
			my $value;
			if ($r->{metric} eq 'collector_stale') {
				# Report a stalled collector, but pause
				# when collection is off.
				$value = $fresh ? 0 : 1
					unless exists($snapshot->{collection_enabled}) &&
						!$snapshot->{collection_enabled};
				}
			elsif ($known) {
				# Only fresh status can establish power,
				# agent or usage readings.
				if ($r->{metric} eq 'guest_down') {
					# A known stopped state is bad; an
					# absent state remains unknown.
					$value = $running ? 0 : 1 if defined($live->{state});
					}
				elsif ($r->{metric} eq 'guest_agent' && $running) {
					# Allow the collector's one-hour retry
					# plus five minutes of slack.
					$value = $live->{agent_available} ? 0 : 1
						if defined($live->{agent_available}) &&
						$live->{agent_checked_at} &&
						$now - $live->{agent_checked_at} <= 3900;
					}
				elsif ($host || $running) {
					# Stopped guests have no meaningful CPU
					# or memory usage reading.
					$value = $host ? $v->{cpu} : $v->{cpu_percent}
						if $r->{metric} eq 'cpu';
					$value = $host
						? percent($v->{memory_used}, $v->{memory_allocated})
						: percent($v->{memory_used_bytes}, $v->{memory_bytes})
						if $r->{metric} eq 'memory';
					$value = $host
						? free_gib($v->{memory_used}, $v->{memory_allocated})
						: free_gib($v->{memory_used_bytes}, $v->{memory_bytes})
						if $r->{metric} eq 'memory_free';
					# Load averages are available
					# only for the host.
					$value = $v->{$r->{metric}}
						if $host && $r->{metric} =~ /\Aload_/;
					# Map each rate to the guest collector's
					# bytes-per-second field.
					my %rates = (
						network_receive => 'network_rx_bytes_sec',
						network_transmit => 'network_tx_bytes_sec',
						disk_read => 'disk_read_bytes_sec',
						disk_write => 'disk_write_bytes_sec' );
					if (my $field = $rates{$r->{metric}}) {
						# Host values use the metric
						# name. Convert rates to MiB/s.
						my $bytes = $v->{$host ? $r->{metric} : $field};
						$value = $bytes / 1024**2 if numeric($bytes);
						}
					}
				}
			push @values, [ '', $value ];
			}
		# Stable owner/device keys keep each filesystem or
		# pool incident separate.
		for my $item (@values) {
			my ($device, $value) = @$item;
			# Negative or non-numeric readings count as unknown.
			push @{$result{$r->{id}}}, {
				owner => $owner, subject => $owner.'/'.$device,
				label => $name.($device ? ' '.$device : ''),
				value => numeric($value) && $value >= 0 ? 0 + $value : undef,
				running => $running ? 1 : 0 };
			}
		}
	}
return \%result;
}

1;
