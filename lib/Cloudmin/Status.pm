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

1;
