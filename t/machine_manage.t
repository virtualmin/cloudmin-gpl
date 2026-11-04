use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use Test::More;
use File::Temp qw(tempdir);
use Digest::SHA qw(sha256_hex);
require "$Bin/../lib/Cloudmin/Jobs.pm";
require "$Bin/../lib/Cloudmin/VMManage.pm";
plan skip_all => 'SQLite and XML::LibXML are required'
	if (!eval { Cloudmin::Jobs::dependencies(); require XML::LibXML; 1 });

# Disk contents live only in memory; real inode checks run in the live suite.
no warnings qw(redefine once);
local *Cloudmin::VMManage::file_identity = sub { return $_[0]; };
my @operation_details;
local *Cloudmin::Libvirt::additional_log = sub {
	push(@operation_details, $_[2]);
	};

{
	package Sys::Virt::Domain;
	# XML_INACTIVE() supplies the libvirt constant for workstation fixtures.
	sub XML_INACTIVE { return 2; }
	# Match libvirt's ABI when the native bindings are absent on the workstation.
	BEGIN {
		eval { require Sys::Virt; 1 };
		no strict 'refs';
		my %flags = (DEVICE_MODIFY_LIVE => 1, DEVICE_MODIFY_CONFIG => 2,
			VCPU_LIVE => 1, VCPU_CONFIG => 2, MEM_LIVE => 1, MEM_CONFIG => 2,
			METADATA_DESCRIPTION => 0, BLOCK_RESIZE_BYTES => 1);
		foreach my $name (keys %flags) {
			# Keep installed native constants; fill only
			# missing workstation stubs.
			my $value = $flags{$name};
			*{$name} = sub { $value } if (!defined(&$name));
			}
		}
	package ManageDomain;
	# Domain fixture methods expose the persistent definition and saved state.
	# get_uuid_string(self) keeps guest identity stable across edits.
	sub get_uuid_string { return $_[0]->{'uuid'}; }
	# get_name(self) supplies the deletion confirmation name.
	sub get_name { return 'fixture'; }
	# is_persistent(self) models a saved domain.
	sub is_persistent { return 1; }
	# is_active(self) reports the fixture's current power state.
	sub is_active { return $_[0]->{'active'} || 0; }
	# get_state(self) supplies running/stopped state and the last stop
	# reason.
	sub get_state { return ($_[0]->is_active() ? ($_[0]->{'state'} || 1) : 5, $_[0]->{'reason'} // 1); }
	# shutdown(self) models refusal, timeout and changes made during the
	# wait.
	sub shutdown {
		$_[0]->{'shutdowns'}++;
		die "Shutdown refused\n" if ($_[0]->{'shutdown_refused'});
		# Accepted shutdowns stop unless the guest is
		# configured to ignore ACPI.
		$_[0]->{'active'} = 0 unless $_[0]->{'shutdown_stuck'};
		$_[0]->{'on_shutdown'}->() if ($_[0]->{'on_shutdown'});
	}
	# destroy(self) models immediate power-off without deleting guest storage.
	sub destroy {
		$_[0]->{'destroys'}++;
		die "Power-off refused\n" if ($_[0]->{'destroy_refused'});
		$_[0]->{'active'} = 0;
		$_[0]->{'reason'} = 2;
	}
	# create(self) boots the saved definition unless startup is refused.
	sub create {
		$_[0]->{'starts'}++;
		die "Start refused\n" if $_[0]->{'start_refused'};
		$_[0]->{'active'} = 1;
		$_[0]->{'live_xml'} = $_[0]->{'xml'};
	}
	# get_xml_description(self, [flags])
	# Defaults to live XML; bit 2 selects the saved definition.
	sub get_xml_description { return ($_[1] || 0) & 2 ? $_[0]->{'xml'} : $_[0]->{'live_xml'} || $_[0]->{'xml'}; }
	# mutate(self, method, value, flags) models independent live/config writes.
	sub mutate
	{
	my ($self, $method, $value, $flags) = @_;
	push(@{$self->{'calls'}}, [$method, $flags]);
	die "Live change refused\n" if (($flags & 1) && $self->{'fail_live'});
	foreach my $side (1, 2) {
		# Model LIVE success followed by CONFIG
		# failure as separate mutations.
		next if (!($flags & $side));
		die "Persistent save failed\n" if ($side == 2 && $self->{'fail_config'});
		next if ($side == 1 && $method eq 'detach_device' && $self->{'detach_pending'});
		my $key = $side == 1 ? 'live_xml' : 'xml';
		my $doc = Cloudmin::Libvirt::parse_xml_document($self->{$key} || $self->{'xml'});
		if ($method eq 'set_vcpus') {
			# A count change leaves the
			# configured CPU maximum intact.
			($doc->findnodes('/domain/vcpu'))[0]->setAttribute('current', $value);
			}
		elsif ($method eq 'set_memory' || $method eq 'set_metadata') {
			# Memory values arrive in KiB;
			# descriptions are unqualified text.
			Cloudmin::VMManage::set_text($doc->documentElement(),
				$method eq 'set_memory' ? 'currentMemory' : 'description', $value,
				$method eq 'set_memory' ? { unit => 'KiB' } : {});
			}
		else {
			# Replace the identified device, or
			# leave it absent for detach.
			my $node = Cloudmin::Libvirt::parse_xml_document($value)->documentElement();
			my $kind = $node->nodeName();
			my $identity = $node->findvalue($kind eq 'disk' ? 'target/@dev' : 'mac/@address');
			my $old = Cloudmin::VMManage::hotplug_device($doc, $kind, $identity);
			$old->unbindNode() if ($old);
			($doc->findnodes('/domain/devices'))[0]->appendChild($doc->importNode($node, 1))
				if ($method ne 'detach_device');
			}
		$self->{$key} = $doc->toString();
		}
	}
	# set_vcpus(self, count, flags) records enabled CPU changes per XML
	# view.
	sub set_vcpus { $_[0]->mutate('set_vcpus', @_[1,2]); }
	# set_memory(self, kib, flags) records the balloon target per XML view.
	sub set_memory { $_[0]->mutate('set_memory', @_[1,2]); }
	# set_metadata(self, type, value, key, uri, flags) forwards the
	# description.
	sub set_metadata { $_[0]->mutate('set_metadata', $_[2], $_[5]); }
	# attach_device(self, xml, flags) adds an attachment to the selected
	# views.
	sub attach_device { $_[0]->mutate('attach_device', @_[1,2]); }
	# detach_device(self, xml, flags) removes an attachment or leaves it
	# pending.
	sub detach_device { $_[0]->mutate('detach_device', @_[1,2]); }
	# update_device(self, xml, flags) replaces the identified fixture
	# attachment.
	sub update_device { $_[0]->mutate('update_device', @_[1,2]); }
	# block_volume(self, target) resolves the fixture disk's actual image.
	sub block_volume
	{
	my ($self, $target) = @_;
	my $doc = Cloudmin::Libvirt::parse_xml_document($self->{'live_xml'} || $self->{'xml'});
	my $disk = Cloudmin::VMManage::hotplug_device($doc, 'disk', $target);
	my $path = $disk->findvalue('source/@file');
	return (grep { $_->get_path() eq $path } values %{$self->{'pool'}->{'volumes'}})[0];
	}
	# get_block_info(self, target) reports capacity without a storage-pool refresh.
	sub get_block_info { return $_[0]->block_volume($_[1])->get_info(); }
	# block_resize(self, target, bytes, flags) changes the open image through QEMU.
	sub block_resize
	{
	push(@{$_[0]->{'calls'}}, ['block_resize', $_[3]]);
	$_[0]->block_volume($_[1])->{'capacity'} = $_[2];
	}
	# has_managed_save_image(self) injects saved memory as an edit blocker.
	sub has_managed_save_image { return $_[0]->{'saved'} || 0; }
	# list_all_snapshots(self, [flags]) injects protected snapshot history.
	sub list_all_snapshots { return @{$_[0]->{'snapshots'} || []}, ($_[0]->{'snapshot'} ? ($_[0]) : ()); }
	# list_all_checkpoints(self, [flags]) injects retained backup checkpoints.
	sub list_all_checkpoints { return $_[0]->{'checkpoint'} ? ($_[0]) : (); }
	# get_job_info(self) injects a running native job that must block
	# deletion.
	sub get_job_info { return { type => $_[0]->{'native_job'} || 0 }; }
	# get_block_job_info(self, target, flags) injects an active disk
	# operation.
	sub get_block_job_info { return { type => $_[0]->{'block_job'} || 0 }; }
	package ManageSnapshot;
	# get_xml_description(self, [flags]) supplies immutable snapshot history.
	sub get_xml_description { return $_[0]->{'xml'}; }
	package ManageVolume;
	# Volume fixture methods retain capacity, backing references and failures.
	# get_name(self) supplies the pool-local volume name.
	sub get_name { return $_[0]->{'name'}; }
	# get_key(self) uses the fixture path as a stable storage key.
	sub get_key { return $_[0]->get_path(); }
	# get_path(self) supplies a synthetic path without creating a file.
	sub get_path { return '/fixture/'.$_[0]->{'name'}; }
	# get_info(self) reports the capacity changed by resize.
	sub get_info { return { capacity => $_[0]->{'capacity'} }; }
	# get_xml_description(self, [flags]) supplies disk format and backing path.
	sub get_xml_description
	{
	return '<volume><target><format type="'.($_[0]->{'format'} || 'qcow2').'"/></target>'.
		($_[0]->{'backing'} ? '<backingStore><path>'.$_[0]->{'backing'}.
		'</path></backingStore>' : '').'</volume>';
	}
	# resize(self, bytes, [flags]) records growth and counts repeat calls.
	sub resize { $_[0]->{'capacity'} = $_[1]; $_[0]->{'resized'}++; }
	# delete(self, [flags]) models refusal or a lost reply after removal.
	sub delete
	{
	die "Storage temporarily unavailable\n" if ($_[0]->{'fail'});
	delete($_[0]->{'pool'}->{'volumes'}->{$_[0]->{'name'}});
	die "Delete reply lost\n" if ($_[0]->{'lost_reply'});
	}
	package ManagePool;
	# Pool fixture methods model active managed storage and sparse allocation.
	# is_active(self) permits managed volume operations.
	sub is_active { return 1; }
	# refresh(self, [flags]) needs no cache update for in-memory volumes.
	sub refresh { return 1; }
	# get_uuid_string(self) supplies the pool identity used by requests.
	sub get_uuid_string { return 'pool'; }
	# get_name(self) supplies the pool display name.
	sub get_name { return 'default'; }
	# get_info(self) supplies configurable space for allocation checks.
	sub get_info { return { available => $_[0]->{'available'} // 100*1024**3 }; }
	# get_xml_description(self, [flags]) models a local directory pool.
	sub get_xml_description { return '<pool type="dir"><target><path>/fixture</path></target></pool>'; }
	# list_all_volumes(self, [flags]) exposes created and surviving volumes.
	sub list_all_volumes { return values %{$_[0]->{'volumes'}}; }
	# create_volume(self, xml, [flags]) models allocation from volume XML.
	sub create_volume
	{
	my ($self, $xml) = @_;
	my $doc = Cloudmin::Libvirt::parse_xml_document($xml);
	my $name = $doc->findvalue('/volume/name');
	my $volume = $self->{'volumes'}->{$name} = bless({ name => $name,
		capacity => 0+$doc->findvalue('/volume/capacity'), pool => $self }, 'ManageVolume');
	return $volume;
	}
	# clone_volume(self, xml, original) models an independent libvirt clone.
	sub clone_volume
	{
	my ($self, $xml, $original) = @_;
	my $volume = $self->create_volume($xml);
	$volume->{'capacity'} = $original->{'capacity'};
	$volume->{'copied_from'} = $original->get_key();
	return $volume;
	}
	package ManageAdapter;
	our @ISA = ('Cloudmin::Libvirt');
	# Adapter fixture methods keep libvirt policy in the real management class.
	# uri(self) permits local storage policy checks.
	sub uri { return 'qemu:///system'; }
	# connect(self) reuses this object as the fake native connection.
	sub connect { return $_[0]; }
	# find_domain(self, uuid) returns the current guest or an absent result.
	sub find_domain { return $_[0]->{'domains'}->{$_[1]}; }
	# list_all_domains(self, [flags]) supplies all guest references.
	sub list_all_domains { return values %{$_[0]->{'domains'}}; }
	# list_all_storage_pools(self, [flags]) supplies the managed fixture pool.
	sub list_all_storage_pools { return $_[0]->{'pool'}; }
	# get_storage_pool_by_uuid(self, uuid) rejects unexpected pool identities.
	sub get_storage_pool_by_uuid { die 'Wrong pool' if $_[1] ne 'pool'; return $_[0]->{'pool'}; }
	# volume(self, pool, name, [key]) detects a changed native storage key.
	sub volume
	{
	my ($self, $pool, $name, $key) = @_;
	my $v = $self->{'pool'}->{'volumes'}->{$name};
	die "Volume replaced\n" if ($v && defined($key) && $key ne $v->get_key());
	return ($self->{'pool'}, $v);
	}
	# list_networks(self) offers one active virtual network.
	sub list_networks { return [{ id => 'nat', name => 'default', active => 1 }]; }
	# list_host_bridges(self, [networks]) offers one available host bridge.
	sub list_host_bridges { return [{ name => 'br-test', state => 'up' }]; }
	# list_domains(self, [strict]) supplies MAC addresses for conflict checks.
	sub list_domains
	{
	return [ map { { macs => [Cloudmin::Libvirt::extract_macs($_->{'xml'})] } }
		values %{$_[0]->{'domains'}} ];
	}
	# get_host_capabilities(self) supplies CPU and memory limits.
	sub get_host_capabilities { return { cpus => 8, memory_kib => 8*1024**2 }; }
	# define_domain(self, xml, [flags]) models refusal or a lost commit reply.
	sub define_domain
	{
	my ($self, $xml) = @_;
	die "Define refused\n" if ($self->{'fail_define'});
	my $doc = Cloudmin::Libvirt::parse_xml_document($xml);
	my $uuid = $doc->findvalue('/domain/uuid');
	$self->{'domains'}->{$uuid}->{'xml'} = $xml;
	$self->{'defines'}++;
	die "Reply lost\n" if ($self->{'lost_reply'});
	return $self->{'domains'}->{$uuid};
	}
	# undefine_domain(self, uuid) removes the fixture guest definition.
	sub undefine_domain { delete($_[0]->{'domains'}->{$_[1]}); }
	# removed_guest(self, uuid, job) records managed-key cleanup.
	sub removed_guest { $_[0]->{'keys_removed'}++; }
	package ManageImages;
	# list(self) returns imported images that must remain immutable.
	sub list { return $_[0]->{'images'} || []; }
	# get/path/with_lock model the existing image store's immutable-source lock.
	# get(self, id) looks up an imported image by its job ID.
	sub get { return (grep { $_->{'id'} eq $_[1] } @{$_[0]->list()})[0] || die 'Image job not found'; }
	# path(self, id, [suffix]) supplies the image lock identity.
	sub path { return $_[1]; }
	# with_lock(self, path, nodiff, callback) records entry without real locking.
	sub with_lock { $_[0]->{'locked'}++; return $_[3]->(); }
	}

my $uuid = '11111111-2222-4333-8444-555555555555';
my $root = tempdir(CLEANUP => 1);
my $serial = 0;
my $xml = '<domain type="kvm"><name>fixture</name><uuid>'.$uuid.'</uuid>'.
	'<memory unit="MiB">512</memory><vcpu>1</vcpu>'.
	'<os><type arch="x86_64">hvm</type><boot dev="hd"/></os>'.
	'<devices><disk type="file" device="disk"><driver type="qcow2"/>'.
	'<source file="/fixture/root.qcow2"/><target dev="vda" bus="virtio"/></disk>'.
	'<interface type="network"><mac address="52:54:00:11:22:33"/>' .
	'<source network="default"/><model type="virtio"/></interface>'.
	'<graphics type="vnc" passwd="fixture-private"/></devices></domain>';

# fixture() creates independent domain, volume, journal and management objects.
sub fixture
{
my %held;
my @audit;
@operation_details = ();
my $jobs = Cloudmin::Jobs->new(directory => "$root/".++$serial,
	lock_file => sub { die 'Nested lock' if $held{$_[0]}; $held{$_[0]} = 1 },
	unlock_file => sub { delete($held{$_[0]}); },
	test_lock => sub { return $held{$_[0]} }, log => sub {
		# Model Webmin attaching queued details to exactly this action entry.
		push(@audit, { action => $_[0], details => [@operation_details] });
		@operation_details = ();
		});
my $pool = bless({ volumes => {} }, 'ManagePool');
foreach my $name (qw(root.qcow2 extra.qcow2)) {
	$pool->{'volumes'}->{$name} = bless({ name => $name,
		capacity => 1024**3, pool => $pool }, 'ManageVolume');
	}
my $domain = bless({ uuid => $uuid, xml => $xml, pool => $pool }, 'ManageDomain');
my $adapter = bless({ domains => { $uuid => $domain }, pool => $pool }, 'ManageAdapter');
my $images = bless({}, 'ManageImages');
my $manager = Cloudmin::VMManage->new(jobs => $jobs, images => $images,
	adapter => sub { $adapter });
$manager->{'test_audit'} = \@audit;
return ($manager, $adapter, $jobs, $domain, $images);
}

# request(manager, action, fields, [id]) validates and journals one operation.
sub request
{
my ($m, $action, $fields, $id) = @_;
$id ||= sprintf('%032x', ++$serial);
my $revision = $m->settings($uuid)->{'revision'};
my $plan = $m->prepare($action, { id => $uuid, revision => $revision,
	%$fields }, $id);
$m->{'jobs'}->submit($id, 'owner', 'guest:'.$uuid, $plan);
return $id;
}

my ($m, $a, $jobs, $d, $images) = fixture();
my $settings = $m->settings($uuid);
is($settings->{'memory_mib'}, 512, 'saved memory uses explicit XML units');
is($settings->{'max_cpus'}, 8, 'editor receives the host CPU limit');
unlike(JSON::PP->new()->encode($settings), qr/fixture-private|<domain/,
	'public settings omit XML and console password');
# Snapshot overlays retain the system role, and restored seeds remain setup media.
{
	local $d->{'xml'} = $d->{'xml'};
	my $creation = 'a'x32;
	$d->{'xml'} =~ s{<devices>}{<metadata><cloudmin:vm xmlns:cloudmin="urn:cloudmin:vm:1"><cloudmin:job>$creation</cloudmin:job></cloudmin:vm></metadata><devices>};
	$d->{'xml'} =~ s{<target dev="vda"}{<backingStore type="file"><source file="/fixture/cloudmin-fixture-system-$creation.qcow2"/></backingStore><target dev="vda"};
	$d->{'xml'} =~ s{</devices>}{<disk type="file" device="disk"><source file="/fixture/cloudmin-fixture-seed-$creation.1791549256"/><target dev="vdb"/><readonly/></disk></devices>};
	my $disks = $m->settings($uuid)->{'disks'};
	is($disks->[0]->{'role'}, 'system', 'backing chain identifies the system disk');
	is($disks->[1]->{'role'}, 'seed', 'timestamped read-only seed keeps its role');
}
for my $case (
	['update', { cpus => 0, memory_mib => 512 }, qr/whole CPU count from 1 to 8/],
	['update', { cpus => 9, memory_mib => 512 }, qr/whole CPU count from 1 to 8/],
	['update', { cpus => 2, memory_mib => 1 }, qr/whole MiB/],
	['update', { cpus => 2, memory_mib => 512, boot => 'disk:missing' }, qr/boot device/],
	['delete', { confirm_name => 'another' }, qr/confirm deletion/],
	['delete', { confirm_name => 'fixture', shutdown => 'yes' }, qr/Invalid shutdown option/],
	['delete_disk', { target => 'missing' }, qr/no longer attached/],
	['delete', { confirm_name => 'fixture', disks => ['missing'] }, qr/no longer attached/],
	['detach_disk', { target => "vda']|//*" }, qr/no longer attached/],
	['grow_disk', { target => 'vda', disk_gib => 0.5 }, qr/larger/],
	['attach_disk', { pool => 'pool', volume => 'root.qcow2' }, qr/used by/],
	['add_interface', { network => 'network:nat', mac => 'ff:ff:ff:ff:ff:ff' }, qr/unicast/],
	['add_interface', { network => 'network:nat', mac => '52:54:00:11:22:33' }, qr/already in use/],
	['add_interface', { network => 'missing' }, qr/active network/],
) {
	ok(!eval { request($m, $case->[0], $case->[1]); 1 }, 'invalid management request rejected');
	like($@, $case->[2], 'validation explains refusal');
	}
for my $state (qw(active saved snapshot checkpoint)) {
	local $d->{$state} = 1;
	if ($state eq 'active' || $state eq 'saved') {
		# Whole-VM deletion accepts history but still
		# needs explicit stop permission.
		ok(!eval { request($m, 'delete', { confirm_name => 'fixture' }); 1 },
			"$state guest protected");
		}
	ok(!eval { request($m, 'delete_disk', { target => 'vda' }); 1 },
		"$state guest protected from disk deletion");
	}
ok(!eval { $m->prepare('update', { id => $uuid, revision => 'stale' }, 'a'x32); 1 },
	'stale form rejected');

# Editing saves one complete definition and retains unrelated secure fields.
my $id = request($m, 'update', { cpus => 2, memory_mib => 1024,
	description => '<guest & details>', boot => 'nic:52:54:00:11:22:33', bootmenu => 1 });
ok($m->run($id), 'settings job succeeds');
is($jobs->get($id)->{'state'}, 'complete', 'settings committed');
my $doc = Cloudmin::Libvirt::parse_xml_document($d->{'xml'});
is($doc->findvalue('/domain/vcpu'), 2, 'CPU count changed');
is($doc->findvalue('/domain/currentMemory'), 1024, 'current memory changed with maximum');
is($doc->findvalue('/domain/devices/graphics/@passwd'), 'fixture-private', 'console password preserved');
is($doc->findvalue('/domain/description'), '<guest & details>', 'description XML escaped');
is($doc->findvalue('/domain/devices/interface/boot/@order'), 1, 'NIC boot order saved');
ok(!$doc->findnodes('/domain/os/boot'), 'conflicting OS boot order removed');

# The completion entry owns the call and the safe before/after settings.
is_deeply($m->{'test_audit'}->[0]->{'details'}, [],
	'submission does not claim any libvirt operation has run');
my $details = $m->{'test_audit'}->[-1]->{'details'};
is(scalar(@$details), 1, 'settings completion has one definition call');
like($details->[0], qr/^libvirt API: Sys::Virt::define_domain\n/,
	'completion records the real API method');
my (undef, $json_details) = split(/\n/, $details->[0], 2);
my $logged = JSON::PP->new()->decode($json_details);
is_deeply($logged->{'changes'}->{'cpus'}, { before => 1, after => 2 },
	'CPU values are recorded before and after');
is_deeply($logged->{'changes'}->{'memory_mib'}, { before => 512, after => 1024 },
	'memory values have consistent units');
is_deeply($logged->{'changes'}->{'description'},
	{ before => '', after => '<guest & details>' }, 'description remains plain data');
ok($logged->{'changes'}->{'boot'} && $logged->{'changes'}->{'bootmenu'},
	'boot order and menu changes are included');
ok(!exists($logged->{'changes'}->{'disks'}), 'unchanged disks are omitted');
unlike($details->[0], qr/fixture-private|<domain|graphics|passwd/,
	'private XML and console credentials never enter additional logging');

# A lost define reply is reconciled through the private operation marker.
$id = request($m, 'update', { cpus => 3, memory_mib => 1024 });
$a->{'lost_reply'} = 1;
ok(!$m->run($id), 'lost reply records failed operation');
is($m->{'test_audit'}->[-1]->{'action'}, 'manage_failed',
	'failed API call is attached to a failure entry');
like(join('', @{$m->{'test_audit'}->[-1]->{'details'}}),
	qr/Sys::Virt::define_domain/, 'failure retains the attempted definition call');
ok($jobs->get($id)->{'cleanup_pending'}, 'uncertain change remains recoverable');
ok(!eval { $jobs->assert_guest_available($uuid); 1 }, 'unfinished change blocks power actions');
my $defines = $a->{'defines'};
delete($a->{'lost_reply'});
$jobs->update($id, sub { $_[0]->{'state'} = 'recovering'; });
ok($m->run($id), 'recovery recognizes completed definition');
is($a->{'defines'}, $defines, 'recovery does not redefine twice');

# Disk growth is exclusive, irreversible, and replayed by target capacity.
$id = request($m, 'grow_disk', { target => 'vda', disk_gib => 2 });
ok($m->run($id), 'disk growth succeeds');
is($a->{'pool'}->{'volumes'}->{'root.qcow2'}->{'capacity'}, 2*1024**3, 'grew to total requested capacity');
$jobs->update($id, sub { $_[0]->{'state'} = 'recovering'; });
ok($m->run($id), 'growth replay succeeds');
is($a->{'pool'}->{'volumes'}->{'root.qcow2'}->{'resized'}, 1, 'growth performed once');

# Attach and detach preserve data; new disks receive a journalled identity.
$id = request($m, 'attach_disk', { pool => 'pool', volume => 'extra.qcow2' });
ok($m->run($id), 'existing disk attached');
$id = request($m, 'detach_disk', { target => 'vdb' });
ok($m->run($id), 'extra disk detached');
ok($a->{'pool'}->{'volumes'}->{'extra.qcow2'}, 'detachment kept volume');
$id = request($m, 'add_disk', { pool => 'pool', disk_gib => 3 });
ok($m->run($id), 'blank disk created and attached');
my ($created) = values %{$jobs->get($id)->{'resources'}->{'new_volumes'}};
is($created->{'capacity'}, 3*1024**3, 'new disk recorded');

# New names identify the VM without changing existing root or detached files.
like($created->{'name'}, qr/^cloudmin-fixture-data-[a-f0-9]{32}\.qcow2$/,
	'new disk name includes the VM name and stable job ID');
ok($a->{'pool'}->{'volumes'}->{'root.qcow2'}, 'existing disk retains its name');

# Clones preserve their original image and revalidate queued source identity.
{
	my ($m, $a, $jobs, $d, $images) = fixture();
	my $original = $a->{'pool'}->{'volumes'}->{'extra.qcow2'};
	$images->{'images'} = [{ id => 'a'x32, state => 'ready', name => 'Original image',
		pool => 'pool', volume => 'extra.qcow2', volume_key => $original->get_key() }];
	my $settings = $m->settings($uuid);
	is(scalar(@{$settings->{'attachable_volumes'}}), 0, 'attached disks and original images are absent from Attach');
	is($settings->{'images'}->[0]->{'name'}, 'Original image', 'completed import is a clone choice');
	my $id = request($m, 'add_disk', { pool => 'pool', image => 'a'x32 });
	ok($m->run($id), 'imported image cloned and attached through the management job');
	my ($copy) = values %{$jobs->get($id)->{'resources'}->{'new_volumes'}};
	is($copy->{'capacity'}, $original->{'capacity'}, 'clone defaults to source capacity');
	is($a->{'pool'}->{'volumes'}->{$copy->{'name'}}->{'copied_from'}, $original->get_key(), 'libvirt clone uses the selected source');
	is($original->{'capacity'}, 1024**3, 'original image capacity stays unchanged');
	ok($images->{'locked'}, 'copy holds the existing image-store lock');
	unlike($d->{'xml'}, qr{source file="/fixture/extra.qcow2"}, 'domain attaches the independent copy');
	ok(!eval { request($m, 'add_disk', { pool => 'pool', image => 'a'x32, disk_gib => 0.5 }); 1 }, 'clone cannot shrink the source');
	my $larger = request($m, 'add_disk', { pool => 'pool', image => 'a'x32, disk_gib => 2 });
	ok($m->run($larger), 'clone can grow independently through libvirt');
	my ($grown) = values %{$jobs->get($larger)->{'resources'}->{'new_volumes'}};
	is($a->{'pool'}->{'volumes'}->{$grown->{'name'}}->{'capacity'}, 2*1024**3, 'clone reaches requested capacity');
	is($original->{'capacity'}, 1024**3, 'clone growth leaves original capacity alone');
	my $count = scalar(keys %{$a->{'pool'}->{'volumes'}});
	$jobs->update($larger, sub { $_[0]->{'state'} = 'recovering'; });
	ok($m->run($larger), 'completed clone replays without copying again');
	is(scalar(keys %{$a->{'pool'}->{'volumes'}}), $count, 'clone retry creates no duplicate');
	$a->{'fail_define'} = 1;
	my $failed = request($m, 'add_disk', { pool => 'pool', image => 'a'x32 });
	ok(!$m->run($failed), 'failed clone attachment is reported');
	is(scalar(keys %{$a->{'pool'}->{'volumes'}}), $count, 'failed attachment removes only its copy');
	ok(!$jobs->get($failed)->{'cleanup_pending'}, 'completed clone rollback releases VM');
	delete($a->{'fail_define'});
	my $next = request($m, 'add_disk', { pool => 'pool', image => 'a'x32, disk_gib => 2 });
	$original->{'capacity'} *= 2;
	ok(!$m->run($next), 'changed source capacity refuses a queued clone');
	like($jobs->get($next)->{'error'}, qr/Source image changed/, 'source-change error is specific');
	$images->{'images'}->[0]->{'state'} = 'failed';
	is(scalar(@{$m->settings($uuid)->{'images'}}), 0, 'failed import is not offered for cloning');
}

# snapshot_fixture() supplies two disk chains and a branch discarded by restore.
sub snapshot_fixture
{
my ($m, $a, $jobs, $d, $images) = fixture();
my $pool = $a->{'pool'};
foreach my $name (qw(base.qcow2 branch.qcow2 data-base.qcow2)) {
	$pool->{'volumes'}->{$name} = bless({ name => $name, capacity => 1024**3,
		pool => $pool }, 'ManageVolume');
	}
$pool->{'volumes'}->{$_}->{'backing'} = '/fixture/base.qcow2' foreach qw(root.qcow2 branch.qcow2);
$pool->{'volumes'}->{'extra.qcow2'}->{'backing'} = '/fixture/data-base.qcow2';
# Saved history references an abandoned vda branch as well as both base disks.
$d->{'xml'} =~ s{</devices>}{<disk type="file" device="disk"><source file="/fixture/extra.qcow2"/><target dev="vdb"/></disk></devices>};
$d->{'snapshots'} = [bless({xml => '<domainsnapshot><name>point</name><domain><devices>'.
	'<disk><source file="/fixture/base.qcow2"/><target dev="vda"/></disk>'.
	'<disk><source file="/fixture/data-base.qcow2"/><target dev="vdb"/></disk>'.
	'</devices></domain><disks><disk name="vda" snapshot="external">'.
	'<source file="/fixture/branch.qcow2"/></disk></disks></domainsnapshot>'}, 'ManageSnapshot')];
return ($m, $a, $jobs, $d, $images);
}

# VM deletion owns the selected disk's whole private history, not just its top.
for my $targets ([], ['vda'], ['vda', 'vdb']) {
	my ($m, $a, $jobs, $d) = snapshot_fixture();
	my $id = request($m, 'delete', { confirm_name => 'fixture', disks => $targets });
	my @names = map { $_->{'name'} } @{$jobs->get($id)->{'request'}->{'volumes'}};
	if (@$targets) {
		# Every selected overlay must be removed
		# before its shared chain base.
		my %position; @position{@names} = (0..$#names);
		ok($position{'base.qcow2'} > $position{'root.qcow2'} &&
			$position{'base.qcow2'} > $position{'branch.qcow2'}, 'working and branch layers precede their base');
		}
	ok($m->run($id), 'VM deletion accepts snapshot history');
	ok(!$a->find_domain($uuid), 'snapshot VM is undefined');
	my @kept = sort keys %{$a->{'pool'}->{'volumes'}};
	is_deeply(\@kept, @$targets == 2 ? [] : @$targets ? ['data-base.qcow2', 'extra.qcow2'] :
		[qw(base.qcow2 branch.qcow2 data-base.qcow2 extra.qcow2 root.qcow2)],
		'only selected disk chains are removed');
	}

# Shared and imported bases survive while private selected overlays are removed.
for my $protected (qw(shared imported kept)) {
	my ($m, $a, $jobs, $d, $images) = snapshot_fixture();
	my $pool = $a->{'pool'};
	if ($protected eq 'shared') {
		# Another managed volume outside this VM
		# depends on the selected base.
		$pool->{'volumes'}->{'foreign.qcow2'} = bless({name => 'foreign.qcow2',
			capacity => 1024**3, pool => $pool, backing => '/fixture/base.qcow2'}, 'ManageVolume');
		}
	elsif ($protected eq 'imported') {
		# Image Manager ownership protects the base
		# even without a guest user.
		$images->{'images'} = [{pool => 'pool', volume => 'base.qcow2', volume_key => '/fixture/base.qcow2'}];
		}
	else {
		# An unchecked disk in this same VM also
		# protects its shared base.
		$pool->{'volumes'}->{'extra.qcow2'}->{'backing'} = '/fixture/base.qcow2';
		}
	my $id = request($m, 'delete', {confirm_name => 'fixture', disks => ['vda']});
	ok($m->run($id), "$protected base permits removing private overlays");
	ok($pool->{'volumes'}->{'base.qcow2'}, "$protected base survives");
	ok(!$pool->{'volumes'}->{'root.qcow2'} && !$pool->{'volumes'}->{'branch.qcow2'}, 'private history is removed');
	}

# A failure after some layers were removed can resume from the frozen plan.
{
	my ($m, $a, $jobs, $d) = snapshot_fixture();
	my $id = request($m, 'delete', {confirm_name => 'fixture', disks => ['vda']});
	$a->{'pool'}->{'volumes'}->{'base.qcow2'}->{'fail'} = 1;
	ok(!$m->run($id), 'partial snapshot-chain deletion reports failure');
	ok(!$a->find_domain($uuid) && $jobs->get($id)->{'cleanup_pending'}, 'remaining layers retain recovery authority');
	ok(!$a->{'pool'}->{'volumes'}->{'root.qcow2'}, 'top layer already removed');
	delete($a->{'pool'}->{'volumes'}->{'base.qcow2'}->{'fail'});
	$jobs->update($id, sub { $_[0]->{'state'} = 'recovering'; });
	ok($m->run($id), 'snapshot-chain cleanup resumes after undefine');
	is_deeply([sort keys %{$a->{'pool'}->{'volumes'}}], ['data-base.qcow2', 'extra.qcow2'], 'recovery preserves the unchecked chain');
	}

# New history or a new live dependency must be rejected before power changes.
for my $change (qw(history live native_job block_job)) {
	my ($m, $a, $jobs, $d) = snapshot_fixture();
	$d->{'active'} = 1;
	my $id = request($m, 'delete', {confirm_name => 'fixture', shutdown => 1, disks => ['vda']});
	if ($change eq 'history') {
		# A snapshot edit invalidates the
		# confirmation's history revision.
		$d->{'snapshots'}->[0]->{'xml'} =~ s{</domainsnapshot>}{<description>changed</description></domainsnapshot>};
		}
	elsif ($change eq 'live') {
		# A new live-only disk introduces a
		# dependency absent from saved XML.
		$d->{'live_xml'} = $d->{'xml'};
		$d->{'live_xml'} =~ s{</devices>}{<disk><source file="/fixture/base.qcow2"/><target dev="vdc"/></disk></devices>};
		}
	else {
		# Simulate a native domain or block job
		# beginning after submission.
		$d->{$change} = 1;
		}
	ok(!$m->run($id), "$change blocks stale deletion");
	ok(!$d->{'shutdowns'} && !$d->{'destroys'}, 'preflight failure leaves power alone');
	ok($a->find_domain($uuid) && $a->{'pool'}->{'volumes'}->{'root.qcow2'}, 'VM and selected disk survive');
	}

# Form revisions and unfinished merges are checked without blocking read-only UI.
{
	my ($m, $a, $jobs, $d) = snapshot_fixture();
	my $settings = $m->settings($uuid);
	$d->{'checkpoint'} = 1;
	ok(!eval { request($m, 'delete', {confirm_name => 'fixture',
		history_revision => $settings->{'history_revision'}}); 1 }, 'stale history from the deletion form is refused');
	like($@, qr/history changed/, 'stale history error asks for a fresh form');
	$d->{'snapshots'}->[0]->{'xml'} =~ s{</domainsnapshot>}{<snapshotDeleteInProgress/></domainsnapshot>};
	ok($m->settings($uuid), 'interrupted history remains visible in the editor');
	ok(!eval { request($m, 'delete', {confirm_name => 'fixture'}); 1 }, 'an interrupted native merge blocks deletion');
	# Once the merge marker clears, completed
	# history can be removed with the VM.
	$d->{'snapshots'}->[0]->{'xml'} =~ s{<snapshotDeleteInProgress/>}{};
	my $id = request($m, 'delete', {confirm_name => 'fixture'});
	ok($m->run($id), 'completed snapshot and checkpoint history permits VM deletion');
	}

# Failed inventories must remain errors, not an apparently empty disk picker.
{
	my ($m, $a) = fixture();
	is_deeply([map { $_->{'name'} } @{$m->settings($uuid)->{'attachable_volumes'}}],
		['extra.qcow2'], 'only unused volumes are offered');
	$a->{'pool'}->{'volumes'}->{'root.qcow2'}->{'backing'} = '/fixture/extra.qcow2';
	is(scalar(@{$m->settings($uuid)->{'attachable_volumes'}}), 0, 'backing image is not attachable');
	local *ManageAdapter::list_all_domains = sub { die "Inventory failed\n"; };
	ok(!eval { $m->settings($uuid); 1 }, 'inventory failure propagates');
	like($@, qr/Inventory failed/, 'inventory error is retained');
}

# NIC changes preserve the guest MAC and do not edit guest OS configuration.
$id = request($m, 'update_interface', { mac => '52:54:00:11:22:33', network => 'bridge:br-test' });
ok($m->run($id), 'interface moved to bridge');
$id = request($m, 'add_interface', { network => 'network:nat', mac => '52:54:00:44:55:66' });
ok($m->run($id), 'new interface attached');
$id = request($m, 'remove_interface', { mac => '52:54:00:44:55:66' });
ok($m->run($id), 'interface removed');

# ISO detection must not leave the guest's cloud-init media undeletable.
my $seed = $a->{'pool'}->{'volumes'}->{'seed.iso'} = bless({
	name => 'seed.iso', capacity => 65536, format => 'iso', pool => $a->{'pool'} }, 'ManageVolume');
$d->{'xml'} =~ s{</devices>}{<disk type="file" device="disk"><driver type="raw"/><source file="/fixture/seed.iso"/><target dev="vdz" bus="virtio"/><readonly/></disk></devices>};
my $seed_plan = $m->prepare('delete', { id => $uuid,
	revision => $m->settings($uuid)->{'revision'}, confirm_name => 'fixture',
	disks => ['vdz'] }, 'f'x32);
is($seed_plan->{'volumes'}->[0]->{'format'}, 'iso', 'ISO seed can be deleted');
ok(!eval { request($m, 'attach_disk', { pool => 'pool', volume => 'seed.iso' }); 1 },
	'ISO seed is not offered as a writable attachment');

# Shared references, including backing chains and imported images, block deletes.
my $other = bless({ uuid => 'other', xml => $xml }, 'ManageDomain');
$a->{'domains'}->{'other'} = $other;
ok(!eval { request($m, 'delete', { confirm_name => 'fixture', disks => ['vda'] }); 1 }, 'shared disk blocks deletion');
like($@, qr/used by/, 'sharing refusal is specific');
delete($a->{'domains'}->{'other'});
$a->{'pool'}->{'volumes'}->{'extra.qcow2'}->{'backing'} = '/fixture/root.qcow2';
ok(!eval { request($m, 'delete', { confirm_name => 'fixture', disks => ['vda'] }); 1 }, 'backing file blocks deletion');
like($@, qr/backing file/, 'backing refusal is specific');
delete($a->{'pool'}->{'volumes'}->{'extra.qcow2'}->{'backing'});
$images->{'images'} = [{ pool => 'pool', volume_key => '/fixture/root.qcow2' }];
ok(!eval { request($m, 'grow_disk', { target => 'vda', disk_gib => 3 }); 1 }, 'imported image cannot grow');
$images->{'images'} = [];

# Deletion can recover after undefine without deleting a retained disk.
$id = request($m, 'delete', { confirm_name => 'fixture', disks => ['vda'] });
$a->{'pool'}->{'volumes'}->{'root.qcow2'}->{'fail'} = 1;
ok(!$m->run($id), 'partial deletion reports failure');
ok(!$a->find_domain($uuid), 'guest undefined before disk deletion');
ok($jobs->get($id)->{'cleanup_pending'}, 'remaining disk cleanup recorded');
delete($a->{'pool'}->{'volumes'}->{'root.qcow2'}->{'fail'});
$jobs->update($id, sub { $_[0]->{'state'} = 'recovering'; });
ok($m->run($id), 'disk cleanup resumes after guest is gone');
ok(!$a->{'pool'}->{'volumes'}->{'root.qcow2'}, 'selected disk removed');
ok($a->{'pool'}->{'volumes'}->{'extra.qcow2'}, 'unselected disk kept');
ok($a->{'keys_removed'}, 'managed key cleanup called');
is($jobs->get($id)->{'state'}, 'complete', 'recovered deletion completed');

# Rechecking immediately before mutation rejects a VM started after submission.
($m, $a, $jobs, $d) = fixture();
$id = request($m, 'delete', { confirm_name => 'fixture' });
$d->{'active'} = 1;
ok(!$m->run($id), 'late VM start blocks deletion');
ok($a->find_domain($uuid), 'running guest remains defined');
ok(!$jobs->get($id)->{'cleanup_pending'}, 'preflight refusal needs no cleanup');

# Confirmed deletion can stop a running guest, including a late start.
for my $active (0, 1) {
	my ($m, $a, $jobs, $d) = fixture();
	$d->{'active'} = $active;
	$d->{'xml'} =~ s{</devices>}{<disk type="file" device="disk"><source file="/fixture/extra.qcow2"/><target dev="vdb"/></disk></devices>};
	my $id = request($m, 'delete', { confirm_name => 'fixture', shutdown => 1, disks => ['vda'] });
	$d->{'active'} = 1;
	ok($m->run($id), 'confirmed deletion shuts down a guest active at execution');
	is($d->{'shutdowns'}, 1, 'one clean shutdown is requested');
	ok(!$a->find_domain($uuid), 'stopped guest is undefined');
	ok(!$a->{'pool'}->{'volumes'}->{'root.qcow2'}, 'selected disk is removed');
	ok($a->{'pool'}->{'volumes'}->{'extra.qcow2'}, 'unselected disk survives');
	is_deeply([map { [@$_{qw(step state)}] } @{$jobs->get($id)->{'events'}}],
		[['delete_shutdown', 'done'], ['manage', 'done']], 'shutdown and deletion are journalled');
	is($m->{'test_audit'}->[-1]->{'action'}, 'delete', 'normal deletion audit is retained');
	}

# Shutdown failures leave both the guest definition and its disks available.
for my $failure (qw(timeout refused unclean paused)) {
	my ($m, $a, $jobs, $d) = fixture();
	$d->{'active'} = 1;
	$d->{'xml'} =~ s{</devices>}{<disk type="file" device="disk"><source file="/fixture/extra.qcow2"/><target dev="vdb"/></disk></devices>};
	$d->{'shutdown_stuck'} = 1 if ($failure eq 'timeout');
	$d->{'shutdown_refused'} = 1 if ($failure eq 'refused');
	$d->{'reason'} = 2 if ($failure eq 'unclean');
	$d->{'state'} = 3 if ($failure eq 'paused');
	$m->{'shutdown_timeout'} = 0;
	my $id = request($m, 'delete', { confirm_name => 'fixture', shutdown => 1, disks => ['vda'] });
	ok(!$m->run($id), "$failure shutdown prevents deletion");
	ok($a->find_domain($uuid), 'definition remains');
	is(scalar(keys %{$a->{'pool'}->{'volumes'}}), 2, 'all disks remain');
	ok(!$jobs->get($id)->{'cleanup_pending'}, 'no destructive work needs recovery');
	ok(eval { $jobs->assert_guest_available($uuid); 1 }, 'failed shutdown permits manual power controls');
	}

# A definition changed while queued must be refused before any power action.
{
	my ($m, $a, $jobs, $d) = fixture();
	$d->{'active'} = 1;
	my $id = request($m, 'delete', { confirm_name => 'fixture', shutdown => 1 });
	$d->{'xml'} =~ s{</domain>}{<description>External edit</description></domain>};
	ok(!$m->run($id), 'stale deletion fails before shutdown');
	ok(!$d->{'shutdowns'} && $a->find_domain($uuid), 'stale form leaves running guest alone');
	}

# Revalidate changes made outside Cloudmin during the shutdown wait.
for my $change (qw(definition shared snapshot)) {
	my ($m, $a, $jobs, $d) = fixture();
	$d->{'active'} = 1;
	$d->{'xml'} =~ s{</devices>}{<disk type="file" device="disk"><source file="/fixture/extra.qcow2"/><target dev="vdb"/></disk></devices>};
	my $id = request($m, 'delete', { confirm_name => 'fixture', shutdown => 1, disks => ['vda'] });
	$d->{'on_shutdown'} = sub {
		# Inject one external change after the stop
		# request but before deletion.
		$d->{'xml'} =~ s{</domain>}{<description>External edit</description></domain>}
			if ($change eq 'definition');
		$a->{'domains'}->{'other'} = bless({ uuid => 'other', xml => $xml }, 'ManageDomain')
			if ($change eq 'shared');
		$d->{'snapshot'} = 1 if ($change eq 'snapshot');
		};
	ok(!$m->run($id), "$change change during shutdown prevents deletion");
	ok($a->find_domain($uuid) && $a->{'pool'}->{'volumes'}->{'root.qcow2'}, 'definition and selected disk survive');
	ok(!$jobs->get($id)->{'cleanup_pending'}, 'pre-deletion refusal releases the reservation');
	}

# Recovery retains the original shutdown deadline and does not request it twice.
{
	my ($m, $a, $jobs, $d) = fixture();
	$d->{'active'} = 1;
	my $id = request($m, 'delete', { confirm_name => 'fixture', shutdown => 1 });
	my $deadline = time() - 1;
	$jobs->update($id, sub { $_[0]->{'resources'} = { started => 1, shutdown_deadline => $deadline }; });
	ok(!$m->run($id), 'recovered shutdown observes its expired deadline');
	is($jobs->get($id)->{'resources'}->{'shutdown_deadline'}, $deadline, 'recovery never extends the wait');
	ok(!$d->{'shutdowns'} && $a->find_domain($uuid), 'recovery neither repeats shutdown nor deletes a running guest');
	}

# Once undefine starts, normal partial-deletion recovery must still apply.
{
	my ($m, $a, $jobs, $d) = fixture();
	$d->{'active'} = 1;
	my $id = request($m, 'delete', { confirm_name => 'fixture', shutdown => 1, disks => ['vda'] });
	my $volume = $a->{'pool'}->{'volumes'}->{'root.qcow2'};
	$volume->{'fail'} = 1;
	ok(!$m->run($id), 'disk deletion failure after shutdown is reported');
	ok($jobs->get($id)->{'cleanup_pending'}, 'remaining disk deletion requires recovery');
	delete($volume->{'fail'});
	$jobs->update($id, sub { $_[0]->{'state'} = 'recovering'; });
	ok($m->run($id), 'recovery finishes deletion after undefine');
	is($d->{'destroys'}, 1, 'recovery does not repeat power-off');
	ok(!$a->{'pool'}->{'volumes'}->{'root.qcow2'}, 'recovered deletion removes selected disk');
	}

# Cancellation remains possible until the shutdown request begins.
{
	my ($m, $a, $jobs, $d) = fixture();
	$d->{'active'} = 1;
	my $id = request($m, 'delete', { confirm_name => 'fixture', shutdown => 1 });
	my $update = \&Cloudmin::Jobs::update;
	local *Cloudmin::Jobs::update = sub {
		my ($store, $job, $callback) = @_;
		# Make cancellation visible inside the
		# transaction that starts the job.
		return $update->($store, $job, sub { $_[0]->{'cancel'} = 1; $callback->(@_); });
		};
	$m->run($id);
	is($jobs->get($id)->{'state'}, 'cancelled', 'cancellation wins before shutdown');
	ok(!$d->{'shutdowns'} && $a->find_domain($uuid), 'cancelled deletion leaves the guest alone');
	}

# Keeping read-only media does not require a clean shutdown of discarded disks.
for my $state (1, 3) {
	my ($m, $a, $jobs, $d) = fixture();
	$d->{'active'} = 1;
	$d->{'state'} = $state;
	$d->{'xml'} =~ s{</devices>}{<disk type="file" device="disk"><source file="/fixture/extra.qcow2"/><target dev="vdb"/><readonly/></disk></devices>};
	my $id = request($m, 'delete', { confirm_name => 'fixture', shutdown => 1, disks => ['vda'] });
	ok($m->run($id), 'discarded writable disks allow immediate power-off, including paused guests');
	is($d->{'destroys'}, 1, 'guest is powered off once');
	ok(!$d->{'shutdowns'}, 'no clean shutdown is requested');
	ok(!$a->find_domain($uuid) && !$a->{'pool'}->{'volumes'}->{'root.qcow2'}, 'VM and selected disk are deleted');
	ok($a->{'pool'}->{'volumes'}->{'extra.qcow2'}, 'read-only media is kept');
	is($jobs->get($id)->{'events'}->[0]->{'step'}, 'delete_power_off', 'job records the actual power action');
	}

# Live-only or unmanaged writable storage must never be treated as discarded.
for my $source ('<source file="/fixture/extra.qcow2"/>', '<source dev="/dev/external"/>') {
	my ($m, $a, $jobs, $d) = fixture();
	$d->{'active'} = 1;
	$d->{'live_xml'} = $d->{'xml'};
	$d->{'live_xml'} =~ s{</devices>}{<disk type="file" device="disk">$source<target dev="vdb"/></disk></devices>};
	ok($m->settings($uuid)->{'delete_force_blocked'}, 'preview accounts for retained live-only storage');
	my $id = request($m, 'delete', { confirm_name => 'fixture', shutdown => 1, disks => ['vda'] });
	ok($m->run($id), 'retained live-only storage gets a clean shutdown');
	is($d->{'shutdowns'}, 1, 'clean shutdown used for a retained writable source');
	ok(!$d->{'destroys'}, 'retained writable storage is never forcibly stopped');
	}

# A refused power-off leaves the VM and every disk intact and permits a retry.
{
	my ($m, $a, $jobs, $d) = fixture();
	$d->{'active'} = 1;
	$d->{'destroy_refused'} = 1;
	my $id = request($m, 'delete', { confirm_name => 'fixture', shutdown => 1, disks => ['vda'] });
	ok(!$m->run($id), 'power-off failure blocks deletion');
	ok($a->find_domain($uuid) && $a->{'pool'}->{'volumes'}->{'root.qcow2'}, 'definition and disks survive refused power-off');
	ok(!$jobs->get($id)->{'cleanup_pending'}, 'refused power-off needs no storage recovery');
	}

# A rejected atomic definition releases the VM and rolls back only new disks.
($m, $a, $jobs, $d) = fixture();
$id = request($m, 'update', { cpus => 2, memory_mib => 512 });
$a->{'fail_define'} = 1;
ok(!$m->run($id), 'libvirt definition refusal recorded');
ok(!$jobs->get($id)->{'cleanup_pending'}, 'unchanged guest needs no recovery');
ok(eval { $jobs->assert_guest_available($uuid); 1 }, 'refused edit does not block power');
$id = request($m, 'add_disk', { pool => 'pool', disk_gib => 2 });
ok(!$m->run($id), 'failed disk attachment recorded');
is(scalar(keys %{$a->{'pool'}->{'volumes'}}), 2, 'failed attachment removes its new volume');
ok(!$jobs->get($id)->{'cleanup_pending'}, 'cleaned failed attachment releases VM');

# A queued change can be cancelled without allocating storage or changing XML.
($m, $a, $jobs, $d) = fixture();
$id = request($m, 'add_disk', { pool => 'pool', disk_gib => 2 });
$jobs->update($id, sub { $_[0]->{'cancel'} = 1; });
ok($m->run($id), 'cancelled job exits normally');
is($jobs->get($id)->{'state'}, 'cancelled', 'queued cancellation committed');
is(scalar(keys %{$a->{'pool'}->{'volumes'}}), 2, 'cancelled job allocated no volume');

# A shared UEFI variable store must survive attempted deletion.
($m, $a, $jobs, $d) = fixture();
$d->{'xml'} =~ s{</os>}{<nvram>/fixture/shared-vars.fd</nvram></os>};
$a->{'domains'}->{'other'} = bless({ uuid => 'other', xml => $d->{'xml'} }, 'ManageDomain');
ok(!eval { request($m, 'delete', { confirm_name => 'fixture' }); 1 },
	'shared NVRAM protected');
like($@, qr/UEFI variables are shared/, 'NVRAM refusal explains sharing');

# A replaced file at the same pool key must never inherit deletion authority.
($m, $a, $jobs, $d) = fixture();
$id = request($m, 'delete', { confirm_name => 'fixture', disks => ['vda'] });
{
	local *Cloudmin::VMManage::file_identity = sub { return 'replacement'; };
	ok(!$m->run($id), 'replacement disk refused at execution');
	like($jobs->get($id)->{'error'}, qr/storage volume was replaced/, 'replacement error retained');
	ok($a->find_domain($uuid), 'replacement refusal precedes undefine');
	}

# One Save validates all tabs and defines the resulting hardware only once.
($m, $a, $jobs, $d, $images) = fixture();
my $combined = { cpus => 3, memory_mib => 1024, changes => [
	{ action => 'grow_disk', target => 'vda', disk_gib => 2 },
	{ action => 'attach_disk', pool => 'pool', volume => 'extra.qcow2' },
	{ action => 'add_disk', pool => 'pool', disk_gib => 3 },
	{ action => 'update_interface', mac => '52:54:00:11:22:33',
	  network => 'bridge:br-test' },
	{ action => 'add_interface', network => 'network:nat' },
	] };
my $before = $d->{'xml'};
ok(!eval { request($m, 'update', { %$combined, cpus => 0 }); 1 },
	'invalid resources reject otherwise valid hardware edits');
is($d->{'xml'}, $before, 'validation leaves the saved definition intact');
is($a->{'pool'}->{'volumes'}->{'root.qcow2'}->{'capacity'}, 1024**3,
	'validation never grows disks');
is(scalar(keys %{$a->{'pool'}->{'volumes'}}), 2, 'validation allocates nothing');
$id = request($m, 'update', $combined);
ok($m->run($id), 'combined resource, disk and network update succeeds');
is($a->{'defines'}, 1, 'one final domain definition applies all tabs');
$settings = $m->settings($uuid);
is($settings->{'cpus'}, 3, 'combined CPU edit saved');
is(scalar(@{$settings->{'disks'}}), 3, 'existing and new disks both attached');
is(scalar(@{$settings->{'interfaces'}}), 2, 'new interface added');
is($settings->{'interfaces'}->[0]->{'source'}, 'br-test', 'existing NIC changed');
is($a->{'pool'}->{'volumes'}->{'root.qcow2'}->{'capacity'}, 2*1024**3,
	'combined disk growth applied');
my $combined_details = join("\n", @{$m->{'test_audit'}->[-1]->{'details'}});
like($combined_details, qr/Sys::Virt::StorageVol::resize.*"before_bytes"/s,
	'disk growth logs its original and requested capacities');
like($combined_details, qr/Sys::Virt::StoragePool::create_volume/,
	'new disks log their allocation');
like($combined_details, qr/"disks".*"interfaces"/s,
	'disk attachments and network changes accompany the definition call');

# Removing hardware and selecting a now-removed boot device cannot partly save.
ok(!eval { request($m, 'update', { cpus => 3, memory_mib => 1024,
	boot => 'disk:vdb', changes => [{ action => 'detach_disk', target => 'vdb' }] }); 1 },
	'boot order is validated against the final hardware');
is(scalar(@{$m->settings($uuid)->{'disks'}}), 3, 'invalid boot choice detaches nothing');
$id = request($m, 'update', { cpus => 3, memory_mib => 1024, changes => [
	{ action => 'detach_disk', target => 'vdb' },
	{ action => 'remove_interface', mac => $settings->{'interfaces'}->[1]->{'mac'} },
	] });
ok($m->run($id), 'detach and interface removal save together');
ok($a->{'pool'}->{'volumes'}->{'extra.qcow2'}, 'batch detachment keeps data');
is(scalar(@{$m->settings($uuid)->{'interfaces'}}), 1, 'selected NIC removed');

# Unchanged shared disks and NIC sources must not block a resource-only save.
($m, $a, $jobs, $d, $images) = fixture();
$images->{'images'} = [{ pool => 'pool', volume_key => '/fixture/root.qcow2' }];
$d->{'xml'} =~ s{<source network="default"/>}{<source network="default" portgroup="kept"/>};
$id = request($m, 'update', { cpus => 2, memory_mib => 512, changes => [
	{ action => 'grow_disk', target => 'vda', disk_gib => 1 },
	{ action => 'update_interface', mac => '52:54:00:11:22:33', network => 'network:nat' },
	] });
ok($m->run($id), 'unchanged hardware is omitted from the operation plan');
like($d->{'xml'}, qr/portgroup="kept"/, 'unchanged NIC keeps its source options');

# Reject conflicting devices and invalid actions before creating a job.
for my $changes (
	[{ action => 'delete' }],
	[{ action => 'delete_disk', target => 'vda' }],
	[{ action => 'grow_disk', target => 'vda', disk_gib => 1 },
	 { action => 'detach_disk', target => 'vda' }],
	[{ action => 'attach_disk', pool => 'pool', volume => 'extra.qcow2' },
	 { action => 'attach_disk', pool => 'pool', volume => 'extra.qcow2' }],
	[{ action => 'add_interface', network => 'network:nat', mac => '52:54:00:aa:bb:cc' },
	 { action => 'add_interface', network => 'network:nat', mac => '52:54:00:aa:bb:cc' }],
	'bad', [undef],
) {
	ok(!eval { request($m, 'update', { cpus => 2, memory_mib => 512,
		changes => $changes }); 1 }, 'invalid hardware batch rejected');
	}

# Different inventory names can still refer to the same disk file.
($m, $a, $jobs, $d) = fixture();
$a->{'pool'}->{'volumes'}->{'alias.qcow2'} = bless({ name => 'alias.qcow2',
	capacity => 1024**3, pool => $a->{'pool'} }, 'ManageVolume');
{
	# Two inventory paths may refer to one inode even with different pool keys.
	local *Cloudmin::VMManage::file_identity = sub {
		return $_[0] =~ /(?:extra|alias)\.qcow2$/ ? 'same-inode' : $_[0];
		};
	ok(!eval { request($m, 'update', { cpus => 2, memory_mib => 512,
		changes => [
			{ action => 'attach_disk', pool => 'pool', volume => 'extra.qcow2' },
			{ action => 'attach_disk', pool => 'pool', volume => 'alias.qcow2' },
		] }); 1 }, 'aliases cannot attach the same file twice in one Save');
	like($@, qr/storage file was selected more than once/, 'alias refusal uses file identity');
	}

# Individual allocations fit, but their sum must fit before any disk is written.
($m, $a, $jobs, $d) = fixture();
$a->{'pool'}->{'available'} = 3*1024**3;
$id = request($m, 'update', { cpus => 2, memory_mib => 512, changes => [
	{ action => 'add_disk', pool => 'pool', disk_gib => 2 },
	{ action => 'add_disk', pool => 'pool', disk_gib => 2 },
	] });
ok(!$m->run($id), 'aggregate pool demand is checked');
is(scalar(keys %{$a->{'pool'}->{'volumes'}}), 2, 'space refusal allocates nothing');
ok(!$jobs->get($id)->{'cleanup_pending'}, 'preflight failure needs no recovery');

# A resize cannot be rolled back; recovery must finish the remaining definition.
($m, $a, $jobs, $d) = fixture();
$id = request($m, 'update', $combined);
$a->{'fail_define'} = 1;
ok(!$m->run($id), 'failed definition after growth records a partial change');
ok($jobs->get($id)->{'cleanup_pending'}, 'partial combined change stays recoverable');
ok(!eval { $jobs->assert_guest_available($uuid); 1 }, 'partial change blocks power');
my @allocated = sort keys %{$a->{'pool'}->{'volumes'}};
delete($a->{'fail_define'});
$jobs->update($id, sub { $_[0]->{'state'} = 'recovering'; });
ok($m->run($id), 'combined change resumes');
is_deeply([sort keys %{$a->{'pool'}->{'volumes'}}], \@allocated,
	'recovery reuses the allocated disk');
is($a->{'pool'}->{'volumes'}->{'root.qcow2'}->{'resized'}, 1,
	'recovery does not resize twice');
is($m->settings($uuid)->{'cpus'}, 3, 'recovery applies remaining resource edits');
$jobs->update($id, sub { $_[0]->{'state'} = 'recovering'; });
ok($m->run($id), 'a lost final reply is reconciled by the batch marker');
is($a->{'defines'}, 1, 'completed batch is not applied twice');

# Deleting one disk keeps the VM, other attachments and unrelated storage.
($m, $a, $jobs, $d) = fixture();
$id = request($m, 'attach_disk', { pool => 'pool', volume => 'extra.qcow2' });
ok($m->run($id), 'attach a second disk before deleting the first');
$id = request($m, 'delete_disk', { target => 'vda' });
ok($m->run($id), 'confirmed disk deletion succeeds');
ok($a->find_domain($uuid), 'disk deletion retains the virtual machine');
is_deeply([map { $_->{'target'} } @{$m->settings($uuid)->{'disks'}}], ['vdb'],
	'deletion removes only the selected attachment');
is_deeply([keys %{$a->{'pool'}->{'volumes'}}], ['extra.qcow2'],
	'deletion removes only the selected storage volume');
is($m->{'test_audit'}->[-1]->{'action'}, 'delete_disk', 'disk deletion has its own action');
like(join('', @{$m->{'test_audit'}->[-1]->{'details'}}),
	qr/Sys::Virt::define_domain.*Sys::Virt::StorageVol::delete/s,
	'audit records detaching before deleting');

# Every reference is protected before detachment, including this VM's aliases.
for my $usage (qw(shared backing same_guest imported imported_alias)) {
	($m, $a, $jobs, $d, $images) = fixture();
	# Another guest must retain access to its attached disk.
	if ($usage eq 'shared') {
		$a->{'domains'}->{'other'} = bless({ uuid => 'other', xml => $xml }, 'ManageDomain');
		}
	# A child image still depends on the selected disk.
	elsif ($usage eq 'backing') {
		$a->{'pool'}->{'volumes'}->{'extra.qcow2'}->{'backing'} = '/fixture/root.qcow2';
		}
	# A second attachment in this guest must also protect its data.
	elsif ($usage eq 'same_guest') {
		$d->{'xml'} =~ s{</devices>}{<disk type="file" device="disk"><source file="/fixture/root.qcow2"/><target dev="vdb"/></disk></devices>};
		}
	# Imports remain protected through both direct and aliased paths.
	else {
		my $name = $usage eq 'imported' ? 'root.qcow2' : 'extra.qcow2';
		$images->{'images'} = [{ pool => 'pool', volume => $name, volume_key => '/fixture/'.$name }];
		}
	local *Cloudmin::VMManage::file_identity = sub {
		return $usage eq 'imported_alias' ? 'same-inode' : $_[0];
		};
	ok(!eval { request($m, 'delete_disk', { target => 'vda' }); 1 },
		"$usage disk cannot be deleted");
	ok(!$a->{'defines'} && $a->{'pool'}->{'volumes'}->{'root.qcow2'},
		"$usage refusal preserves definition and data");
	# The editor must identify protected imports as well as refusing deletion.
	if ($usage =~ /^imported/) {
		ok($m->settings($uuid)->{'disks'}->[0]->{'imported'},
			"$usage disk is marked in the editor");
		}
	}

# Refused definitions leave data attached; uncertain replies remain recoverable.
for my $failure (qw(define detach_reply volume delete_reply)) {
	($m, $a, $jobs, $d) = fixture();
	my $volume = $a->{'pool'}->{'volumes'}->{'root.qcow2'};
	$a->{'fail_define'} = 1 if ($failure eq 'define');
	$a->{'lost_reply'} = 1 if ($failure eq 'detach_reply');
	$volume->{'fail'} = 1 if ($failure eq 'volume');
	$volume->{'lost_reply'} = 1 if ($failure eq 'delete_reply');
	$id = request($m, 'delete_disk', { target => 'vda' });
	ok(!$m->run($id), "$failure is recorded as failed");
	# A refused detach leaves both the attachment and its file intact.
	if ($failure eq 'define') {
		ok(!$jobs->get($id)->{'cleanup_pending'}, 'refused definition needs no recovery');
		like($d->{'xml'}, qr/root\.qcow2/, 'refused detach preserves attachment');
		ok($a->{'pool'}->{'volumes'}->{'root.qcow2'}, 'refused detach preserves data');
		next;
		}
	ok($jobs->get($id)->{'cleanup_pending'}, "$failure remains recoverable");
	ok(!eval { $jobs->assert_guest_available($uuid); 1 }, 'unfinished deletion blocks power');
	unlike($d->{'xml'}, qr/root\.qcow2/, 'selected disk was detached before deletion');
	delete($a->{'lost_reply'});
	delete($volume->{'fail'});
	$jobs->update($id, sub { $_[0]->{'state'} = 'recovering'; });
	ok($m->run($id), "$failure recovers successfully");
	is($a->{'defines'}, 1, 'recovery does not redefine the retained VM');
	ok(!$a->{'pool'}->{'volumes'}->{'root.qcow2'}, 'recovery finishes volume deletion');
	ok(!$jobs->get($id)->{'cleanup_pending'}, 'completed deletion releases the VM');
	}

# Recheck queued and partially completed deletions against current ownership.
for my $partial (0, 1) {
	for my $change (qw(shared replaced)) {
		($m, $a, $jobs, $d) = fixture();
		$id = request($m, 'delete_disk', { target => 'vda' });
		# Repeat the ownership check after an interrupted detach, too.
		if ($partial) {
			$a->{'lost_reply'} = 1;
			ok(!$m->run($id), 'simulate interruption after detach');
			delete($a->{'lost_reply'});
			$jobs->update($id, sub { $_[0]->{'state'} = 'recovering'; });
			}
		$a->{'domains'}->{'other'} = bless({ uuid => 'other', xml => $xml }, 'ManageDomain')
			if ($change eq 'shared');
		local *Cloudmin::VMManage::file_identity = sub {
			return $change eq 'replaced' ? 'replacement-inode' : $_[0];
			};
		ok(!$m->run($id), "$change volume rejected on ".($partial ? 'recovery' : 'queued execution'));
		ok($a->{'pool'}->{'volumes'}->{'root.qcow2'}, 'changed volume is not deleted');
		is($a->{'defines'} || 0, $partial, 'refusal does not change the definition');
		}
	}

# Hard links must be detected as shared data, just like symlink aliases.
open(my $disk_file, '>', "$root/disk") || die $!;
print $disk_file 'fixture';
close($disk_file);
link("$root/disk", "$root/alias") || die $!;
ok(Cloudmin::Images::xml_uses_volume(
	'<disk><source file="'.$root.'/alias"/></disk>',
	"$root/disk", 'pool', 'disk'), 'hard-linked disk reference is protected');


# A permanently refused definition has an explicit, non-destructive exit.
{
    my ($m, $a, $jobs, $d) = fixture();
    my $id = request($m, 'update', $combined);
    $a->{fail_define} = 1;
    $m->run($id);
    ok($m->discard_change($id), 'remaining edit can be discarded after a refused definition');
    ok(!$jobs->get($id)->{cleanup_pending}, 'discard releases the guest');
    is($a->{pool}{volumes}{'root.qcow2'}{capacity}, 2*1024**3, 'discard preserves completed growth');
    is(scalar(keys %{$a->{pool}{volumes}}), 2, 'unattached new disks are cleaned up');
    is($d->{xml}, $xml, 'discard leaves the original definition intact');
    ok(eval { $jobs->assert_guest_available($uuid); 1 }, 'power actions can proceed again');
}
{
    my ($m, $a, $jobs, $d) = fixture();
    my $id = request($m, 'update', $combined);
    $a->{fail_define} = 1;
    $m->run($id);
    $d->{xml} =~ s{</domain>}{<description>External edit</description></domain>};
    ok(!eval { $m->discard_change($id); 1 }, 'discard refuses a changed definition');
    ok($jobs->get($id)->{cleanup_pending}, 'uncertain changes keep their reservation');
}
# Missing imports on an unrelated inactive pool do not prevent disk operations.
{
    my ($m, $a, $jobs, $d, $images) = fixture();
    { package InactivePool;
      # get_uuid_string(self) identifies the unrelated inactive pool.
      sub get_uuid_string { 'inactive' }
      # is_active(self) makes the fixture pool unavailable for volume lookup.
      sub is_active { 0 }
      # get_xml_description(self, [flags]) supplies its synthetic directory.
      sub get_xml_description { '<pool type="dir"><target><path>/missing-fixture</path></target></pool>' }
    }
    no warnings 'redefine';
    local *ManageAdapter::list_all_storage_pools = sub { ($_[0]->{pool}, bless({}, 'InactivePool')) };
    my $volume = \&ManageAdapter::volume;
    local *ManageAdapter::volume = sub { die 'Inactive pool queried' if $_[1] eq 'inactive'; $volume->(@_); };
    $images->{images} = [{ pool => 'inactive', volume => 'image.qcow2', volume_key => 'old-image' }];
    my $id = request($m, 'grow_disk', { target => 'vda', disk_gib => 2 });
    ok($m->run($id), 'unrelated inactive imported pool does not block growth');
    ok(!$jobs->get($id)->{cleanup_pending}, 'successful growth is not marked for cleanup');
}

# Partial API updates preserve an omitted description but allow explicit clearing.
{
	my ($m, $a, $jobs, $d) = fixture();
	$d->{xml} =~ s{</domain>}{<description>Retained description</description></domain>};
	my $id = request($m, 'update', {cpus => 2, memory_mib => 1024});
	ok($m->run($id), 'partial update succeeds');
	is(Cloudmin::Libvirt::parse_xml_document($d->{xml})->findvalue('/domain/description'),
		'Retained description', 'omitted description is preserved');
	$id = request($m, 'update', {cpus => 2, memory_mib => 1024, description => ''});
	ok($m->run($id), 'explicit description clearing succeeds');
	is(Cloudmin::Libvirt::parse_xml_document($d->{xml})->findvalue('/domain/description'),
		'', 'explicit empty description is respected');
}
# running_fixture() provides CPU slots and a working balloon in both definitions.
sub running_fixture
{
my @fixture = fixture();
my ($manager, undef, undef, $domain) = @fixture;
$domain->{'xml'} =~ s{<vcpu>1</vcpu>}{<vcpu current="1">4</vcpu>};
$domain->{'xml'} =~ s{</devices>}{<memballoon model="virtio"/></devices>};
$domain->{'live_xml'} = $domain->{'xml'};
$domain->{'active'} = 1;
$manager->{'hotplug_timeout'} = 0;
return @fixture;
}

# Successful live calls update both allocations while preserving their maximums.
{
my ($m, $a, $jobs, $d) = running_fixture();
my $id = request($m, 'update', { cpus => 2, memory_mib => 384 });
ok($m->run($id), 'running resources change without shutdown');
is($jobs->get($id)->{'scope'}, 'live', 'job identifies live execution');
is_deeply($d->{'calls'}, [
	['set_vcpus', Sys::Virt::Domain::VCPU_LIVE() | Sys::Virt::Domain::VCPU_CONFIG()],
	['set_memory', Sys::Virt::Domain::MEM_LIVE() | Sys::Virt::Domain::MEM_CONFIG()]],
	'CPU and memory calls update live and persistent settings');
is($m->settings($uuid)->{'cpus'}, 2, 'settings reports current CPU count');
is($m->settings($uuid)->{'cpu_limit'}, 4, 'CPU ceiling survives the edit');
is($m->settings($uuid)->{'memory_mib'}, 384, 'settings reports balloon target');
is($m->settings($uuid)->{'memory_limit_mib'}, 512, 'memory ceiling survives the edit');
ok(!$a->{'defines'}, 'live edits never redefine the complete domain');
}

# Boot CPUs set the live minimum even when the saved maximum has spare slots.
{
my ($m, $a, $jobs, $d) = running_fixture();
$d->{$_} =~ s/current="1"/current="2"/ foreach qw(xml live_xml);
is($m->settings($uuid)->{'live_limits'}->{'min_cpus'}, 2, 'boot CPUs set the live minimum');
my $id = request($m, 'update', { cpus => 1, memory_mib => 384 });
ok($m->run($id), 'CPU reduction is saved while memory changes live');
is($jobs->get($id)->{'scope'}, 'live', 'mixed changes report live scope');
is_deeply($jobs->get($id)->{'deferred_fields'}, ['cpus'], 'job identifies its deferred CPU change');
is_deeply($d->{'calls'}, [['set_memory', 3]], 'boot CPU removal makes no live CPU call');
is_deeply($m->settings($uuid)->{'pending'}->{'cpus'}, {running => 2, saved => 1}, 'settings expose pending CPU count');
# Later saves must retain or explicitly cancel the deferred allocation.
$id = request($m, 'update', { cpus => 1, memory_mib => 448, description => 'Later edit' });
ok($m->run($id), 'an unrelated save preserves the pending CPU allocation');
is_deeply($m->settings($uuid)->{'pending'}->{'cpus'}, {running => 2, saved => 1}, 'unrelated save does not apply the pending reduction');
$id = request($m, 'update', { cpus => 2, memory_mib => 448 });
ok($m->run($id), 'editing the saved CPU count back cancels its pending change');
ok(!$m->settings($uuid)->{'pending'}->{'cpus'}, 'matching values have no pending note');
# A stop between submission and execution moves the whole request offline.
$id = request($m, 'update', { cpus => 1, memory_mib => 384 });
$d->{'active'} = 0;
ok($m->run($id), 'queued update succeeds after shutdown');
is($jobs->get($id)->{'scope'}, 'config', 'stopped execution records its actual scope');
is_deeply($m->settings($uuid)->{'pending'}, {}, 'stopped guest has no pending running values');
}

# Live CPU entries, not next-boot configuration, identify removable CPUs.
{
my ($m, $a, $jobs, $d) = running_fixture();
$d->{$_} =~ s/current="1"/current="3"/ foreach qw(xml live_xml);
$d->{'live_xml'} =~ s{</domain>}{<vcpus>
 <vcpu id="0" enabled="yes" hotpluggable="no"/>
 <vcpu id="1" enabled="yes" hotpluggable="no"/>
 <vcpu id="2" enabled="yes" hotpluggable="yes"/>
 <vcpu id="3" enabled="no" hotpluggable="yes"/>
</vcpus></domain>};
is($m->settings($uuid)->{'live_limits'}->{'min_cpus'}, 2,
	'only enabled removable CPUs lower the live minimum');
my $id = request($m, 'update', { cpus => 2, memory_mib => 512 });
ok($m->run($id), 'a hot-added CPU can still be removed live');
is_deeply($d->{'calls'}, [['set_vcpus', Sys::Virt::Domain::VCPU_LIVE() |
	Sys::Virt::Domain::VCPU_CONFIG()]], 'permitted reduction uses the native live/config call');
}

# Re-evaluate the CPU minimum if the guest boots after a request is prepared.
{
my ($m, $a, $jobs, $d) = running_fixture();
$d->{$_} =~ s/current="1"/current="2"/ foreach qw(xml live_xml);
$d->{'active'} = 0;
my $id = request($m, 'update', { cpus => 1, memory_mib => 512 });
$d->{'active'} = 1;
ok($m->run($id), 'a newly started guest saves the CPU reduction for next start');
is($jobs->get($id)->{'scope'}, 'config', 'new live limit updates the job scope');
ok(!@{$d->{'calls'} || []}, 'state change is checked before any native write');
}

# A live refusal must not persist the requested configuration.
{
my ($m, $a, $jobs, $d) = running_fixture();
my $before = $d->{'xml'};
my $id = request($m, 'update', { cpus => 2, memory_mib => 512 });
$d->{'fail_live'} = 1;
ok(!$m->run($id), 'live failure is reported');
is($d->{'xml'}, $before, 'live refusal leaves persistent XML unchanged');
ok(!$jobs->get($id)->{'cleanup_pending'}, 'unchanged resources release the guest');
}

# Recovery completes a failed config save without repeating the live change.
{
my ($m, $a, $jobs, $d) = running_fixture();
my $id = request($m, 'update', { cpus => 2, memory_mib => 512 });
$d->{'fail_config'} = 1;
ok(!$m->run($id), 'persistent failure after live success is reported');
ok($jobs->get($id)->{'cleanup_pending'}, 'partial success remains reserved');
is(Cloudmin::Libvirt::parse_xml_document($d->{'live_xml'})->findvalue('/domain/vcpu/@current'),
	2, 'running CPU change really happened');
# Remove the injected save failure and recover only the missing CONFIG write.
$d->{'fail_config'} = 0;
$jobs->update($id, sub { $_[0]->{'state'} = 'recovering'; });
ok($m->run($id), 'recovery repairs the persistent definition');
is_deeply($d->{'calls'}->[-1], ['set_vcpus', Sys::Virt::Domain::VCPU_CONFIG()],
	'recovery changes only the missing persistent state');
}

# Every supported disk/NIC operation uses the running domain API.
{
my ($m, $a, $jobs, $d) = running_fixture();
foreach my $case (
	['attach_disk', {pool => 'pool', volume => 'extra.qcow2'}, 'attach_device'],
	['grow_disk', {target => 'vdb', disk_gib => 2}, 'block_resize'],
	['detach_disk', {target => 'vdb'}, 'detach_device'],
	['add_disk', {pool => 'pool', disk_gib => 1}, 'attach_device'],
	['add_interface', {network => 'network:nat', mac => '52:54:00:aa:bb:cc'}, 'attach_device'],
	['update_interface', {mac => '52:54:00:aa:bb:cc', link => 'down', inbound_kib => 1024}, 'update_device'],
	['update_interface', {mac => '52:54:00:aa:bb:cc', network => 'bridge:br-test'}, 'update_device'],
	['remove_interface', {mac => '52:54:00:aa:bb:cc'}, 'detach_device'],
) {
	my $id = request($m, $case->[0], $case->[1]);
	ok($m->run($id), $case->[0].' works live') or diag($jobs->get($id)->{'error'});
	is($d->{'calls'}->[-1]->[0], $case->[2], 'uses the requested native method');
	# Link-state and bandwidth edits must not suggest changing guest addresses.
	is($jobs->get($id)->{'network_changed'},
		$case->[0] =~ /interface/ && exists($case->[1]->{'network'}) || $case->[0] eq 'remove_interface' ? 1 : 0,
		'only attachment changes request guest networking guidance');
	}
ok(!$a->{'pool'}->{'volumes'}->{'extra.qcow2'}->{'resized'}, 'running disk never uses volume resize');
ok($a->{'pool'}->{'volumes'}->{'extra.qcow2'}, 'detachment preserves its disk file');
}

# Delayed removal keeps CONFIG until the guest confirms that the device is gone.
{
my ($m, $a, $jobs, $d) = running_fixture();
my $before = $d->{'xml'};
my $id = request($m, 'detach_disk', {target => 'vda'});
$d->{'detach_pending'} = 1;
ok(!$m->run($id), 'unacknowledged detach times out');
is($d->{'xml'}, $before, 'detach timeout leaves persistent configuration intact');
ok($jobs->get($id)->{'cleanup_pending'}, 'late removal remains recoverable');
# Failed jobs permit recovery-enabling power actions; an active worker does not.
foreach my $action (qw(resume shutdown force_off)) {
	ok(eval { $jobs->assert_guest_available($uuid, $action); 1 },
		"failed hotplug allows $action so the guest can complete recovery");
	}
ok(!eval { $jobs->assert_guest_available($uuid, 'reset'); 1 },
	'hard reset still waits for unfinished hardware changes');
$jobs->update($id, sub { $_[0]->{'state'} = 'recovering'; });
ok(!eval { $jobs->assert_guest_available($uuid, 'resume'); 1 },
	'resuming cannot race a recovery worker');
$jobs->update($id, sub { $_[0]->{'state'} = 'failed'; });
is_deeply($d->{'calls'}, [['detach_device', Sys::Virt::Domain::DEVICE_MODIFY_LIVE()]],
	'no config detach before acknowledgement');
# Model the guest completing the original unplug after the timeout.
$d->{'detach_pending'} = 0;
$d->detach_device('<disk><target dev="vda"/></disk>', 1);
$jobs->update($id, sub { $_[0]->{'state'} = 'recovering'; });
ok($m->run($id), 'recovery detects late device removal');
is_deeply($d->{'calls'}->[-1], ['detach_device', Sys::Virt::Domain::DEVICE_MODIFY_CONFIG()],
	'persistent detach follows confirmed live removal');
}

# State changes before execution choose the appropriate path afresh.
foreach my $start (0, 1) {
my ($m, $a, $jobs, $d) = running_fixture();
$d->{'active'} = $start;
my $id = request($m, 'update', {cpus => 2, memory_mib => 512});
$d->{'active'} = !$start;
ok($m->run($id), 'guest state is re-evaluated before execution');
is($jobs->get($id)->{'scope'}, $start ? 'config' : 'live', 'scope reflects execution state');
}

# A balloon can report an intermediate value after libvirt accepts its target.
{
my ($m, $a, $jobs, $d) = running_fixture();
my $id = request($m, 'update', {cpus => 1, memory_mib => 384});
local *ManageDomain::set_memory = sub {
	my ($domain, $target, $flags) = @_;
	# Save the target but expose an intermediate balloon size in live XML.
	$domain->mutate('set_memory', $target, $flags & 2);
	my $doc = Cloudmin::Libvirt::parse_xml_document($domain->{'live_xml'});
	Cloudmin::VMManage::set_text($doc->documentElement(), 'currentMemory', 448, {unit => 'MiB'});
	$domain->{'live_xml'} = $doc->toString();
	};
ok(!$m->run($id), 'slow balloon adjustment remains recoverable');
$jobs->update($id, sub { $_[0]->{'state'} = 'recovering'; });
ok(!$m->run($id), 'recovery waits while the balloon is still moving');
like($jobs->get($id)->{'error'}, qr/guest has not confirmed/, 'intermediate memory is not mistaken for an external edit');
is(scalar(@{$d->{'calls'}}), 1, 'accepted balloon request is not sent again');
$d->{'live_xml'} = $d->{'xml'};
$jobs->update($id, sub { $_[0]->{'state'} = 'recovering'; });
ok($m->run($id), 'recovery completes once the balloon reaches its target');
}

# Resource ceilings can be saved without changing the running hardware.
{
my ($m, $a, $jobs, $d) = running_fixture();
my $live = $d->{'live_xml'};
my $id = request($m, 'update', {cpus => 5, memory_mib => 1024, bootmenu => 1, boot => 'disk:vda'});
is($jobs->get($id)->{'request'}->{'scope'}, 'config', 'submission identifies a saved-only change');
ok($m->run($id), 'CPU, memory and boot changes are saved while running') or diag($jobs->get($id)->{'error'});
is($d->{'live_xml'}, $live, 'saved-only changes leave running hardware intact');
is_deeply($jobs->get($id)->{'deferred_fields'}, [qw(boot cpus memory)], 'result names all deferred groups');
is($m->settings($uuid)->{'pending'}->{'cpu_limit'}->{'saved'}, 5, 'saved CPU maximum is visible');
is($m->settings($uuid)->{'pending'}->{'memory_mib'}->{'saved'}, 1024, 'saved memory allocation is visible');
ok(!$d->{'calls'}, 'saved-only changes make no native live calls');
# A full start uses saved XML and removes the resource differences.
$d->{'active'} = 0;
$d->{'live_xml'} = $d->{'xml'};
$d->{'active'} = 1;
is_deeply($m->settings($uuid)->{'pending'}, {}, 'pending differences disappear after a full start');
}
# A new maximum and a supported allocation can share one update.
{
my ($m, $a, $jobs, $d) = running_fixture();
my $id = request($m, 'update', {cpus => 2, cpu_limit => 6, memory_mib => 384, memory_limit_mib => 1024});
ok($m->run($id), 'live allocations and saved maximums succeed together') or diag($jobs->get($id)->{'error'});
is_deeply($d->{'calls'}, [['set_vcpus', 1], ['set_memory', 1]], 'allocations change live before their maximums are saved');
my $s = $m->settings($uuid);
is($s->{'running'}->{'cpus'}, 2, 'CPU allocation changed live');
is($s->{'running'}->{'memory_mib'}, 384, 'memory allocation changed live');
is_deeply([sort keys %{$s->{'pending'}}], [qw(cpu_limit memory_limit_mib)], 'only maximums remain pending');
}
# A failed persistent save reports the real error without changing live hardware.
{
my ($m, $a, $jobs, $d) = running_fixture();
my $before = $d->{'xml'};
my $id = request($m, 'update', {cpus => 5, memory_mib => 512});
$a->{'fail_define'} = 1;
ok(!$m->run($id), 'persistent definition failure is reported');
is($d->{'xml'}, $before, 'failed definition leaves saved XML unchanged');
ok(!$d->{'calls'}, 'failed deferred update never touches live CPUs');
}
# Without a balloon, even a smaller allocation is a next-start setting.
{
my ($m, $a, $jobs, $d) = running_fixture();
$d->{$_} =~ s{<memballoon model="virtio"/>}{} foreach qw(xml live_xml);
my $id = request($m, 'update', {cpus => 1, memory_mib => 384});
ok($m->run($id), 'memory without a balloon saves for next start');
is($jobs->get($id)->{'scope'}, 'config', 'missing balloon selects configuration only');
is_deeply($m->settings($uuid)->{'pending'}->{'memory_mib'}, {running => 512, saved => 384}, 'memory values remain distinct until start');
ok(!$d->{'calls'}, 'no unsupported balloon call is attempted');
}
# A lower saved maximum must not block allocations allowed by the running guest.
{
my ($m, $a, $jobs, $d) = running_fixture();
$d->{'xml'} =~ s/current="1">4/current="1">1/;
my $id = request($m, 'update', {cpus => 2, cpu_limit => 2, memory_mib => 512});
ok($m->run($id), 'edit replaces a lower pending maximum without a config-only CPU error');
is_deeply($d->{'calls'}, [['set_vcpus', 1]], 'allocation uses LIVE while its new saved maximum is pending');
is_deeply($m->settings($uuid)->{'pending'}->{'cpu_limit'}, {running => 4, saved => 2}, 'new saved maximum remains visible');
}
# Lost define replies and mixed partial success recover through the same journal.
foreach my $lost_reply (0, 1) {
my ($m, $a, $jobs, $d) = running_fixture();
my $id = request($m, 'update', {cpus => 2, cpu_limit => 6, memory_mib => 512});
$a->{$lost_reply ? 'lost_reply' : 'fail_define'} = 1;
ok(!$m->run($id), 'failed deferred save leaves the mixed job recoverable');
ok($jobs->get($id)->{'cleanup_pending'}, 'changed live allocation keeps the job reserved');
delete @$a{qw(lost_reply fail_define)};
$jobs->update($id, sub { $_[0]->{'state'} = 'recovering'; });
ok($m->run($id), 'recovery finishes the saved maximum') or diag($jobs->get($id)->{'error'});
is(scalar(@{$d->{'calls'}}), 1, 'recovery does not repeat the live CPU change');
is($a->{'defines'}, 1, 'definition is committed exactly once');
}
# Pending boot order survives later network edits without reaching the live XML.
{
my ($m, $a, $jobs, $d) = running_fixture();
my $mac = '52:54:00:11:22:33';
my $id = request($m, 'update', {cpus => 1, memory_mib => 512, boot => 'nic:'.$mac,
    changes => [{action => 'update_interface', mac => $mac, link => 'down'}]});
ok($m->run($id), 'boot selection and live network edit succeed together') or diag($jobs->get($id)->{'error'});
my $live = Cloudmin::Libvirt::parse_xml_document($d->{'live_xml'});
ok(!$live->exists('/domain/devices/interface/boot'), 'new boot order never entered the live interface');
$id = request($m, 'update_interface', {mac => $mac, link => 'up'});
ok($m->run($id), 'later network edit preserves both boot definitions') or diag($jobs->get($id)->{'error'});
$live = Cloudmin::Libvirt::parse_xml_document($d->{'live_xml'});
ok(!$live->exists('/domain/devices/interface/boot'), 'pending boot order stays out of later live updates');
ok(Cloudmin::Libvirt::parse_xml_document($d->{'xml'})->exists('/domain/devices/interface/boot'), 'later update keeps the saved boot selection');
}
# Empty live CD drives omit their raw format; this is not an external edit.
{
my ($m, $a, $jobs, $d) = running_fixture();
my $cd = '<disk type="file" device="cdrom"><driver name="qemu" type="raw"/><target dev="sda" bus="scsi"/><readonly/></disk>';
$d->{'xml'} =~ s{</devices>}{$cd</devices>};
$cd =~ s/ type="raw"//;
$d->{'live_xml'} =~ s{</devices>}{$cd</devices>};
my $volume = bless({ name => 'rescue.iso', format => 'raw', capacity => 1024**2,
	pool => $a->{'pool'} }, 'ManageVolume');
$a->{'pool'}->{'volumes'}->{'rescue.iso'} = $volume;
my $id = request($m, 'change_media', {target => 'sda', pool => 'pool', volume => 'rescue.iso'});
ok($m->run($id), 'empty live CD accepts media despite omitted format') or diag($jobs->get($id)->{'error'});
is($d->{'calls'}->[-1]->[0], 'update_device', 'media insertion uses the native update method');
$id = request($m, 'change_media', {target => 'sda', volume => ''});
ok($m->run($id), 'media eject preserves the drive');
ok(Cloudmin::VMManage::hotplug_device(Cloudmin::Libvirt::parse_xml_document($d->{'xml'}), 'disk', 'sda'),
	'empty persistent CD drive remains defined');
}
# ISO swaps are independent of writable disk snapshot and checkpoint chains.
for my $history ('snapshot', 'checkpoint') {
for my $active (0, 1) {
    # Start with existing history and an empty read-only removable drive.
    my ($m, $a, $jobs, $d) = running_fixture();
    $d->{'active'} = $active;
    $d->{$history} = 1;
    my $cd = '<disk type="file" device="cdrom"><driver name="qemu" type="raw"/><target dev="sda" bus="scsi"/><readonly/></disk>';
    $d->{$_} =~ s{</devices>}{$cd</devices>} for qw(xml live_xml);
    $a->{'pool'}->{'volumes'}->{'setup.iso'} = bless({name => 'setup.iso',
        format => 'raw', capacity => 1024**2, pool => $a->{'pool'}}, 'ManageVolume');
    # Exercise insertion and ejection for both live and stopped definitions.
    for my $media ('setup.iso', '') {
        my $change = {target => 'sda', pool => 'pool', volume => $media};
        # The editor batches media insertion with resource fields; the API
        # also supports a direct eject action.
        my $id = $media ? request($m, 'update', {cpus => 1, memory_mib => 512, changes => [{action => 'change_media', %$change}]})
            : request($m, 'change_media', $change);
        # The saved attachment changes while existing history stays intact.
        ok($m->run($id), "media swap with $history, active=$active") or diag($jobs->get($id)->{'error'});
        my $doc = Cloudmin::Libvirt::parse_xml_document($d->{'xml'});
        is($doc->findvalue('/domain/devices/disk[@device="cdrom"]/source/@file'),
            $media ? '/fixture/'.$media : '', 'saved drive contains the requested media');
        ok($d->{$history}, 'media swap preserves history');
    }
}
}

# Spare ports are checked before creating a disk; CPU changes still work.
{
my ($m, $a, $jobs, $d) = running_fixture();
$d->{'xml'} =~ s/arch="x86_64"/arch="x86_64" machine="q35"/;
$d->{'live_xml'} = $d->{'xml'};
my $id = request($m, 'add_disk', {pool => 'pool', disk_gib => 1});
ok(!$m->run($id), 'guest without ports refuses hot-add before allocation');
is($jobs->get($id)->{'scope'}, 'offline-required', 'missing ports report the required scope');
is(scalar(keys %{$a->{'pool'}->{'volumes'}}), 2, 'no unused disk was allocated');
$id = request($m, 'update', {cpus => 2, memory_mib => 512});
ok($m->run($id), 'missing PCIe ports do not block CPU changes');
$d->{'active'} = 0;
$id = request($m, 'update', {cpus => 2, memory_mib => 512, enable_live => 1});
ok($m->run($id), 'stopped legacy guest gains hardware expansion');
my $doc = Cloudmin::Libvirt::parse_xml_document($d->{'xml'});
is($doc->findnodes('/domain/devices/controller[@model="pcie-root-port"]')->size(), 16, 'offline expansion adds ports');
ok($doc->findnodes('/domain/devices/disk[@device="cdrom"]'), 'offline expansion adds empty CD drive');
}
# Recovery must not mask an unrelated edit to the CPU maximum.
{
my ($m, $a, $jobs, $d) = running_fixture();
my $id = request($m, 'update', {cpus => 2, memory_mib => 512});
$d->{'fail_config'} = 1;
ok(!$m->run($id), 'fixture leaves a live-only CPU change');
$d->{'xml'} =~ s{>4</vcpu>}{>8</vcpu>};
delete($d->{'fail_config'});
$jobs->update($id, sub { $_[0]->{'state'} = 'recovering'; });
ok(!$m->run($id), 'recovery refuses an externally changed maximum');
like($jobs->get($id)->{'error'}, qr/Unrelated settings changed/, 'recovery explains the conflict');
}

# A long storage allocation cannot hide an external edit before hardware writes.
foreach my $active (0, 1) {
my ($m, $a, $jobs, $d) = running_fixture();
$d->{'active'} = $active;
my $id = request($m, 'add_disk', {pool => 'pool', disk_gib => 1});
my $apply = \&Cloudmin::VMManage::apply_storage;
local *Cloudmin::VMManage::apply_storage = sub {
	# Simulate a libvirt editor racing the disk
	# allocation, after its side effect.
	$apply->(@_);
	$d->{'xml'} =~ s{</domain>}{<description>External edit during copy</description></domain>};
	};
ok(!$m->run($id), 'external edit during storage work stops the hardware change');
like($jobs->get($id)->{'error'}, qr/configuration changed during storage work/,
	'failure identifies the changed definition');
ok(!$d->{'calls'} && !$a->{'defines'}, 'neither live hardware nor saved settings are overwritten');
}
# Snapshot and checkpoint history do not prevent resource or network edits.
foreach my $history (qw(snapshot checkpoint)) {
foreach my $active (0, 1) {
my ($m, $a, $jobs, $d) = running_fixture();
$d->{'active'} = $active;
$d->{$history} = 1;
my $id = request($m, 'update', {cpus => 2, memory_mib => 384,
	description => 'Edited with history', changes => [
		{action => 'grow_disk', target => 'vda', disk_gib => 1},
		{action => 'update_interface', mac => '52:54:00:11:22:33', link => 'down'}]});
ok($m->run($id), "resources and network update with $history, active=$active")
	or diag($jobs->get($id)->{'error'});
my $settings = $m->settings($uuid);
is($settings->{'cpus'}, 2, 'CPU edit persists with history');
is($settings->{'memory_mib'}, 384, 'memory edit persists with history');
is($settings->{'description'}, 'Edited with history', 'description edit persists with history');
is($settings->{'interfaces'}->[0]->{'link'}, 'down', 'network edit persists with history');
ok(!$a->{'pool'}->{'volumes'}->{'root.qcow2'}->{'resized'}, 'unchanged disk size is skipped');
my $before = $d->{'xml'};
foreach my $case (
	['grow_disk', {target => 'vda', disk_gib => 2}],
	['detach_disk', {target => 'vda'}],
	['delete_disk', {target => 'vda'}],
	['add_disk', {pool => 'pool', disk_gib => 1}],
	['attach_disk', {pool => 'pool', volume => 'extra.qcow2'}],
	['update', {cpus => 2, memory_mib => 384, enable_live => 1}],
	['update', {cpus => 3, memory_mib => 384,
		changes => [{action => 'detach_disk', target => 'vda'}]}],
) {
	# Actual storage changes remain blocked even when
	# grouped with resource edits.
	ok(!eval { request($m, $case->[0], $case->[1]); 1 }, "$history blocks $case->[0] storage changes");
	like($@, qr/before changing writable disks/, 'refusal identifies the storage restriction');
	}
is($d->{'xml'}, $before, 'refused storage changes preserve the definition');
is(scalar(keys %{$a->{'pool'}->{'volumes'}}), 2, 'refused storage changes allocate nothing');
}
}

# History created after submission is checked before storage work or hotplug.
foreach my $active (0, 1) {
my ($m, $a, $jobs, $d) = running_fixture();
$d->{'active'} = $active;
my $id = request($m, 'add_disk', {pool => 'pool', disk_gib => 1});
$d->{'checkpoint'} = 1;
ok(!$m->run($id), 'new checkpoint blocks a queued disk change');
like($jobs->get($id)->{'error'}, qr/before changing writable disks/, 'worker checks current history');
ok(!$d->{'calls'} && !$a->{'defines'}, 'queued refusal makes no hardware write');
is(scalar(keys %{$a->{'pool'}->{'volumes'}}), 2, 'queued refusal makes no storage write');
ok(!$jobs->get($id)->{'cleanup_pending'}, 'unchanged refused job releases its reservation');
}

# A saved memory image still blocks edits even when disk history is permitted.
{
my ($m, $a, $jobs, $d) = fixture();
$d->{'saved'} = 1;
ok(!eval { request($m, 'update', {cpus => 2, memory_mib => 384}); 1 },
	'managed save still blocks resource changes');
like($@, qr/Remove the managed save/, 'managed save refusal remains specific');
}
# A socket layout must not turn every shared-form save into a resource error.
foreach my $active (0, 1) {
my ($m, $a, $jobs, $d) = running_fixture();
$d->{'active'} = $active;
$d->{'snapshot'} = 1;
$d->{'xml'} =~ s{<vcpu current="1">4</vcpu>}{<vcpu current="1">3</vcpu>};
my $topology = '<cpu mode="host-passthrough"><topology sockets="3" dies="1" clusters="1" cores="1" threads="1"/></cpu>';
$d->{'xml'} =~ s{</domain>}{$topology</domain>};
$d->{'live_xml'} = $d->{'xml'};
my $id = request($m, 'update', {cpus => 2, memory_mib => 384,
	description => 'Topology retained', changes => [
		{action => 'update_interface', mac => '52:54:00:11:22:33', link => 'down'}]});
ok($m->run($id), "topology guest accepts resource and network edits, active=$active")
	or diag($jobs->get($id)->{'error'});
is(($m->settings($uuid))->{'cpu_limit'}, 3, 'CPU maximum remains tied to its topology');
like($d->{'xml'}, qr/\Q$topology\E/, 'custom CPU layout is preserved');
ok(!eval { request($m, 'update', {cpus => 2, cpu_limit => 4, memory_mib => 384}); 1 },
	'changing a topology-bound maximum is refused');
like($@, qr/CPU maximum is fixed/, 'only the conflicting CPU field is identified');
my $settings = $m->settings($uuid);
is_deeply($settings->{'resource_locks'}, {cpus => 0, cpu_limit => 1,
	memory_mib => 0, memory_limit_mib => 0}, 'editor locks only the topology-bound field');
}

# Advanced layouts still permit unrelated saves without rewriting resource XML.
foreach my $case (
	['<vcpus><vcpu id="0" enabled="yes" hotpluggable="no"/><vcpu id="1" enabled="no" hotpluggable="yes"/></vcpus>',
		{cpus => 2}, qr/CPU count is controlled/],
	['<cputune><vcpupin vcpu="0" cpuset="0"/></cputune>',
		{cpu_limit => 5}, qr/CPU maximum is fixed/],
	['<cpu><numa><cell id="0" cpus="0-3" memory="524288" unit="KiB"/></numa></cpu>',
		{memory_limit_mib => 768}, qr/memory maximum is fixed/],
	['<maxMemory slots="4" unit="MiB">2048</maxMemory>',
		{memory_limit_mib => 768}, qr/memory maximum is fixed/],
) {
my ($m, $a, $jobs, $d) = running_fixture();
$d->{'active'} = 0;
$d->{'xml'} =~ s{</domain>}{$case->[0]</domain>};
my $id = request($m, 'update', {cpus => 1, memory_mib => 512, description => 'Unrelated edit'});
ok($m->run($id), 'advanced resource settings permit a description save');
like($d->{'xml'}, qr/\Q$case->[0]\E/, 'advanced settings remain intact');
ok(!eval { request($m, 'update', {cpus => 1, memory_mib => 512, %{$case->[1]}}); 1 },
	'conflicting resource edit is refused');
like($@, $case->[2], 'resource refusal identifies the affected setting');
}

# Adding ports must not silently grow the maximum beyond an existing topology.
{
my ($m, $a, $jobs, $d) = running_fixture();
$d->{'active'} = 0;
$d->{'xml'} =~ s{<vcpu current="1">4</vcpu>}{<vcpu current="2">3</vcpu>};
$d->{'xml'} =~ s{</domain>}{<cpu><topology sockets="3" cores="1" threads="1"/></cpu></domain>};
my $id = request($m, 'update', {cpus => 2, memory_mib => 512, enable_live => 1});
ok($m->run($id), 'hardware expansion preserves an existing topology');
is(($m->settings($uuid))->{'cpu_limit'}, 3, 'expansion never overrides the topology maximum');
}
# Clean power cycles apply saved hardware and never force a timed-out shutdown.
{
my ($m, $a, $jobs, $d) = running_fixture();
$d->{'xml'} =~ s/current="1"/current="2"/;
my $id = request($m, 'power_cycle', {});
ok($m->run($id), 'power cycle completes through the job worker');
is($d->{'shutdowns'}, 1, 'clean shutdown requested once');
is($d->{'starts'}, 1, 'guest starts once after shutdown');
is_deeply($m->settings($uuid)->{'pending'}, {}, 'new start applies pending resources');
ok($m->run($id), 'completed job can be queried again');
is($d->{'shutdowns'}, 1, 'repeated job cannot power cycle twice');
is_deeply([ map { $_->{'step'} } @{$jobs->get($id)->{'events'}} ],
	[qw(power_cycle_shutdown power_cycle_start)], 'both power phases are journalled');
}
# A guest that ignores ACPI remains running and available for manual action.
{
my ($m, $a, $jobs, $d) = running_fixture();
$d->{'shutdown_stuck'} = 1;
$m->{'shutdown_timeout'} = 0;
my $id = request($m, 'power_cycle', {});
ok(!$m->run($id), 'shutdown timeout fails the job');
like($jobs->get($id)->{'error'}, qr/did not shut down.*No forced power-off/s, 'timeout explains actual outcome');
ok($d->{'active'} && !$d->{'starts'}, 'timeout leaves guest running without a second start');
ok(!$jobs->get($id)->{'cleanup_pending'}, 'timeout permits a later manual power action');
}
# Queued power cycles must not apply a definition changed after submission.
{
my ($m, $a, $jobs, $d) = running_fixture();
my $id = request($m, 'power_cycle', {});
$d->{'xml'} =~ s/current="1"/current="2"/;
ok(!$m->run($id), 'queued definition changes refuse power cycle');
ok(!$d->{'shutdowns'}, 'revision mismatch does not shut down guest');
}
# A refused start leaves the stopped guest available
# without a hardware recovery.
{
my ($m, $a, $jobs, $d) = running_fixture();
my $id = request($m, 'power_cycle', {});
$d->{'start_refused'} = 1;
ok(!$m->run($id), 'start failure retains native error');
like($jobs->get($id)->{'error'}, qr/Start refused/, 'actual startup refusal reported');
ok(!$d->{'active'} && !$jobs->get($id)->{'cleanup_pending'}, 'stopped guest remains available for manual start');
}
# A journalled start with a lost reply completes
# without cycling the guest twice.
{
my ($m, $a, $jobs, $d) = running_fixture();
my $id = request($m, 'power_cycle', {});
$jobs->update($id, sub { $_[0]->{'resources'} = { started => 1, shutdown_complete => 1, start_requested => 1 }; });
ok($m->run($id), 'lost start reply recovers by checking current state');
ok(!$d->{'shutdowns'} && !$d->{'starts'}, 'recovery does not repeat power actions');
}
# Paused execution cannot acknowledge the clean shutdown used for a power cycle.
{
my ($m, $a, $jobs, $d) = running_fixture();
$d->{'state'} = 3;
eval { request($m, 'power_cycle', {}); };
like($@, qr/Resume the virtual machine/, 'paused guest needs an explicit resume');
}
# An external forced stop must not satisfy a requested clean shutdown.
{
my ($m, $a, $jobs, $d) = running_fixture();
$d->{'reason'} = 2;
my $id = request($m, 'power_cycle', {});
ok(!$m->run($id), 'an unclean stop cannot satisfy a power cycle');
like($jobs->get($id)->{'error'}, qr/without a clean shutdown/, 'unclean stop is explained');
ok(!$d->{'starts'}, 'an uncleanly stopped guest is not automatically started');
}
# A cancellation accepted at the first-write lock must prevent shutdown.
{
my ($m, $a, $jobs, $d) = running_fixture();
my $id = request($m, 'power_cycle', {});
my $update = \&Cloudmin::Jobs::update;
local *Cloudmin::Jobs::update = sub {
	my ($store, $job, $callback) = @_;
	# Race the worker's first-write transaction
	# with an accepted cancellation.
	return $update->($store, $job, sub { $_[0]->{'cancel'} = 1; $callback->(@_); });
	};
$m->run($id);
is($jobs->get($id)->{'state'}, 'cancelled', 'cancellation wins before power changes');
ok(!$d->{'shutdowns'}, 'cancelled cycle leaves the guest running');
}
# Both memory controls round decimal GiB to stored whole MiB.
{
	my ($manager, $adapter, $journal, $domain) = fixture();
	my $job = request($manager, 'update', { cpus => 1, memory_mib => 1.1,
		memory_mib_units => 1024**3, memory_limit_mib => 1.2,
		memory_limit_mib_units => 1024**3 });
	ok($manager->run($job), 'decimal memory edit succeeds');
	my $settings = $manager->settings($uuid);
	is($settings->{'memory_mib'}, 1126, 'current memory rounds to nearest MiB');
	is($settings->{'memory_limit_mib'}, 1229, 'maximum memory rounds to nearest MiB');
}
done_testing();
