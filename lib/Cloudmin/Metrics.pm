package Cloudmin::Metrics;

# Convert libvirt counters into guest resource usage shared by all viewers.
use strict;
use warnings;

# new(class) retains the preceding sample for CPU and I/O rates.
sub new
{
return bless { previous => {} }, $_[0];
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

1;
