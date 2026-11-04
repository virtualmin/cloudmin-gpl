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
require "$module_root_directory/cloudmin-lib.pl";
{
    package KeyAPIFixture;
    # Minimal services retain the real controller's permission ordering.
    # list(self) counts a public library read.
    sub list { $_[0]->{reads}++; [] }
    # get(self, id) counts a public detail lookup.
    sub get { $_[0]->{reads}++; {public=>'public',id=>'key',name=>'Name'} }
    # save(self, fields) counts a library write.
    sub save { $_[0]->{writes}++; {id=>'key',name=>'Name'} }
    # remove(self, id, revision) counts a removal.
    sub remove { $_[0]->{writes}++; {id=>'key',name=>'Name'} }
    # download(self, id) counts a privileged private-key read.
    sub download { $_[0]->{writes}++; 'private-fixture-value' }
    # check_token(self, owner, token) accepts only the fixture token.
    sub check_token { die "Bad token\n" if ($_[2] || '') ne 'valid'; }
    # lock(self, name, callback) counts host locks around the callback.
    sub lock { $_[0]->{locks}++; $_[2]->() }
    # assert_guest_available(self, id) models a busy guest reservation.
    sub assert_guest_available { die "Guest busy\n" if $_[0]->{busy}; }
    # inventory(self, username) counts a guest-key read.
    sub inventory { $_[0]->{reads}++; {keys=>[],revision=>'revision'} }
    # add(self, username, public) counts a guest-key write.
    sub add { $_[0]->{writes}++; {added=>1} }
}
my $service = bless {}, 'KeyAPIFixture';
my ($readonly, $pro) = (0, 1);
my @logs;
{
    no warnings qw(redefine once);
    # get_ssh_key_manager() keeps host ACL checks and simulates Pro availability.
    local *main::get_ssh_key_manager = sub {
        require_access('host');
        die "Requires Pro\n" unless $pro;
        $service;
    };
    # get_vm_service() fails if a key action reaches the creation dispatcher.
    local *main::get_vm_service = sub {die "Unexpected creation service\n"};
    # get_vm_jobs() supplies the reservation and locking fixture.
    local *main::get_vm_jobs = sub {$service};
    # get_image_jobs() supplies the token-checking fixture.
    local *main::get_image_jobs = sub {$service};
    # guest_ssh_service(id) returns the mock service and its guest identity.
    local *main::guest_ssh_service = sub {($service,{uuid=>'guest',name=>'Guest'})};
    # is_readonly_mode() exposes the current test permission setting.
    local *main::is_readonly_mode = sub {$readonly};
    # webmin_log(action, type, id, [fields]) captures audit data for inspection.
    local *main::webmin_log = sub {push(@logs,[@_])};
    my @writes = qw(save_ssh_key delete_ssh_key download_ssh_key add_guest_ssh_key remove_guest_ssh_key);
    my %input = (token=>'valid',id=>'guest',username=>'admin',key=>'key',confirm=>1,revision=>'revision');
    # Deny every key action before a delegated user can touch the services.
    for my $action ('ssh_keys','guest_ssh_keys',@writes) {
        local %access = (admin=>0,power=>1,vms=>'guest');
        ok(!eval {call_vm_api(1,$action,{%input});1}, "$action rejects delegated access");
        like($@,qr/Access denied/, 'host permission required');
    }
    # Host access alone cannot enable the library on GPL.
    %access=(admin=>1);
    $pro=0;
    ok(!eval {call_vm_api(1,'ssh_keys',{});1}, 'GPL rejects library');
    # Read-only sessions may list public keys but cannot make changes or
    # download private keys.
    $pro=1; $readonly=1;
    for my $action (@writes) {
        ok(!eval {call_vm_api(1,$action,{%input});1}, "$action rejects read-only session");
    }
    is($service->{writes} || 0,0,'denied calls have no effects');
    is_deeply(call_vm_api(1,'ssh_keys',{}),[],'read-only public inventory works');
    is_deeply(call_vm_api(1,'guest_ssh_keys',{%input}),{keys=>[],revision=>'revision'},'read-only sessions can list guest keys');
    # Write access still requires a valid token before reaching the service.
    $readonly=0;
    for my $action (@writes) {
        ok(!eval {call_vm_api(1,$action,{%input,token=>'bad'});1}, "$action rejects bad token");
        like($@,qr/Bad token/,'token checked before operation');
    }
    # Deletions require confirmation; guest changes also honor reservations.
    ok(!eval {call_vm_api(1,'delete_ssh_key',{%input,confirm=>0});1},'library deletion needs confirmation');
    ok(!eval {call_vm_api(1,'remove_guest_ssh_key',{%input,confirm=>0});1},'guest removal needs confirmation');
    $service->{busy}=1;
    ok(!eval {call_vm_api(1,'add_guest_ssh_key',{%input});1},'reserved guest cannot be edited');
    like($@,qr/Guest busy/,'reservation failure retained');
    # Authorized requests reject ambiguous sources and keep audits public.
    $service->{busy}=0;
    ok(!eval {call_vm_api(1,'add_guest_ssh_key',{%input,public=>'another'});1},'ambiguous key source rejected');
    ok(!eval {call_vm_api(1,'add_guest_ssh_key',{%input,key=>'',public=>''});1},'missing key source rejected');
    like($@,qr/Select a saved key or paste public keys\n/,'missing source names both inputs');
    # Listing never blocks host jobs; changes do, and are logged against the VM.
    my $locks = $service->{locks} || 0;
    call_vm_api(1,'guest_ssh_keys',{%input});
    is($service->{locks} || 0, $locks, 'guest listing never takes the host lock');
    is(call_vm_api(1,'add_guest_ssh_key',{%input})->{added},1,'authorized add dispatched');
    is($service->{locks}, $locks + 1, 'guest changes hold the host lock');
    my ($guest_log) = grep { $_->[0] eq 'add_guest_ssh_key' } @logs;
    is_deeply([@$guest_log[1,2]], ['vm', 'guest'], 'guest changes are logged against the virtual machine');
    is($guest_log->[3]->{'name'}, 'Guest', 'guest audit entries carry the virtual machine name');
    # A private download returns key material but must not put it in audits.
    is(call_vm_api(1,'download_ssh_key',{%input})->{private},'private-fixture-value','explicit authorized download works');
    unlike(convert_to_json(\@logs,0,1),qr/private-fixture-value|public/, 'audit contains no key material');
}
# Only the missing authorized_keys error becomes an empty inventory,
# allowing the Pro addition flow to continue. Other failures stay errors.
my $command = 'guest-ssh-get-authorized-keys';
my $missing = "error: guest agent command failed: unable to execute QEMU agent command '$command': failed to read '/home/alpine/.ssh/authorized_keys': Failed to open file: No such file or directory";
is_deeply(guest_ssh_reply($command, 256, '', $missing), {keys => []},
    'a missing authorized_keys file is an empty inventory');
# Check guest failures and missing host sockets against that narrow exception.
for my $error ($missing =~ s/No such file or directory/Permission denied/r,
    "failed to find user nosuchuser", "guest agent is not connected",
    "failed to open /run/libvirt/libvirt-sock: No such file or directory") {
    ok(!eval { guest_ssh_reply($command, 256, '', $error); 1 },
        'other agent and host failures remain errors');
}
# The missing-file exception applies only to listing, never to a write.
ok(!eval { guest_ssh_reply('guest-ssh-add-authorized-keys', 256, '', $missing); 1 },
    'a failed key addition cannot report success');
is_deeply(guest_ssh_reply($command, 0, '{"return":{"keys":[]}}', ''), {keys => []},
    'successful agent inventory remains unchanged');
# Access denials remain failures and explain the guest's SELinux permission.
for my $operation (qw(get add remove)) {
    my $cmd = "guest-ssh-$operation-authorized-keys";
    my $denied = "unable to execute QEMU agent command '$cmd': Permission denied";
    ok(!eval { guest_ssh_reply($cmd, 256, '', $denied); 1 },
        "$operation cannot treat denied access as an empty inventory or success");
    like($@, qr/inside the virtual machine/, 'permission repair targets the guest');
    like($@, qr/setsebool -P virt_qemu_ga_manage_ssh on/, 'SELinux repair is explained');
}
done_testing();
