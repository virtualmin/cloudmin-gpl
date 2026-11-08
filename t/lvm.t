use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use WebminCore qw(convert_to_json);
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path remove_tree);
require "$Bin/../lib/Cloudmin/Libvirt.pm";

my $group_id = '111111-2222-3333-4444-5555-6666-777777';
my $native_id = '11111111-2222-4333-8444-555555555555';
my $groups =
	[ { vg_name => 'guests', vg_uuid => $group_id, vg_size => '10737418240',
	    vg_free => '4294967296', vg_extent_size => '4194304', vg_attr =>
									  'wz--n-' } ];
my @volumes;

# volume(name, segment, [thin_pool]) builds metadata without touching host LVM.
sub volume
{
my ($name, $segment, $thin) = @_;
return { vg_name => 'guests', vg_uuid => $group_id, lv_name => $name,
	 lv_uuid =>
		 sprintf('%06d-2222-3333-4444-5555-6666-777777', 1 + @volumes),
	 lv_size => '1073741824', lv_attr => $segment eq 'thin'
		 ? 'Vwi-a-tz--'
		 : $segment eq 'thin-pool' ? 'twi-a-tz--' : '-wi-a-----',
	 segtype => $segment, pool_lv => $thin || '', origin => '',
	 lv_path => '/dev/guests/'.$name, lv_active => 'active', lv_tags => '',
	 data_percent => $segment =~ /thin/ ? '25.00' : '',
	 metadata_percent => $segment eq 'thin-pool' ? '1.00' : '',
	 zero => $segment eq 'thin-pool' ? 'zero' : 'unknown',
	 lv_health_status => '',
	 lv_kernel_major => '253', lv_kernel_minor => ''.(1 + @volumes) };
}
push(@volumes, volume('thick', 'linear'));
push(@volumes, volume('fast', 'thin-pool'));
push(@volumes, volume('guest', 'thin', 'fast'));
push(@volumes, volume('other', 'thin-pool'));
push(@volumes, volume('other-guest', 'thin', 'other'));
my @calls;
# runner(command, arguments...) returns fixture reports and rejects mutations.
my $driver = Cloudmin::LVM->new(readonly => 0, runner => sub {
	my ($command, @args) = @_;
	push(@calls, [ $command, @args ]);
	return convert_to_json({ report => [ { vg => $groups } ] })
		if ($command eq 'vgs');
	return convert_to_json({ report => [ { lv => \@volumes } ] })
		if ($command eq 'lvs');
	die "Unexpected mutation\n";
	});

{
	package LVMPool;

	# get_uuid_string(self) returns the native libvirt VG registration ID.
	sub get_uuid_string
	{
	return $native_id;
	}

	# get_name(self) returns the registered pool's display name.
	sub get_name
	{
	return 'storage';
	}

	# get_xml_description(self, [flags]) identifies the
	# registered volume group.
	sub get_xml_description
	{
	return '<pool type="logical"><name>storage</name><source><name>guests</name></source><target><path>/dev/guests</path></target></pool>';
	}

	# is_active(self) supplies a running fixture VG.
	sub is_active
	{
	return 1;
	}

	# is_persistent(self) supplies a saved fixture registration.
	sub is_persistent
	{
	return 1;
	}

	# get_autostart(self) supplies the fixture boot policy.
	sub get_autostart
	{
	return 1;
	}

	# refresh(self) needs no host action; the driver
	# reloads fixture metadata.
	sub refresh
	{
	}
	}

# Pool inventory separates allocation destinations and keeps stable identifiers.
my @pools = $driver->pools(bless({ }, 'LVMPool'));
is(scalar(@pools), 3, 'one thick destination and two thin destinations');
is($pools[0]->get_uuid_string(), $native_id,
   'thick destination keeps the libvirt UUID');
is($pools[1]->get_name(), 'storage/fast',
   'thin pool display identifies its parent');
like($pools[1]->get_uuid_string(),
     qr/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/,
     'thin pool has a public UUID');
isnt($pools[1]->get_uuid_string(), $pools[2]->get_uuid_string(),
     'thin pool UUIDs do not collide');
is_deeply([ map { $_->get_name() } $pools[0]->list_all_volumes() ], [ 'thick' ],
	  'thick inventory excludes thin disks and metadata');
is_deeply([ map { $_->get_name() } $pools[1]->list_all_volumes() ], [ 'guest' ],
	  'thin inventory includes only this pool');
is(scalar(@calls), 2, 'one operation shares a single LVM inventory');
my ($disk) = $pools[1]->list_all_volumes();
my $key = $disk->get_key();
like($key, qr/^lvm:\Q$group_id\E:/,
     'logical volume identity contains both LVM UUIDs');
is($disk->get_info()->{'type'}, 1, 'logical volumes report block storage');
is($disk->get_info()->{'allocation'}, 268435456,
   'thin allocation is physical usage');
is($pools[1]->get_info()->{'available'}, 805306368,
   'thin available space excludes allocated chunks');
is($pools[1]->get_info()->{'metadata_percent'}, 1,
   'thin metadata usage is reported');
like($disk->get_xml_description(), qr/<format type="raw"/,
     'logical disks use raw format');
is(Cloudmin::LVM::capacity({ lv_attr => 'swi-a-s---', segtype => 'linear',
			     lv_size => 104857600, origin_size => 100663296 }),
   100663296,
   'classic snapshot capacity is its origin, even when lvs reports linear segments');
is(Cloudmin::LVM::device_path('guest-vg', 'disk-1'),
   '/dev/mapper/guest--vg-disk--1',
   'canonical mapper paths escape dashes in both names');
is($pools[0]->aligned_capacity(4194305), 8388608,
   'thick capacity rounds up to a complete extent');
is($pools[1]->aligned_capacity(513), 1024,
   'thin capacity rounds up to a sector');

# Btrfs mountinfo hides member device numbers behind an anonymous filesystem ID.
{
	my $root = tempdir(CLEANUP => 1);
	my $devices = "$root/$native_id/devices";
	make_path("$devices/dm-1", "$devices/dm-2", "$root/features");
	for my $minor ( 1, 2 ) {
		open(my $fh, '>', "$devices/dm-$minor/dev") or die $!;
		print($fh "253:$minor\n");
		close($fh) or die $!;
		}
	for my $minor ( 1, 2 ) {
		ok(!eval { Cloudmin::LVM::btrfs_host_use("253:$minor",
							 $root); 1 },
		   "mounted Btrfs member $minor is refused");
		like($@, qr/mounted on the host by Btrfs/,
		     'mount refusal explains the owner');
		}
	ok(Cloudmin::LVM::btrfs_host_use('253:3', $root),
	   'unrelated LV remains usable');
	unlink("$devices/dm-2/dev") or die $!;
	ok(!eval { Cloudmin::LVM::btrfs_host_use('253:3', $root); 1 },
	   'unreadable member identity fails closed');
	remove_tree("$devices/dm-1", "$devices/dm-2");
	ok(Cloudmin::LVM::btrfs_host_use('253:1', $root),
	   'unmounted filesystem no longer owns its LVs');
	ok(Cloudmin::LVM::btrfs_host_use('253:1', "$root/absent"),
	   'unloaded Btrfs needs no device checks');
	}

# Whole-group checks include hidden mappings and thin-pool aliases.
{
	no warnings 'redefine';
	my @checked;
	local *Cloudmin::LVM::host_use = sub { push(@checked, [ @_ ]); 1 };
	# Model visible LVs plus a thin-pool mapping with internal opens.
	(my $vg = $group_id) =~ s/-//g;
	my @mappings = map {
		(my $lv = $_->{lv_uuid}) =~ s/-//g;
		"LVM-$vg$lv|253|$_->{lv_kernel_minor}|0"
		} @volumes;
	push(@mappings, "LVM-$vg".('a' x 32)."-tpool|253|99|2");
	# Replace only dmsetup output; exercise the real
	# group membership parser.
	my $report = join("\n", @mappings);
	my $checking = Cloudmin::LVM->new(runner => sub {
		is($_[0], 'dm_info',
		   'host check requests read-only device-mapper inventory');
		return $report;
		});
	ok($checking->group_host_use($pools[0]->group()),
	   'unused whole group passes host checks');
	is(scalar(@checked), 6, 'visible and hidden mappings are all checked');
	is($checked[-1]->[0]->{lv_path}, '/dev/block/253:99',
	   'internal device uses its kernel identity');
	is($checked[-1]->[0]->{open_count}, 2,
	   'open count reaches the host-use guard');
	ok($checked[0]->[1]->{'253:99'},
	   'only devices in this group are allowed as internal holders');
	# Missing or malformed device state must never authorize deactivation.
	$report = '';
	ok(!eval { $checking->group_host_use($pools[0]->group()); 1 },
	   'missing active mappings fail closed');
	$report = "LVM-$vg".('a' x 32)."|253|99|unknown";
	ok(!eval { $checking->group_host_use($pools[0]->group()); 1 },
	   'unknown device usage fails closed');
	# A valid report still cannot override a host-use refusal.
	$report = join("\n", @mappings);
	local *Cloudmin::LVM::host_use = sub { die "Host swap is in use\n" };
	ok(!eval { $checking->group_host_use($pools[0]->group()); 1 },
	   'host-use refusal propagates');
	}

# Reusing a path or a name cannot inherit a deleted LV's ownership.
{
	local $volumes[2]->{'lv_uuid'} =
		'999999-2222-3333-4444-5555-6666-777777';
	ok(!eval { $disk->record(1); 1 }, 'replacement LV is rejected');
	like($@, qr/replaced/,
	     'replacement error explains the changed identity');
	}
$driver->inventory(1);
{
	local $volumes[1]->{'lv_uuid'} =
		'999999-2222-3333-4444-5555-6666-777777';
	ok(!eval { $pools[1]->group(1); 1 },
	   'replacement thin pool is rejected');
	}
$driver->inventory(1);
{
	local $groups->[0]->{'vg_uuid'} =
		'999999-2222-3333-4444-5555-6666-777777';
	ok(!eval { $driver->inventory(1); 1 },
	   'inconsistent VG and LV reports fail closed');
	}
$driver->inventory(1);

# Unknown usage must not appear as an empty healthy thin pool.
{
	local $volumes[1]->{'metadata_percent'} = '';
	$driver->inventory(1);
	ok(!eval { $pools[1]->get_info(); 1 },
	   'unavailable metadata usage is rejected');
	}
$driver->inventory(1);
for my $case ( [ 'data_percent', '95', qr/Extend/ ],
	       [ 'metadata_percent', '90', qr/Extend/ ],
	       [ 'lv_health_status', 'needs_check', qr/Repair/ ] ) {
	local $volumes[1]->{$case->[0]} = $case->[1];
	ok(
		!eval { $pools[1]->create_volume(
			'<volume><name>refused</name><capacity>4096</capacity></volume>'); 1 },
		'unsafe thin pool refuses allocation: '.$case->[0]);
	like($@, $case->[2],
	     'thin-pool refusal explains the required action');
	}
$driver->inventory(1);
foreach my $name ( '../root', '-option', '/dev/root', 'name;command',
		   'thin_tmeta', 'snapshot0' ) {
	ok(!eval { Cloudmin::LVM::name($name); 1 },
	   "unsafe or reserved name rejected: $name");
	}
foreach my $bytes ( '-1', 'NaN', '2.5', '9007199254740992' ) {
	ok(!eval { Cloudmin::LVM::number($bytes); 1 },
	   "invalid capacity rejected: $bytes");
	}
{
	local $driver->{'readonly'} = 1;
	my $before = @calls;
	ok(!eval { $driver->command('lvremove', '--yes', '--select',
				    'lv_uuid=fixture'); 1 },
	   'read-only mode refuses mutation');
	is(scalar(@calls), $before,
	   'read-only request never reaches the runner');
	}
ok(!eval { $driver->command('vgremove', 'guests'); 1 },
   'unimplemented destructive operation is rejected');
ok(
	!eval { $pools[1]->create_volume(
		'<volume><name>new</name><capacity>4096</capacity><target><format type="qcow2"/></target></volume>'); 1 }, 'QCOW2 cannot be uploaded as a raw logical disk');
like($@, qr/raw disks/, 'format error is explicit');

# Thin creation uses Webmin's existing helper and reserves virtual capacity.
{
	my $settings;
	local $driver->{'creator'} = sub {
		$settings = { %{$_[0]} };
		my $record =
			volume($settings->{'name'}, 'thin',
			       $settings->{'thin_in'});
		$record->{'lv_size'} = $settings->{'size'} * 1024;
		push(@volumes, $record);
		return undef;
		};
	my $created =
		$pools[1]->create_volume(
			'<volume><name>large-guest</name><capacity unit="bytes">2147483648</capacity><target><format type="raw"/></target></volume>');
	is($settings->{'thin_in'}, 'fast',
	   'Webmin receives the selected thin pool');
	is($settings->{'size'}, 2097152,
	   'byte capacity is converted to Webmin KiB units');
	is($settings->{'perm'}, 'rw', 'Webmin creates a writable disk');
	is($created->get_info()->{'capacity'}, 2147483648,
	   'virtual capacity can exceed physical thin-pool capacity');
	}
{
	local $volumes[1]->{'zero'} = '';
	ok(
		!eval { $pools[1]->create_volume(
			'<volume><name>unsafe</name><capacity>4096</capacity></volume>'); 1 }, 'thin pool without zeroing cannot expose old data');
	like($@, qr/zeroing/, 'zeroing requirement is explained');
	}

# Conversion accepts only backing files present in active libvirt file pools.
{
	package ConversionVolume;

	# get_path(self) returns a harmless temporary file
	# representing the layer.
	sub get_path
	{
	$_[0]->{path}
	}

	# get_xml_description(self, [flags]) supplies
	# libvirt's backing metadata.
	sub get_xml_description
	{
	my ($self) = @_;
	return '<volume><target><format type="'.$self->{format}.
	       '"/></target>'.
	       ($self->{backing}
		       ? '<backingStore><path>'.$self->{backing}.
		'</path></backingStore>'
		       : '').'</volume>';
	}
	package ConversionPool;

	# get_xml_description(self, [flags]) identifies file storage.
	sub get_xml_description
	{
	'<pool type="dir"><target><path>/fixture</path></target></pool>'
	}

	# is_active(self) supplies readable managed storage.
	sub is_active
	{
	1
	}

	# list_all_volumes(self) returns only the explicitly managed layers.
	sub list_all_volumes
	{
	@{$_[0]->{volumes}}
	}
	package ConversionConnection;

	# list_all_storage_pools(self, [flags]) supplies the one fixture pool.
	sub list_all_storage_pools
	{
	$_[0]->{pool}
	}
	package main;
	my $work = tempdir(CLEANUP => 1);
	for my $name (qw(top base unknown)) {
		open(my $fh, '>', "$work/$name") or die $!;
		close($fh);
		}
	my $base =
		bless({ path => "$work/base", format => 'raw' },
		      'ConversionVolume');
	my $top =
		bless({ path => "$work/top", format => 'qcow2',
			backing => 'base' },
		      'ConversionVolume');
	my $pool = bless({ volumes => [ $top, $base ] }, 'ConversionPool');
	my $adapter = Cloudmin::Libvirt->new(connection_factory => sub {
		bless({ pool => $pool }, 'ConversionConnection');
		});
	my ($files, $layers) = $adapter->conversion_sources($top);
	is_deeply($files, { image => "$work/top", layer1 => "$work/base" },
		  'relative backing path resolves through managed inventory');
	is_deeply($layers,
		  [ { name => 'image', format => 'qcow2' },
		    { name => 'layer1', format => 'raw' } ],
		  'worker receives only fixed private names and formats');
	$top->{backing} = 'unknown';
	ok(!eval { $adapter->conversion_sources($top); 1 },
	   'unmanaged backing file is rejected even when it exists');
	$top->{backing} = 'top';
	ok(!eval { $adapter->conversion_sources($top); 1 },
	   'cyclic backing metadata is rejected');
	}

# Auxiliary files use the preferred file pool, else the conventional default
# pool, else the first file pool by name; libvirt's listing order is arbitrary.
{
	package AuxiliaryPool;

	# get_uuid_string(self) returns the fixture pool ID.
	sub get_uuid_string
	{
	$_[0]->{uuid}
	}

	# get_name(self) returns the fixture pool name.
	sub get_name
	{
	$_[0]->{name}
	}

	# is_active(self) marks inactive fixtures ineligible.
	sub is_active
	{
	!$_[0]->{inactive}
	}

	# get_xml_description(self, [flags]) identifies the fixture backend.
	sub get_xml_description
	{
	'<pool type="'.($_[0]->{type} ||
			'dir').'"><name>'.$_[0]->{name}.'</name></pool>'
	}
	package AuxiliaryConnection;

	# list_all_storage_pools(self, [flags]) returns fixtures
	# in an unsorted order.
	sub list_all_storage_pools
	{
	@{$_[0]->{pools}}
	}
	package main;
	my @pools = map { bless($_, 'AuxiliaryPool') } (
		{ uuid => 'zeta', name => 'zeta' },
		{ uuid => 'off', name => 'aaa', inactive => 1 },
		{ uuid => 'default', name => 'default' },
		{ uuid => 'alpha', name => 'alpha' },
		{ uuid => 'scsi', name => 'abc', type => 'scsi' } );
	my $adapter =
		Cloudmin::Libvirt->new(connection_factory =>
					       sub { bless({ pools => \@pools },
							   'AuxiliaryConnection') });
	is($adapter->file_pool('alpha')->get_name(), 'alpha',
	   'preferred file pool is used');
	is($adapter->file_pool('scsi')->get_name(), 'default',
	   'default pool replaces a non-file preference');
	is($adapter->file_pool('off')->get_name(), 'default',
	   'inactive preference falls back to default');
	@pools = grep { $_->{name} ne 'default' } @pools;
	is($adapter->file_pool('')->get_name(), 'alpha',
	   'first file pool by name is used without a default pool');
	@pools = grep { $_->{type} || $_->{inactive} } @pools;
	ok(!eval { $adapter->file_pool(''); 1 },
	   'no active file pool is an error');
	like($@, qr/file storage pool/, 'missing file pool is explained');
	}

# Native disk growth must not reach QEMU's file-only live resize operation.
require "$Bin/../lib/Cloudmin/VMManage.pm";
for my $block ( 0, 1 ) {
	my $plan =
		{ operation => 'grow_disk', before_xml =>
						    '<domain><vcpu>1</vcpu><memory unit="KiB">1048576</memory><devices/></domain>',
		  target => 'vda', bytes => 2048, volume =>
							  { capacity => 1024,
							    block => $block } };
	Cloudmin::VMManage::prepare_hotplug($plan);
	if ($block) {
		# LVM growth needs stopped I/O while the host
		# allocates and zeroes bytes.
		like($plan->{'offline_reason'}, qr/Shut down.*LVM/,
		     'LVM growth requires stopped guest before mutation');
		}
	else {
		# File disks retain the existing QEMU live-resize path.
		ok(!$plan->{'offline_reason'},
		   'ordinary file growth retains live resize support');
		}
	}

done_testing();
