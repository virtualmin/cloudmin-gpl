use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP qw(encode_json decode_json);
require "$Bin/../lib/Cloudmin/Backups.pm";
require "$Bin/../lib/Cloudmin/Jobs.pm";
require "$Bin/../lib/Cloudmin/BackupTransport.pm";
require "$Bin/../lib/Cloudmin/Libvirt.pm";

# Inventory must expose useful metadata without returning saved credentials.
my $uuid = '12345678-1234-1234-1234-123456789abc';
my $id = 'a' x 32;
my $store = Cloudmin::Backups->new(directory => tempdir(CLEANUP => 1));
$store->record($id, {id => $id, name => 'fixture', created => 1, target => {secret => 'private'}});
is($store->inventory()->[0]->{name}, 'fixture', 'inventory returns records rather than flattened fields');
ok(!exists($store->inventory()->[0]->{target}), 'inventory excludes private transport settings');
# Invalid identities, duplicate mappings and unreferenced disks cannot restore.
my $m = {name => 'server.example.test', uuid => $uuid,
 files => {disk0 => {size => 4096}, nvram => {size => 4096}},
 disks => [{target => 'vda', file => 'disk0', format => 'qcow2', capacity => 4096}], nvram_format => 'raw'};
ok(eval {Cloudmin::Backups::validate_manifest($m); 1}, 'valid restore identity and disk mapping');
for my $bad ({%$m, uuid => '../../host'}, {%$m, disks => [@{$m->{disks}}, @{$m->{disks}}]},
 {%$m, nvram_format => 'vmdk'}, {%$m, virtualmin => 'unknown'},
 {%$m, files => {%{$m->{files}}, disk1 => {size => 4096}}}) {
 ok(!eval {Cloudmin::Backups::validate_manifest($bad); 1}, 'invalid restore manifest rejected');
}

# XML checks require LibXML; the remaining tests still run without it.
SKIP: {
 skip 'XML::LibXML is unavailable', 18 if (!eval {require XML::LibXML; 1});
 my $xml = qq{<domain type="kvm"><name>$m->{name}</name><uuid>$uuid</uuid>
 <os><type arch="x86_64">hvm</type><nvram>/old/vars.fd</nvram></os>
 <devices><disk type="file" device="disk"><driver name="qemu" type="qcow2"/><source file="/old/root"/>
 <backingStore/><target dev="vda" bus="virtio"/><serial>guest-disk-id</serial></disk>
 <interface type="network"><source network="default"/><mac address="52:54:00:12:34:56"/></interface>
 <graphics type="vnc" port="5901" listen="0.0.0.0" passwd="fixture-password"/>
 <channel type="unix"><source path="/old/socket"/><target name="org.qemu.guest_agent.0"/></channel></devices></domain>};
 # Rebind host paths while retaining the guest UUID, MAC and disk identity.
 my $restored = Cloudmin::Backups::restore_xml($xml, $m, $id, {disk0 => {path => '/new/disk'}}, {path => '/new/vars'});
 my $doc = Cloudmin::Libvirt::parse_xml_document($restored);
 is($doc->findvalue('/domain/uuid'), $uuid, 'restore keeps UUID');
 is($doc->findvalue('/domain/devices/interface/mac/@address'), '52:54:00:12:34:56', 'restore keeps MAC');
 is($doc->findvalue('/domain/devices/disk/serial'), 'guest-disk-id', 'restore keeps guest-visible disk identity');
 is($doc->findvalue('/domain/devices/disk/source/@file'), '/new/disk', 'restore replaces host disk path');
 is($doc->findvalue('/domain/os/nvram'), '/new/vars', 'restore replaces host firmware path');
 is(Cloudmin::Libvirt::extract_metadata($restored)->{job}, $id, 'new ownership marker supports cleanup');
 is($doc->findvalue('/domain/devices/graphics/@listen'), '127.0.0.1', 'restored console remains private');
 ok(!$doc->exists('/domain/devices/channel/source | /domain/devices/disk/backingStore'), 'stale host socket and backing paths removed');
 # Neither extra XML disks nor host firmware files may escape manifest checks.
 my $extra = $xml;
 $extra =~ s{</devices>}{<disk type="file" device="disk"><source file="/unlisted"/><target dev="vdc"/></disk></devices>};
 ok(!eval {Cloudmin::Backups::restore_xml($extra,$m,$id,{disk0 => {path=>'/new/disk'}},{path=>'/new/vars'});1}, 'restore rejects XML disks absent from the manifest');
 # Firmware extensions can reference host files outside the archived disks.
 for my $extension (
  '<sysinfo type="fwcfg"><entry name="opt/fixture" file="/host/private"/></sysinfo>',
  '<os><type arch="x86_64">hvm</type><acpi><table type="raw">/host/table</table></acpi></os>') {
  my $external=$xml;
  # OS extensions replace the existing block; sysinfo is a domain sibling.
  if ($extension =~ /^<os>/) { $external =~ s{<os>.*?</os>}{$extension}s; }
  # Test an external sysinfo file without changing the existing OS block.
  else { $external =~ s{</domain>}{$extension</domain>}; }
  eval {Cloudmin::Backups::check_external_state(Cloudmin::Libvirt::parse_xml_document($external))};
  like($@,qr/unsupported external host resources/,'backup refuses unarchived firmware files');
  ok(!eval {Cloudmin::Backups::restore_xml($external,$m,$id,{disk0=>{path=>'/new/disk'}},{path=>'/new/vars'});1},'restore refuses firmware paths from another host');
 }
 # The verified manifest controls firmware format and requires a matching
 # device.
 my $wrong_format=$xml; $wrong_format =~ s{<nvram>}{<nvram format="qcow2">};
 my $fixed=Cloudmin::Libvirt::parse_xml_document(Cloudmin::Backups::restore_xml($wrong_format,$m,$id,{disk0=>{path=>'/new/disk'}},{path=>'/new/vars'}));
 is($fixed->findvalue('/domain/os/nvram/@format'),'raw','firmware uses its verified archive format');
 my $missing_firmware=$xml; $missing_firmware =~ s{<nvram>.*?</nvram>}{};
 ok(!eval {Cloudmin::Backups::restore_xml($missing_firmware,$m,$id,{disk0=>{path=>'/new/disk'}},{path=>'/new/vars'});1},'restore rejects firmware without a matching XML device');
 # Restoring must retain the Pro warning when the restored VM is later cloned.
 {
  no warnings qw(redefine once);
  local *Cloudmin::Jobs::get = sub {return {state=>'complete', request=>{operation=>'restore',uuid=>$uuid},resources=>{virtualmin=>'pro'}}};
  my $service = bless({jobs=>bless({},'Cloudmin::Jobs')},'Cloudmin::Clones');
  is($service->installed_edition($doc), 'pro', 'restored Pro edition remains available to cloning');
  $doc->findnodes('/domain/uuid')->[0]->removeChildNodes();
  is($service->installed_edition($doc), '', 'edition record must match the restored guest UUID');
 }
 $xml =~ s{</devices>}{<filesystem type="mount"><source dir="/etc"/></filesystem></devices>};
 ok(!eval {Cloudmin::Backups::restore_xml($xml,$m,$id,{disk0 => {path=>'/new/disk'}},{path=>'/new/vars'});1}, 'restore rejects shared host filesystems');
}

# A restored seed must remain distinguishable from unrelated read-only disks,
# including when a file-backed backup is restored into a logical volume.
SKIP: {
 skip 'XML::LibXML is unavailable', 3 if (!eval {require XML::LibXML; 1});
 my $old = 'a' x 32;
 my $source = qq{<domain><name>fixture</name><uuid>$uuid</uuid>
 <metadata><vm xmlns="urn:cloudmin:vm:1"><job>$old</job></vm></metadata><devices>
 <disk type="file" device="disk"><driver type="qcow2"/><source file="/old/cloudmin-fixture-system-$old.qcow2"/><target dev="vda"/></disk>
 <disk type="file" device="disk"><driver type="raw"/><source file="/old/cloudmin-fixture-seed-$old.iso"/><target dev="vdb"/><readonly/></disk>
 <disk type="file" device="disk"><driver type="raw"/><source file="/old/reference.raw"/><target dev="vdc"/><readonly/></disk>
 </devices></domain>};
 my $manifest = {name => 'fixture', uuid => $uuid, disks => [
  {file => 'disk0', target => 'vda', format => 'qcow2'},
  {file => 'disk1', target => 'vdb', format => 'raw'},
  {file => 'disk2', target => 'vdc', format => 'raw'}]};
 foreach my $type ('dir', 'logical', 'lvmthin') {
  my $names = Cloudmin::Backups::restore_volume_names($source, $manifest, $id, $type);
  my %volumes = map { $_ => {path => $type eq 'dir' ? '/new/'.$names->{$_}
   : Cloudmin::LVM::device_path('guest-vg', $names->{$_}), block => $type ne 'dir'} } keys %$names;
  my $restored = Cloudmin::Backups::restore_xml($source, $manifest, $id, \%volumes);
  is_deeply([map { $_->{'role'} } Cloudmin::Libvirt::extract_disks($restored)],
   [qw(system seed disk)], "restore into $type preserves seed and system roles without treating read-only data as a seed");
 }
}

# Provider availability must agree across UI and backend entry points.
for my $pro (0, 1) {
 no warnings 'redefine';
 local *Cloudmin::BackupTransport::has_pro_providers = sub {$pro};
 is_deeply([Cloudmin::BackupTransport::modes()],
  [qw(local ssh s3), $pro ? qw(gcs azure bb dropbox drive) : ()], "provider list matches edition (Pro=$pro)");
 for my $mode (qw(local ssh s3 gcs azure bb dropbox drive)) {
  my $target = {mode => $mode, path => '/backups', host => 'storage.example.test', user => 'backup',
   key_file => '/private/key', bucket => 'backups', access => 'fixture', secret => 'fixture', refresh_token => 'fixture', account => 'fixture'};
  # Installed providers must pass the same field validation in either edition.
  if ($pro || $mode =~ /\A(?:local|ssh|s3)\z/) {
   ok(eval {Cloudmin::BackupTransport::validate($target); 1}, "$mode destination accepted (Pro=$pro)");
  }
  else {
   # Every entry point rejects Pro providers before files or remote connections.
   for my $call (
    sub {Cloudmin::BackupTransport::validate($target)},
    sub {Cloudmin::BackupTransport::saved_target($target,$target)},
    sub {Cloudmin::BackupTransport::preflight($target,0)},
    sub {Cloudmin::BackupTransport::transfer('put',$target,'fixture.tar','/missing')},
    sub {Cloudmin::BackupTransport::remote({target=>$target,operation=>'get',filename=>'fixture.tar'})}) {
    eval {$call->()};
    like($@,qr/requires Cloudmin Pro/,"$mode cannot bypass the GPL restriction");
   }
  }
  unlike(Cloudmin::BackupTransport::label({%$target, secret => 'do-not-display'}), qr/do-not-display/, 'destination label excludes credentials');
 }
}
# Reject unsafe paths, insecure endpoints and missing SSH authentication.
for my $target ({mode=>'ssh',path=>'/backups/*',host=>'host',user=>'root',password=>'fixture'},
 {mode => 'local',path => '../etc'}, {mode => 's3',path => 'safe',bucket => 'b',endpoint => 'http://unsafe'},
 {mode => 'ssh',path => '/backups',host => 'host',user => 'root',password => ''}) {
 ok(!eval {Cloudmin::BackupTransport::validate($target); 1}, 'unsafe destination rejected');
}
# Saved secrets remain private and change only when explicitly replaced or cleared.
my $saved = {mode=>'s3',path=>'daily',bucket=>'fixture',access=>'id',secret=>'saved-secret',session_token=>'saved-token'};
my $kept = Cloudmin::BackupTransport::saved_target({%$saved,secret=>'',session_token=>''},$saved);
is($kept->{secret},'saved-secret','blank credential keeps the saved value');
is($kept->{session_token},'saved-token','blank optional token is retained');
is(Cloudmin::BackupTransport::saved_target({%$saved,secret=>'replacement'},$saved)->{secret},'replacement','new credential replaces saved value');
is(Cloudmin::BackupTransport::saved_target({%$saved,session_token_clear=>1},$saved)->{session_token},'','optional credential can be cleared');
ok(!eval {Cloudmin::BackupTransport::saved_target({%$saved,secret_clear=>1},$saved);1},'required credential cannot be silently removed');
ok(!eval {Cloudmin::BackupTransport::saved_target({%$saved,mode=>'bb',secret=>''},$saved);1},'changing providers never reuses the previous secret');
# Human-readable filenames still carry a collision-resistant job identifier.
like(Cloudmin::Backups::archive_filename('host.example.test',$id,0,1),qr/^cloudmin-host\.example\.test-19700101T000000Z-$id\.tar\.gz$/,'archive name includes machine, UTC date and collision-safe ID');
unlike(Cloudmin::Backups::archive_filename('../odd / name',$id,0,0),qr{[/\s]},'archive name cannot add directories or whitespace');

# Firmware must remain stable across both the disk snapshot and the copy.
{
 require File::Copy;
 my $dir=tempdir(CLEANUP=>1); my $source="$dir/vars"; my $dest="$dir/copy";
 open(my $fh,'>',$source) or die $!; print($fh 'firmware'); close($fh);
 my $identity=Cloudmin::VMManage::file_identity($source);
 my $hash=Cloudmin::Backups::firmware_digest($source,$identity);
 no warnings 'redefine';
 local *Cloudmin::Worker::copy_file = sub {File::Copy::copy($_[0],$_[1]) or die $!};
 ok(eval {Cloudmin::Backups::copy_firmware($source,$dest,$identity,$hash);1},'stable live firmware can be copied');
 open($fh,'>',$source) or die $!; print($fh 'modified'); close($fh);
 ok(!eval {Cloudmin::Backups::copy_firmware($source,$dest,$identity,$hash);1},'firmware changed since the snapshot is rejected');
 $hash=Cloudmin::Backups::firmware_digest($source,$identity);
 # copy_file(source, destination, limit) simulates a write during the copy.
 local *Cloudmin::Worker::copy_file = sub {
  File::Copy::copy($_[0],$_[1]) or die $!;
  open(my $out,'>',$_[0]) or die $!; print($out 'changed again'); close($out);
 };
 ok(!eval {Cloudmin::Backups::copy_firmware($source,$dest,$identity,$hash);1},'firmware changed during copying is rejected');
}

# Empty inventories use useful empty states, and populated tables fill their cards.
{
 require WebminCore; WebminCore->import();
 our ($module_root_directory,$root_directory,%text);
 $module_root_directory="$Bin/.."; $root_directory=$CloudminTest::webmin_root;
 require "$Bin/../cloudmin-backup-pages.pl";
 open(my $lang,'<',"$Bin/../lang/en") or die $!;
 while (<$lang>) {chomp; $text{$1}=$2 if /^([^=]+)=(.*)$/;}
 no warnings qw(redefine once);
 local *main::get_backup_service=sub {$store};
 local *Cloudmin::Backups::inventory=sub {[]};
 local *main::backup_schedules=sub {[]};
 my $empty=main::show_backup_list('token');
 like($empty,qr/No backups yet/,'empty backups offer a clear next step');
 unlike($empty,qr/<table\b/,'empty cards do not print useless table headers');
 my $form=main::show_backup_destination('dest0',$saved);
 unlike($form,qr/saved-secret|saved-token/,'stored credentials never appear in the HTML');
 like($form,qr/Leave blank to keep the saved value/,'saved credentials explain blank input');
 # Both selectors expose disabled previews without permitting Pro transfers.
 for my $pro (0, 1) {
  local *Cloudmin::BackupTransport::has_pro_providers = sub {$pro};
  my $dest=main::show_backup_destination('dest0',$saved);
  my ($select)=$dest =~ m{<select\b[^>]*name="dest0_mode"[^>]*>(.*?)</select>}s;
  my @enabled = map { /value="([a-z0-9]+)"/; $1 } grep { !/\bdisabled\b/ } ($select =~ /(<option\b[^>]*>)/g);
  is_deeply(\@enabled, [Cloudmin::BackupTransport::modes()],
   "enabled destinations match the backend (Pro=$pro)");
  unlike($dest,qr/experimental/i,'provider names have no experimental label');
 }
 # Default choices override stale textbox contents, and one SSH method is used.
 my $input={dest0_mode=>'ssh',dest0_ssh_port=>'2222',dest0_ssh_port_def=>1,
  dest0_ssh_authentication=>'password',dest0_ssh_password=>'fixture',dest0_ssh_key_file=>'/old/key'};
 my $target=main::parse_backup_target($input,'dest0');
 is($target->{port},'','default SSH port ignores stale custom text');
 is($target->{key_file},'','password authentication ignores the hidden private key');
 $target=main::parse_backup_target({%$input,dest0_ssh_authentication=>'key',dest0_ssh_port_def=>0},'dest0');
 is($target->{port},'2222','custom SSH port is retained');
 ok($target->{password} eq '' && $target->{password_clear},'private key selection clears the saved password');
 is($target->{key_file},'/old/key','private key selection retains the file');
 is($target->{user},'root','private key authentication defaults to root when blank');
 is(main::parse_backup_target({%$input,dest0_ssh_authentication=>'key',dest0_ssh_user=>'backup'},'dest0')->{user},
  'backup','hiding the username retains a custom login');
 my $s3=main::parse_backup_target({src_mode=>'s3',src_s3_endpoint=>'https://old.example',src_s3_endpoint_def=>1,
  src_s3_region=>'eu-west-1',src_s3_region_def=>1,src_s3_ca_file=>'/old/ca',src_s3_ca_file_def=>1},'src');
 is_deeply([@{$s3}{qw(endpoint region ca_file)}],['','',''],'default S3 settings clear custom values');
 # Populated rows must retain escaping and fill the standard inventory card.
 local *Cloudmin::Backups::inventory=sub {[{id=>$id,name=>'<fixture>',created=>1,size=>4096,destination=>'local'}]};
 local *main::make_date=sub {'date'};
 local *main::nice_size=sub {'4 KiB'};
 my $full=main::show_backup_list('token');
 like($full,qr/&lt;fixture&gt;/,'guest names are escaped');
 like($full,qr/width=['"]?100%/,'inventory uses the full card width');
 # Hiding data columns must retain the correct archive's permitted actions.
 local $main::config{'backup_columns'} = 'name,size';
 my @tables;
 # ui_columns_table(@args) captures headings, rows and sort types.
 local *main::ui_columns_table = sub {push(@tables, [@_[0,2,3]]); return ''};
 main::show_backup_list('token');
 is_deeply($tables[0]->[0], [$text{'vm_name'}, $text{'backup_size'}, ''], 'reduced archive headings retain actions');
 is($tables[0]->[1]->[0]->[1], '4 KiB', 'archive size stays aligned');
 like($tables[0]->[1]->[0]->[2], qr/restore_form.cgi\?backup=$id/, 'archive actions keep the correct ID');
 # Configured columns cannot add actions to a read-only view.
 @tables = ();
 main::show_backup_list('');
 is(scalar(@{$tables[0]->[0]}), 2, 'read-only archive table contains no action column');
}
done_testing();
