package Cloudmin::NotificationTypes;

# Shared condition and delivery method definitions keep validation, messages
# and forms consistent.
use strict;
use warnings;

# metrics() returns condition names in their display order.
sub metrics
{
return qw(cpu memory memory_free filesystem filesystem_free pool pool_free
	load_1 load_5 load_15 network_receive network_transmit disk_read disk_write
	guest_down guest_agent pool_inactive collector_stale job_failed);
}

# metric(name) returns units, defaults and allowed scopes, or undef if unknown.
# Usage is a percentage; free space uses GiB and rates use MiB/s.
sub metric
{
my ($name) = @_;
return undef unless defined($name) && grep { $_ eq $name } metrics();
# Group conditions by value type so forms and checks use the same defaults.
my $percent = $name =~ /\A(?:cpu|memory|filesystem|pool)\z/;
my $free = $name =~ /_free\z/;
my $rate = $name =~ /\A(?:network_|disk_)/;
my $load = $name =~ /\Aload_/;
my $boolean = $name =~ /\A(?:guest_down|guest_agent|pool_inactive|collector_stale)\z/;
# Pool, load and collector conditions apply only to the host. Filesystem and
# pool conditions take a device. Free space alerts at or below its threshold,
# everything else at or above. Default thresholds are 90 percent, 100 MiB/s,
# and 1 for free space and load.
return {
	unit => $percent ? '%' : $free ? 'GiB' : $rate ? 'MiB/s' : '',
	boolean => $boolean ? 1 : 0,
	numeric => $percent || $free || $rate || $load ? 1 : 0,
	host_only => $name =~ /\A(?:pool|load_|collector_stale)/ ? 1 : 0,
	device => $name =~ /\A(?:filesystem|pool)/ ? 1 : 0,
	threshold => $percent ? 90 : $rate ? 100 : 1,
	comparison => $free ? 'le' : 'ge' };
}

# transports() lists delivery methods accepted by the store and forms.
sub transports
{
return qw(email webhook slack discord teams ntfy telegram pushover gotify);
}

# private_address(type) identifies methods whose URLs must be kept private.
sub private_address
{
return $_[0] =~ /\A(?:slack|discord|teams)\z/ ? 1 : 0;
}

1;
