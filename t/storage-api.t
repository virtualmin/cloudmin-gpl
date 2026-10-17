use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib", "$Bin/../lib";
use CloudminTest;
use Test::More;
use WebminCore;
our ($module_root_directory, $remote_user, %access);
$module_root_directory = "$Bin/..";
$remote_user = 'fixture';
require "$Bin/../cloudmin-lib.pl";
require "$Bin/../cloudmin-storage-lib.pl";
{
    package StorageAPITokens;
    # check_token(self, owner, token) accepts only the fixture token.
    sub check_token { die "Invalid token\n" if ($_[2] || '') ne 'valid'; }
    package StorageAPIService;
    # inventory(self) returns mutable fixture records without opening libvirt.
    sub inventory { {local => 1, pools => $_[0]->{pools}} }
    # lvm_groups(self) models optional discovery and its failure mode.
    sub lvm_groups { die "No lvm2\n" if $_[0]->{group_error}; ['guests'] }
    # create(self, input) records both directory and existing-VG registration.
    sub create {
        my ($self, $in) = @_;
        $self->{created} = {%$in};
        push(@{$self->{pools}}, {name => $in->{name}, uuid => 'new-id', type => $in->{type}});
        return $in->{name};
    }
    # change(self, action, id, revision, [enabled]) simulates stale refusal.
    # enabled applies only to autostart changes.
    sub change {
        my ($self, $action, $id, $revision, $enabled) = @_;
        die "Stale revision\n" if $revision ne 'revision';
        $self->{changed} = [$action, $id, $enabled];
        return 'existing';
    }
    # review_volume(self, pool, name, [refresh]) reports ownership without writing.
    # The fixture ignores refresh and returns its current ownership flag.
    sub review_volume { (undef, undef, {name => $_[2], pool => 'existing', revision => 'revision',
        usage => {owners => $_[0]->{owned} ? [{name => 'guest'}] : [], reason => $_[0]->{owned} ? 'Owned' : ''}}) }
    # delete_volume(self, pool, name, revision, confirm) models final service guards.
    sub delete_volume {
        my ($self, $pool, $name, $revision, $confirm) = @_;
        die "Owned\n" if $self->{owned};
        die "Confirm\n" if !$confirm;
        die "Stale revision\n" if $revision ne 'revision';
        $self->{deleted}++;
        return {name => $name, key => 'key', pool => 'existing', path => '/fixture/'.$name};
    }
    # review_pool(self, id, [stop]) records stop permission and returns a review.
    sub review_pool { $_[0]->{review_stop} = $_[2]; (undef, {id => $_[1], name => 'existing', revision => 'revision', usage => {owners => [], reason => ''}}) }
    # unregister(self, id, revision, confirm, [stop]) records stop permission
    # and returns the removed pool's public identity.
    sub unregister { $_[0]->{unregistered}++; $_[0]->{stop} = $_[4]; {id => $_[1], name => 'existing'} }
}
my $service = bless({pools => [{uuid => 'pool-id', name => 'existing', revision => 'revision'}]}, 'StorageAPIService');
our $readonly;
my ($lookups, @logs);
{
    no warnings qw(redefine once);
    # Substitute only external services; retain the real ACL and API dispatch.
    *get_storage_service = sub { $lookups++; $service };
    *get_vm_service = sub { die "Storage must not load the VM creation service\n" };
    *get_image_jobs = sub { bless({}, 'StorageAPITokens') };
    *is_readonly_mode = sub { $readonly };
    *webmin_log = sub { push(@logs, [@_]) };
    *error_message = sub { Cloudmin::Libvirt::error_message($_[0]) };
}
my %input = (token => 'valid', id => 'pool-id', pool => 'pool-id', volume => 'spare.raw',
    revision => 'revision', confirm => 1, name => 'new', type => 'dir', path => '/fixture/new', enabled => 0);
my @writes = qw(register_pool pool_start pool_stop pool_autostart volume_review delete_volume pool_review unregister_pool);
# Deny delegated users before constructing a service or exposing inventory.
for my $action ('storage', @writes) {
    local %access = (admin => 0, power => 1);
    my $before = $lookups || 0;
    ok(!eval { call_vm_api(1, $action, {%input}); 1 }, "$action denies a delegated user");
    is($lookups || 0, $before, 'denial precedes storage lookup');
}
# Reviews issue revisions, so they share mutation method and token guards.
for my $action (@writes) {
    local $ENV{REQUEST_METHOD} = 'GET';
    ok(!eval { call_vm_api(1, $action, {%input}); 1 }, "$action refuses HTTP GET");
    local $ENV{REQUEST_METHOD} = 'POST';
    local $readonly = 1;
    ok(!eval { call_vm_api(1, $action, {%input}); 1 }, "$action refuses read-only mode");
    $readonly = 0;
    ok(!eval { call_vm_api(1, $action, {%input, token => 'bad'}); 1 }, "$action checks its token");
}
# Read-only inventory survives failure of optional group discovery.
{
    local $ENV{REQUEST_METHOD} = 'GET';
    local $readonly = 1;
    is_deeply(call_vm_api(1, 'storage', {})->{lvm_groups}, ['guests'], 'host reads need no token and allow read-only GET');
    local $service->{group_error} = 1;
    my $data = call_vm_api(1, 'storage', {});
    is(scalar(@{$data->{pools}}), 1, 'group discovery failure preserves pool inventory');
    like($data->{lvm_group_error}, qr/No lvm2/, 'discovery failure is explicit');
}
# Local root entry points omit HTTP variables but retain ACL and token checks.
local $ENV{REQUEST_METHOD};
delete $ENV{REQUEST_METHOD};
for my $type ('dir', 'logical') {
    my $record = call_vm_api(1, 'register_pool', {%input, type => $type, name => $type, group => 'guests'});
    is($record->{name}, $type, 'registration returns fresh pool record');
    is($service->{created}->{type}, $type, 'selected backend reaches shared service');
    is($logs[-1]->[0], 'create', 'registration is audited');
}
# Directory lifecycle operations use the shared service and audit path.
for my $action (qw(start stop autostart)) {
    call_vm_api(1, 'pool_'.$action, {%input});
    is($service->{changed}->[0], $action, "$action uses shared mutation path");
    is($logs[-1]->[0], $action, "$action is audited");
}
ok(!eval { call_vm_api(1, 'pool_stop', {%input, revision => 'stale'}); 1 }, 'stale pool revision refused');
# A review can explain ownership, but the same request cannot delete the volume.
{
    local $service->{owned} = 1;
    my $review = call_vm_api(1, 'volume_review', {%input});
    is($review->{usage}->{owners}->[0]->{name}, 'guest', 'blocked review retains owner');
    is($review->{usage}->{reason}, 'Owned', 'blocked review explains refusal');
    ok(!eval { call_vm_api(1, 'delete_volume', {%input}); 1 }, 'owned volume cannot be deleted');
}
# Both a current revision and confirmation are required for deletion.
for my $extra ({revision => 'stale'}, {confirm => 0}) {
    ok(!eval { call_vm_api(1, 'delete_volume', {%input, %$extra}); 1 }, 'volume mutation validates revision and confirmation');
}
# Successful changes return their identity and create an audit entry.
call_vm_api(1, 'delete_volume', {%input});
is($service->{deleted}, 1, 'one confirmed volume is deleted');
is($logs[-1]->[0], 'delete', 'volume deletion is audited');
is(call_vm_api(1, 'pool_review', {%input})->{revision}, 'revision', 'pool review returns revision');
call_vm_api(1, 'unregister_pool', {%input});
is($service->{unregistered}, 1, 'unregistration uses shared service');
is($logs[-1]->[0], 'unregister', 'unregistration is audited');
# The final mutation must carry the same stop choice as the review.
call_vm_api(1, 'pool_review', {%input, stop => 1});
is($service->{review_stop}, 1, 'API reviews explicit stop permission');
call_vm_api(1, 'unregister_pool', {%input, stop => 1});
is($service->{stop}, 1, 'API passes explicit stop permission to guarded removal');
done_testing();
