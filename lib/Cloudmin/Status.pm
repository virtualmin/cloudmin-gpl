package Cloudmin::Status;

# Shared status cache and per-subscriber changes, independent of the transport.
use strict;
use warnings;
use WebminCore qw(convert_to_json);
use File::Basename qw(dirname);
require(dirname(__FILE__).'/Metrics.pm');

# new(class) creates an empty collector cache.
sub new
{
return bless { vms => {}, health => {}, due => {}, resources => {}, guest => {},
	guest_due => {},
	metrics => Cloudmin::Metrics->new(), encoded => {}, revision => 0 }, $_[0];
}

# record(self, vm)
# Retains only public inventory fields, never guest XML or secrets.
sub record
{
my ($self, $vm) = @_;
my $id = $vm->{'uuid'};
# Keep disk roles and resource differences public; never cache secure XML here.
$self->{'vms'}->{$id} = { map { $_ => $vm->{$_} }
	qw(uuid name state active persistent autostart vcpus memory_kib macs
	   addresses disk_targets disk_roles pending) };
$self->{'vms'}->{$id}->{'addresses'} ||= [];
# Sys::Virt returns names as UTF-8 bytes; WebSocket text encoding needs characters.
utf8::decode($self->{'vms'}->{$id}->{'name'})
	if (defined($self->{'vms'}->{$id}->{'name'}) && !utf8::is_utf8($self->{'vms'}->{$id}->{'name'}));
$self->refresh($id);
}

# refresh(self, uuid) compares each changed record once, regardless of viewers.
sub refresh
{
my ($self, $id) = @_;
my $encoded = convert_to_json($self->value($id), 0, 0, 1);
# Repeated probe results must not cause another broadcast to every
# viewer.
return if (($self->{'encoded'}->{$id} || '') eq $encoded);
$self->{'encoded'}->{$id} = $encoded;
$self->{'revision'}++;
}

# invalidate(self, uuid) discards old health after a lifecycle or agent event.
sub invalidate
{
my ($self, $id) = @_;
delete $self->{'health'}->{$id};
delete $self->{'resources'}->{$id};
delete $self->{'guest'}->{$id};
$self->{'metrics'}->forget($id);
$self->{'guest_due'}->{$id} = 0;
$self->{'due'}->{$id} = 0;
# Deletion events can arrive after the corresponding inventory record is
# gone.
$self->refresh($id) if ($self->{'vms'}->{$id});
}

# remove(self, uuid) drops a deleted VM and any pending health result.
sub remove
{
my ($self, $id) = @_;
delete $self->{$_}->{$id}
	for qw(vms health due encoded resources guest guest_due);
$self->{'metrics'}->forget($id);
$self->{'revision'}++;
}

# checked(self, uuid, result, now) caches one probe for all interested users.
sub checked
{
my ($self, $id, $result, $now) = @_;
# Ignore a slow health result for a guest removed while the probe ran.
return if (!$self->{'vms'}->{$id});
$self->{'health'}->{$id} = $result;
# A health probe may learn addresses that the inventory did not yet
# contain.
$self->{'vms'}->{$id}->{'addresses'} = $result->{'addresses'}
	if ($result->{'addresses'});
$self->{'due'}->{$id} = $now + (($result->{'ssh'} || '') eq 'responding' ? 30
	: 5);
$self->refresh($id);
}

# refresh_addresses(self, ids, lookup)
# Refreshes host-observed leases and ARP entries without polling guest agents.
# lookup(uuid, record) returns an address array; failures retain the last read.
sub refresh_addresses
{
my ($self, $ids, $lookup) = @_;
foreach my $id (@$ids) {
	my $vm = $self->{'vms'}->{$id} || next;
	next if (!$vm->{'active'});
	# Keep agent-only static addresses until the next agent or lifecycle update.
	next if (grep { ($_->{'source'} || '') eq 'agent' } @{$vm->{'addresses'}});
	my $addresses = eval { $lookup->($id, $vm) };
	next if (ref($addresses) ne 'ARRAY');
	$vm->{'addresses'} = $addresses;
	$self->refresh($id);
	}
}

# next_probe(self, clients, now)
# Selects the most overdue health check among permitted, visible VM details.
# Overview subscriptions never trigger SSH checks for the whole inventory.
# Socket callers must supply a policy here and to resource_ids and message.
# Without a policy, these methods do not filter by VM assignments.
sub next_probe
{
my ($self, $clients, $now) = @_;
my %wanted = map { $_->{'id'} => 1 }
	grep { !$_->{'paused'} && $_->{'id'} ne 'overview' &&
		(!$_->{'policy'} || $_->{'policy'}->allows('view', $_->{'id'})) } @$clients;
my ($id) = sort { ($self->{'due'}->{$a} || 0) <=> ($self->{'due'}->{$b} || 0) ||
	$a cmp $b }
	grep { $self->{'vms'}->{$_} && ($self->{'due'}->{$_} || 0) <= $now }
	keys %wanted;
return $id;
}

# resource_ids(self, clients) lists VMs that visible clients are allowed to view.
sub resource_ids
{
my ($self, $clients) = @_;
my %ids;
# Collect assigned VMs across visible subscriptions, sampling each VM once.
foreach my $client (grep { !$_->{'paused'} } @$clients) {
	my @ids = $client->{'id'} eq 'overview' ? keys %{$self->{'vms'}} : ($client->{'id'});
	$ids{$_} = 1 for grep { $self->{'vms'}->{$_} &&
		(!$client->{'policy'} || $client->{'policy'}->allows('view', $_)) } @ids;
	}
return [sort keys %ids];
}

# next_guest_probe(self, clients, now)
# Schedules at most one slow query per second.
# A 100-VM overview takes at least 100 seconds per round, regardless of viewers.
sub next_guest_probe
{
my ($self, $clients, $now) = @_;
# Pace slow guest-agent queries across all viewers, not per connection.
return if (($self->{'guest_next'} || 0) > $now);
my ($id) = sort { ($self->{'guest_due'}->{$a} ||
	0) <=> ($self->{'guest_due'}->{$b} || 0) || $a cmp $b }
	grep { $self->{'vms'}->{$_}->{'state'} =~ /\A(?:running|blocked)\z/ &&
		($self->{'guest_due'}->{$_} || 0) <= $now }
		@{$self->resource_ids($clients)};
# An empty queue should not delay a guest that becomes due next tick.
$self->{'guest_next'} = $now + 1 if ($id);
return $id;
}

# value(self, uuid) combines public inventory, health and resource measurements.
sub value
{
my ($self, $id) = @_;
return { vm => $self->{'vms'}->{$id}, health => $self->{'health'}->{$id},
	resources => $self->{'resources'}->{$id},
	guest => $self->{'guest'}->{$id} };
}

1;
