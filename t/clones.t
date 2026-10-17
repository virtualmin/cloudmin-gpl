use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use Test::More;
use File::Temp qw(tempdir);
require "$Bin/../lib/Cloudmin/Clones.pm";
require "$Bin/../lib/Cloudmin/Jobs.pm";

# Exercise the actual XML rewrite with private firmware, two disks and media.
my $request = { name => 'copy.example.test', uuid => '22222222-2222-4222-8222-222222222222',
    memory_mib => 2048, cpus => 2, mac => '52:54:00:11:22:33',
    console_password => '12ab34cd', attachment => {type => 'network', source => 'default'},
    source_xml => q{<domain type="kvm"><name>original</name><uuid>11111111-1111-4111-8111-111111111111</uuid>
      <hwuuid>11111111-aaaa-4aaa-8aaa-111111111111</hwuuid><sysinfo type="smbios"><system><entry name="uuid">11111111-1111-4111-8111-111111111111</entry></system></sysinfo><memory unit="KiB">1048576</memory><currentMemory>1048576</currentMemory><vcpu current="1">4</vcpu>
      <cpu><topology sockets="4" cores="1" threads="1"/></cpu><genid>old</genid><metadata><old/></metadata>
      <os><smbios mode="host"/><type arch="aarch64">hvm</type><loader readonly="yes" type="pflash">/firmware</loader><nvram template="/template">/old.fd</nvram></os>
      <devices><disk type="file" device="disk"><driver type="qcow2"/><source file="/original"/><target dev="vda" bus="virtio"/><serial>old</serial><backingStore><source file="/base"/></backingStore></disk>
      <disk type="file" device="disk"><driver type="raw"/><source file="/seed"/><target dev="vdb" bus="virtio"/><readonly/></disk>
      <disk type="file" device="disk"><driver type="raw"/><source file="/data"/><target dev="vdc" bus="virtio"/></disk>
      <interface type="network"><mac address="52:54:00:aa:bb:cc"/><source network="old"/><target dev="vnet0"/></interface>
      <graphics type="vnc" port="5901" passwd="old" websocket="5701"><listen type="address" address="0.0.0.0"/></graphics>
      <channel type="unix"><source path="/old.agent"/><target type="virtio" name="org.qemu.guest_agent.0"/></channel>
      <console type="file"><source path="/old.log"/></console></devices></domain>} };
my $xml = Cloudmin::Clones::domain_xml($request, 'a'x32, [{path=>'/copy'}, {path=>'/data-copy'}], {path=>'/new-seed'}, {path=>'/new.fd'});
my $doc = Cloudmin::Libvirt::parse_xml_document($xml);
# Identity and resource values must no longer refer to the source domain.
is($doc->findvalue('/domain/name'), $request->{'name'}, 'new domain name');
is($doc->findvalue('/domain/uuid'), $request->{'uuid'}, 'new domain UUID');
ok(!$doc->exists('/domain/hwuuid | /domain/sysinfo'), 'source hardware identity removed');
is($doc->findvalue('/domain/os/smbios/@mode'), 'emulate', 'physical host DMI is not exposed');
is($doc->findvalue('/domain/memory/@unit'), 'MiB', 'memory unit follows requested value');
ok(!$doc->exists('/domain/currentMemory | /domain/cpu/topology | /domain/genid'), 'old resource topology and generation removed');
is_deeply([map { $_->getValue() } $doc->findnodes('/domain/devices/disk/source/@file')],
    ['/copy', '/data-copy', '/new-seed'], 'every writable disk copied and seed replaced');
ok(!$doc->exists('//backingStore | //serial[text()]'), 'no source chain or disk serial reused');
is($doc->findvalue('/domain/devices/interface/mac/@address'), $request->{'mac'}, 'fresh MAC');
is($doc->findvalue('/domain/devices/interface/source/@network'), 'default', 'selected network');
# Firmware and console endpoints belong to the new guest, not its source.
is($doc->findvalue('/domain/os/nvram'), '/new.fd', 'private NVRAM copy');
is($doc->findvalue('/domain/devices/graphics/@passwd'), '12ab34cd', 'fresh console credential');
is($doc->findvalue('/domain/devices/graphics/listen/@address'), '127.0.0.1', 'console stays local');
ok(!$doc->exists('/domain/devices/channel/source | /domain/devices/console/source | /domain/devices/graphics/@websocket'), 'runtime sockets and ports reset');
my $fresh = Cloudmin::Libvirt::parse_xml_document(Cloudmin::Clones::domain_xml($request, 'a'x32, [{path=>'/copy'}, {path=>'/data'}]));
is($fresh->findvalue('/domain/os/nvram'), '', 'fresh UEFI lets libvirt allocate its own variables');
is($fresh->findvalue('/domain/os/nvram/@template'), '/template', 'firmware template retained');
my $unchanged = Cloudmin::Libvirt::parse_xml_document(Cloudmin::Clones::domain_xml(
    {%$request, clone_mode=>'unchanged'}, 'a'x32,
    [{path=>'/copy',format=>'qcow2'}, {path=>'/copied-seed',format=>'raw'}, {path=>'/data',format=>'qcow2'}]));
is($unchanged->findvalue('/domain/devices/disk[readonly]/source/@file'), '/copied-seed', 'unchanged copy has an independent seed');
is($unchanged->findvalue('/domain/devices/disk[readonly]/driver/@type'), 'raw', 'unchanged seed retains its raw format');

# Unsupported devices must fail in source validation, before storage work.
{
    package CloneSourceDomain;
    # has_managed_save_image(self) models a source without saved RAM state.
    sub has_managed_save_image { 0 }
    # list_all_checkpoints(self) supplies a source without backup checkpoints.
    sub list_all_checkpoints { () }
    # get_state(self) supplies libvirt's shutoff state for hardware validation.
    sub get_state { 5 }
    # is_active(self) keeps device validation independent of a running guest.
    sub is_active { 0 }
    package main;
    my $source_doc;
    my $service = bless({}, 'Cloudmin::Clones');
    my $domain = bless({}, 'CloneSourceDomain');
    no warnings qw(redefine once);
    local *Cloudmin::VMManage::get_guest = sub { (undef, $domain, $source_doc) };
    local *Cloudmin::Snapshots::check_history_storage = sub { die "Reached storage validation\n"; };
    for my $case (
        ['<graphics type="spice"/>', qr/VNC graphical consoles/, 'SPICE'],
        ['<tpm model="tpm-crb"><backend type="emulator" version="2.0"/></tpm>', qr/TPMs/, 'emulated TPM'],
        ['<graphics type="vnc"/>', qr/Reached storage validation/, 'VNC'],
        ['', qr/Reached storage validation/, 'serial-only'],
    ) {
        $source_doc = Cloudmin::Libvirt::parse_xml_document('<domain><devices>'.$case->[0].'</devices></domain>');
        eval { $service->source('fixture'); };
        like($@, $case->[1], "$case->[2] checked before storage validation");
    }
}

# Real SQLite submission must reserve both objects until cleanup succeeds.
SKIP: {
    skip 'SQLite bindings required', 10 unless eval { Cloudmin::Jobs::dependencies(); 1 };
    my $dir = tempdir(CLEANUP=>1);
    my $jobs = Cloudmin::Jobs->new(directory=>"$dir/jobs", lock_file=>sub {1}, unlock_file=>sub {1}, test_lock=>sub {0}, log=>sub {});
    my $uuid = '11111111-1111-4111-8111-111111111111';
    $jobs->submit('a'x32, 'root', 'vm:copy', {operation=>'clone', source_uuid=>$uuid});
    ok(!eval { $jobs->submit('b'x32,'root','guest:'.$uuid,{operation=>'delete',uuid=>$uuid}); 1 }, 'source cannot be deleted during clone');
    ok(!eval { $jobs->submit('b'x32,'root','vm:copy',{}); 1 }, 'destination name also reserved');
    ok(!eval { $jobs->assert_guest_available($uuid); 1 }, 'power and direct operations blocked');
    $jobs->update('a'x32, sub { $_[0]->{'state'}='failed'; $_[0]->{'cleanup_pending'}=1 });
    # Failed source restoration must retain its reservation until recovery.
    ok(!eval { $jobs->submit('b'x32,'root','guest:'.$uuid,{}); 1 }, 'failed cleanup retains source');
    $jobs->update('a'x32, sub { $_[0]->{'resources'}={'shutdown_requested'=>1}; });
    # Allow stopping a stuck shutdown without allowing startup or new work.
    ok(eval { $jobs->assert_guest_available($uuid, 'force_off'); 1 }, 'failed pending shutdown allows source stop for recovery');
    ok(!eval { $jobs->assert_guest_available($uuid, 'start'); 1 }, 'failed pending shutdown still blocks source startup');
    $jobs->update('a'x32, sub { $_[0]->{'resources'}->{'shutdown_complete'}=1; });
    ok(!eval { $jobs->assert_guest_available($uuid, 'force_off'); 1 }, 'completed shutdown does not bypass a failed clone reservation');
    $jobs->update('a'x32, sub { $_[0]->{'cleanup_pending'}=0 });
    # Successful cleanup releases the source, including for later edit jobs.
    ok(eval { $jobs->assert_guest_available($uuid); 1 }, 'clean rollback releases source');
    ok($jobs->submit('b'x32,'root','guest:'.$uuid,{operation=>'update',uuid=>$uuid}), 'source edit can follow rollback');
    ok(!eval { $jobs->submit('c'x32,'root','vm:another',{operation=>'clone',source_uuid=>$uuid}); 1 }, 'existing edit prevents clone in reverse order');
}
# Render the real clone form with localized labels and an isolated preset store.
{
    require WebminCore;
    WebminCore->import();
    our ($module_root_directory, $root_directory, %text, %config);
    $module_root_directory = "$Bin/..";
    $root_directory = $CloudminTest::webmin_root;
    require "$Bin/../cloudmin-pages.pl";
    require "$Bin/../lib/Cloudmin/Presets.pm";
    open(my $lang, '<', "$Bin/../lang/en") or die $!;
    while (<$lang>) { chomp; $text{$1}=$2 if /^([^=]+)=(.*)$/; }
    my $dir = tempdir(CLEANUP=>1);
    my $store = Cloudmin::Presets->new(directory=>$dir, access=>sub {}, lock=>sub {1}, unlock=>sub {});
    no warnings qw(redefine once);
    local *main::get_presets = sub { $store };
    my $source = {id=>'source', name=>'Source <guest>', revision=>'revision',
        cpus=>2, memory_mib=>2048, disks=>[{bytes=>20*1024**3}], active=>1, nvram=>1,
        presets=>{map { $_=>$store->list($_) } qw(template plan)},
        options=>{pools=>[{id=>'pool',name=>'Pool',available=>30*1024**3}], networks=>[{key=>'network:test',name=>'Test'}]}};
    my $html = main::show_vm_clone_form($source, 'token');
    # The form carries source revision and consent fields, never source secrets.
    like($html, qr/Source &lt;guest&gt;/, 'source display name escaped');
    like($html, qr/name="revision"[^>]*value="revision"/, 'source revision bound to submission');
    like($html, qr/name="clone_mode"/, 'prepared and unchanged choices available');
    like($html, qr/name="nvram_mode"/, 'firmware choice available');
    like($html, qr/machine_clone\.js/, 'clone initializer loaded');
    like($html, qr/<form[^>]*action=['"]clone_machine\.cgi['"]/, 'clone selects native theme streaming');
    unlike($html, qr/name="action"/, 'clone leaves the form action URL accessible');
    unlike($html, qr/name="virtualmin_(?:key|serial)"/, 'clone never asks for installation credentials');
    like($html, qr/<option[^>]*(?:value="fresh"[^>]*selected|selected[^>]*value="fresh")/,
        'running source defaults to fresh firmware');
    my $stopped = main::show_vm_clone_form({%$source, active=>0}, 'token');
    like($stopped, qr/<option[^>]*(?:value="copy"[^>]*selected|selected[^>]*value="copy")/,
        'stopped source defaults to copied firmware');
}
done_testing();
