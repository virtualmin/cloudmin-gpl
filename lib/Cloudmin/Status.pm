package Cloudmin::Status;

# Shared status cache and per-subscriber changes, independent of the transport.
use strict;
use warnings;
use WebminCore qw(convert_to_json);
use File::Basename qw(dirname);
require(dirname(__FILE__).'/Metrics.pm');

# remove(self, uuid) drops a deleted VM and any pending health result.
sub remove
{
my ($self, $id) = @_;
delete $self->{$_}->{$id}
	for qw(vms health due encoded resources guest guest_due);
$self->{'metrics'}->forget($id);
$self->{'revision'}++;
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

1;
