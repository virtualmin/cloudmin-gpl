use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use Test::More;
use File::Temp qw(tempdir);
use WebminCore qw(convert_to_json convert_from_json);
our ($module_root_directory,$module_var_directory,$module_config_directory,%access,$cloudmin_last_error);
# Keep module state temporary and replace host services with test stubs.
$module_root_directory = "$Bin/..";
$module_var_directory = tempdir(CLEANUP=>1);
$module_config_directory = $module_var_directory;
require "$module_root_directory/cloudmin-lib.pl";
require "$module_root_directory/cloudmin-statistics-lib.pl";
# Two guests distinguish permitted inventory from unrelated private records.
my $one = '11111111-1111-4111-8111-111111111111';
my $two = '22222222-2222-4222-8222-222222222222';
my $template = Cloudmin::Presets::default_id();
my @servers = (
    {id=>$one,uuid=>$one,name=>'alpha',state=>'running',active=>1,vcpus=>2,memory_kib=>2097152,
     autostart=>1,disk_targets=>['vda','vdb'],addresses=>[],cloudmin=>{job=>'a'x32,template=>$template}},
    {id=>$two,uuid=>$two,name=>'beta',state=>'shutoff',active=>0,vcpus=>1,memory_kib=>1048576,
     autostart=>0,disk_targets=>['vda'],addresses=>[],cloudmin=>{}},
);
my @probed;
{
    package MachinesAPIAdapter;
    # get_resource_stats(self, ids) returns statistics for fixture disks and
    # media.
    sub get_resource_stats {
        my ($self,$ids)=@_; push(@probed,@$ids);
        return { map {$_=>{'block.count'=>3,'block.0.name'=>'vda','block.0.capacity'=>20*1024**3,
            'block.1.name'=>'vdb','block.1.capacity'=>5*1024**3,'block.2.name'=>'sda','block.2.capacity'=>1024**3}} @$ids };
    }
    package MachinesAPIJobs;
    # get(self, id) includes private fields that must never leave the API.
    sub get {return {created=>1700000000,request=>{uuid=>$one,plan=>$template,password=>'secret',virtualmin_key=>'license'}};}
}
{
    no warnings qw(redefine once);
    # list_managed_servers_sorted() returns the fixture in inventory order.
    local *main::list_managed_servers_sorted = sub {@servers};
    # Statistics reads use the collector, never a new libvirt sample per request.
    local *main::get_libvirt = sub { die "Inventory API must not resample libvirt\n" };
    local *main::statistics_latest = sub { return {vms => {map {
        $_->{uuid} => {resources => {disk_capacity_bytes => 25 * 1024 ** 3}}
    } @servers}}; };
    # get_vm_jobs() supplies a private creation record to test public filtering.
    local *main::get_vm_jobs = sub {bless {},'MachinesAPIJobs'};
    # get_vm_service() fails if inventory tries to load the creation service.
    local *main::get_vm_service = sub {die "Machine reads must not open the creation service\n"};
    # get_server_addresses(server) records probes and returns a test address.
    local *main::get_server_addresses = sub {push(@probed,$_[0]->{uuid}); return $_[0]->{active} ? ('192.0.2.1') : ();};
    # is_readonly_mode() makes inventory run under read-only access throughout.
    local *main::is_readonly_mode = sub {1};
    # Host administrators receive both summaries, but no private request fields.
    %access = (admin=>1);
    my $rows = call_vm_api(1,'machines',{});
    is_deeply([map {$_->{name}} @$rows],[qw(alpha beta)],'visible inventory order retained');
    is($rows->[0]->{disk_gib},25,'total includes every writable disk and excludes media');
    is($rows->[0]->{memory_mib},2048,'inventory memory converted from KiB');
    is($rows->[0]->{cpus},2,'CPU count');
    is($rows->[1]->{state},'stopped','stopped state normalized');
    is_deeply($rows->[0]->{addresses},['192.0.2.1'],'address strings');
    # Attach only creation time and preset names from the matching private job.
    is($rows->[0]->{created},1700000000,'creation time from matching job');
    is($rows->[0]->{template},'Default Template','attached template name');
    is($rows->[0]->{plan},'Default Plan','attached plan from matching creation job');
    like(convert_to_json($rows,0,1),qr/"autostart":true/,'autostart is a JSON boolean');
    unlike(convert_to_json($rows,0,1),qr/secret|license|request|password/,'private metadata is excluded');
    # Both exact names and UUIDs select one object rather than an array.
    is(call_vm_api(1,'machines',{id=>'alpha'})->{id},$one,'name resolves to UUID');
    is(call_vm_api(1,'machines',{id=>$two})->{name},'beta','UUID resolves to name');
    # Delegation must filter before probing, including address and preset reads.
    %access = (admin=>0,vms=>$one);
    @probed=();
    $rows=call_vm_api(1,'machines',{});
    is(scalar(@$rows),1,'delegated viewer sees only assigned guest');
    ok(!grep({$_ eq $two} @probed),'unassigned guest is not probed');
    is($rows->[0]->{template},'Default Template','viewer can see attached preset name without host access');
    # Hidden guests and nonexistent selectors must be indistinguishable.
    for my $id ($two,'beta','missing') {
        ok(!eval {call_vm_api(1,'machines',{id=>$id});1},'hidden or missing guest refused');
        is($@,"Virtual machine not found\n",'same error hides inaccessible guest existence');
    }
    # No assignments should return an empty list without probing any guest.
    %access = (admin=>0);
    @probed=();
    is_deeply(call_vm_api(1,'machines',{}),[],'no assignments means an empty inventory');
    is_deeply(\@probed,[],'empty visible inventory performs no detail reads');
    # Report malformed selectors and backend errors instead of empty inventory.
    %access=(admin=>1);
    foreach my $id ('',[],{}) {ok(!eval {call_vm_api(1,'machines',{id=>$id});1},'malformed selector rejected');}
    local $cloudmin_last_error='libvirt connection failed';
    ok(!eval {call_vm_api(1,'machines',{});1},'inventory failure is not an empty success');
    like($@,qr/libvirt connection failed/,'inventory failure explained');
}
{
    no warnings qw(redefine once);
    # list_managed_servers_sorted() supplies duplicate names to test ambiguity.
    local *main::list_managed_servers_sorted = sub {({%{$servers[0]},name=>'duplicate'},{%{$servers[1]},name=>'duplicate'})};
    # is_readonly_mode() removes read-only policy as a possible failure cause.
    local *main::is_readonly_mode = sub {0};
    %access=(admin=>1);
    ok(!eval {call_vm_api(1,'machines',{id=>'duplicate'});1},'ambiguous names refused');
    like($@,qr/Ambiguous/,'ambiguity asks for UUID');
}
done_testing();
