use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib", "$Bin/../lib";
use CloudminTest;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cloudmin::Storage;
use Cloudmin::Images;

{
	package VolumePool;

	# get_name(self) supplies the fixture pool label.
	sub get_name
	{
	$_[0]->{'name'}
	}

	# get_uuid_string(self) identifies the fixture pool.
	sub get_uuid_string
	{
	$_[0]->{'uuid'}
	}

	# is_active(self) models whether native pool operations are available.
	sub is_active
	{
	!$_[0]->{'inactive'}
	}

	# is_persistent(self) distinguishes saved and transient pools.
	sub is_persistent
	{
	!$_[0]->{'transient'}
	}

	# get_autostart(self) supplies the simulated start-at-boot setting.
	sub get_autostart
	{
	0
	}

	# get_info(self) supplies fixed capacity counters for inventory tests.
	sub get_info
	{
	{ state => 2, capacity => 1024, allocation => 512,
	  available => 512 }
	}

	# get_xml_description(self, [flags]) supplies pool type and location.
	sub get_xml_description
	{
	"<pool type='".($_[0]->{'type'} ||
			'dir').
		"'><name>$_[0]->{name}</name><source><name>guests-vg</name></source><target><path>$_[0]->{path}</path></target></pool>"
	}

	# list_all_volumes(self, [flags]) supplies volumes or
	# an inventory failure.
	sub list_all_volumes
	{
	die "volume list failed\n"
		if $_[0]->{'error'}; @{$_[0]->{'volumes'} || [ ]}
	}

	# refresh(self, [flags]) records inventory refresh requests.
	sub refresh
	{
	$_[0]->{'refreshes'}++
	}

	# undefine(self) proves registration removal holds the host lock.
	sub undefine
	{
	die "host lock missing\n"
		if !$_[0]->{jobs}->{locked}; die "undefine failed\n"
			if $_[0]->{fail_undefine}; $_[0]->{undefined}++;
	}

	# destroy(self) records a stop only under the shared host lock.
	sub destroy
	{
	die "host lock missing\n" if !$_[0]->{jobs}->{locked};
	die "device busy\n" if $_[0]->{fail_stop};
	$_[0]->{stops}++; $_[0]->{inactive} = 1;
	}
	package TestVolume;

	# get_name(self) identifies the volume within its pool.
	sub get_name
	{
	$_[0]->{'name'}
	}

	# get_path(self) supplies a local file or injects an
	# identity-read failure.
	sub get_path
	{
	die "volume path unavailable\n"
		if $_[0]->{'fail_path'}; $_[0]->{'path'}
	}

	# get_key(self) uses the fixture path as its native volume key.
	sub get_key
	{
	$_[0]->{'path'}
	}

	# get_info(self) supplies fixed capacity counters.
	sub get_info
	{
	{ type => 0, capacity => 1024, allocation => 512 }
	}

	# get_xml_description(self, [flags]) models backing paths and metadata.
	sub get_xml_description
	{
	my ($self) = @_;
	return "<volume><name>$self->{name}</name><capacity>1024</capacity><allocation>".
	       ($self->{'allocated'} ||
		512)."</allocation><target><path>$self->{path}</path>".
	       ($self->{'metadata'} || '').'</target>'.
	       ($self->{'backing'}
		       ? "<backingStore><path>$self->{backing}</path></backingStore>"
		       : '').'</volume>';
	}

	# delete(self, [flags]) requires the simulated host
	# lock before unlinking.
	sub delete
	{
	die "host lock missing\n" if !$_[0]->{'jobs'}->{'locked'};
	die "native deletion failed\n" if $_[0]->{'fail_delete'};
	unlink($_[0]->{'path'}) or die $!;
	$_[0]->{'deleted'}++;
	}
	package VolumeDomain;

	# get_name(self) labels the guest owning a fixture volume.
	sub get_name
	{
	'fixture VM'
	}

	# get_uuid_string(self) deduplicates live and saved guest references.
	sub get_uuid_string
	{
	'vm-uuid'
	}

	# is_active(self) models running and stopped owners.
	sub is_active
	{
	$_[0]->{'active'} || 0
	}

	# is_persistent(self) makes inactive guest XML available.
	sub is_persistent
	{
	1
	}

	# get_xml_description(self, flags) selects live or inactive guest XML.
	sub get_xml_description
	{
	$_[1] == 2
		? ($_[0]->{'inactive_xml'} || $_[0]->{'xml'})
		: $_[0]->{'xml'}
	}

	# has_managed_save_image(self) reports the configured
	# saved-memory fixture.
	sub has_managed_save_image
	{
	!!$_[0]->{'saved'}
	}

	# managed_save_get_xml_description(self, [flags]) exposes
	# saved disk references.
	sub managed_save_get_xml_description
	{
	$_[0]->{'saved'}
	}

	# list_all_snapshots(self, [flags]) supplies
	# snapshot reference fixtures.
	sub list_all_snapshots
	{
	@{$_[0]->{'snapshots'} || [ ]}
	}

	# list_all_checkpoints(self, [flags]) supplies
	# checkpoint reference fixtures.
	sub list_all_checkpoints
	{
	@{$_[0]->{'checkpoints'} || [ ]}
	}
	package VolumeSnapshot;

	# get_xml_description(self, [flags]) supplies saved volume references.
	sub get_xml_description
	{
	$_[0]->{'xml'}
	}
	package VolumeConnection;

	# list_all_domains(self, [flags]) supplies guests for reference checks.
	sub list_all_domains
	{
	die "domain inventory failed\n"
		if $_[0]->{'error'}; @{$_[0]->{'domains'} || [ ]}
	}

	# list_all_storage_pools(self, [flags]) supplies the fixture pool list.
	sub list_all_storage_pools
	{
	@{$_[0]->{'pools'}}
	}

	# get_storage_pool_by_uuid(self, uuid) resolves the fixture pool.
	sub get_storage_pool_by_uuid
	{
	(
		grep { $_->{'uuid'} eq $_[1] } @{$_[0]->{'pools'}})[0] ||
		die 'missing pool'
	}
	package VolumeLVM;
	our @ISA = ('Cloudmin::LVM');

	# inventory(self, [refresh]) exposes fixture VG metadata
	# without host commands.
	sub inventory
	{
	die "LVM metadata unavailable\n"
		if $_[0]->{error}; $_[0]->{groups}
	}

	# group_host_use(self, group) models host-only users and
	# records fresh checks.
	sub group_host_use
	{
	$_[0]->{checks}++; die "mounted on the host\n"
		if $_[0]->{host_busy}; 1
	}
	package VolumeJobs;

	# lock(self, name, callback) records entry and runs
	# the guarded callback.
	sub lock
	{
	local $_[0]->{'locked'} = 1; $_[2]->()
	}

	# list(self, [owner], [active]) supplies jobs that can
	# block storage changes.
	sub list
	{
	$_[0]->{'active'} || [ ]
	}
	package VolumeImages;

	# list(self, [owner], [active], [strict]) supplies
	# import ownership records.
	sub list
	{
	die "image record unreadable\n"
		if $_[0]->{'error'}; $_[0]->{'records'} || [ ]
	}

	# path(self, id) supplies a fixed filename for
	# mocked import-lock checks.
	sub path
	{
	'/fixture/image.json'
	}
	}
my $tmp = tempdir('/tmp/cloudmin-volumes-unit-XXXXXX', CLEANUP => 1);
my $jobs = bless({ }, 'VolumeJobs');
my $images = bless({ test_lock => sub { 0 } }, 'VolumeImages');
my $disk =
	bless({ name => 'disk.raw', path => "$tmp/disk.raw", jobs => $jobs },
	      'TestVolume');
my $pool =
	bless({ name => 'fixture',
		uuid => '11111111-2222-3333-4444-555555555555',
		path => $tmp, volumes => [ $disk ] }, 'VolumePool');
my $conn = bless({ pools => [ $pool ] }, 'VolumeConnection');
my $adapter = Cloudmin::Libvirt->new(connection_factory => sub { $conn });
my $service =
	Cloudmin::Storage->new(adapter => $adapter, jobs => $jobs, images =>
									   $images);
no warnings 'redefine';
local *Cloudmin::Libvirt::log_call = sub { };
open(my $file, '>', $disk->{'path'}) or
	die $!; print $file 'keep me'; close($file);
my $uuid = $pool->{'uuid'};
my (undef, undef, $review) = $service->inspect_volume($uuid, 'disk.raw');
ok($review->{'revision'},
   'unused file gets a deletion review bound to its identity');
ok(!$disk->{'deleted'} && -f $disk->{'path'}, 'review does not remove data');
{
	local $disk->{'allocated'} = 1000;
	is(Cloudmin::Storage::volume_revision($pool, $disk),
	   $review->{'revision'},
	   'allocation counters do not identify the file');
	local $disk->{'metadata'} =
		'<compat>1.1</compat><clusterSize>65536</clusterSize><timestamps><atime>1234</atime></timestamps>';
	is(Cloudmin::Storage::volume_revision($pool, $disk),
	   $review->{'revision'},
	   'metadata discovered by refresh does not invalidate confirmation');
	}
ok(!eval { $service->delete_volume($uuid, 'disk.raw', $review->{'revision'},
				   0); 1 }, 'explicit confirmation required');
ok(!eval { $service->delete_volume($uuid, 'disk.raw', 'stale', 1); 1 },
   'stale confirmation rejected');

# All live and saved domain representations protect references, including seeds.
my $domain = bless({ xml => '<domain><devices/></domain>' }, 'VolumeDomain');
$conn->{'domains'} = [ $domain ];
my $source =
	"<domain><devices><disk><source file='$disk->{path}'/></disk></devices></domain>";
for my $case (
	[ xml => $source, 'stopped VM disk' ],
	[ inactive_xml => $source, 'persistent disk not present in live XML' ],
	[ saved => $source, 'managed save disk' ],
	[ snapshots =>
		  [ bless({ xml => "<domainsnapshot>$source</domainsnapshot>" },
			  'VolumeSnapshot') ], 'snapshot disk' ],
	[ checkpoints =>
		  [ bless({ xml => "<domaincheckpoint>$source</domaincheckpoint>" },
			  'VolumeSnapshot') ], 'checkpoint disk' ],
	[ xml => "<domain><os><nvram>$disk->{path}</nvram></os></domain>",
	  'NVRAM file' ],
	[ xml => "<domain><os><kernel>$disk->{path}</kernel></os></domain>",
	  'boot kernel' ],
	[ snapshots =>
		  [ bless({ xml =>
				    "<domainsnapshot><memory file='$disk->{path}'/></domainsnapshot>" },
			  'VolumeSnapshot') ], 'snapshot memory file' ],
	[ xml =>
		  "<domain><devices><disk><source pool='fixture' volume='disk.raw'/></disk></devices></domain>", 'named pool volume' ],
) {
	local $domain->{$case->[0]} = $case->[1];
	ok(!eval { $service->delete_volume($uuid, 'disk.raw',
					   $review->{'revision'}, 1); 1 },
	   "$case->[2] prevents deletion after review");
	like($@, qr/owned or referenced/, 'refusal explains ownership');
	}
{
	local $domain->{'xml'} = $source;
	for my $active ( 0, 1 ) {
		local $domain->{'active'} = $active;
		my $usage = $service->inventory()->{'pools'}->[0]
			    ->{'volumes'}->[0]->{'usage'};
		is($usage->{'owners'}->[0]->{'active'}, $active,
		   'inventory identifies stopped and running VM owners');
		is(scalar(@{$usage->{'owners'}}), 1,
		   'live and saved definitions do not duplicate the same owner');
		}
	}

# Backing references can be relative, symlinked or hard-linked to the same data.
my $child =
	bless({ name => 'child.qcow2', path => "$tmp/child.qcow2", backing =>
									   'disk.raw' }, 'TestVolume');
{
	local $pool->{'volumes'} = [ $disk, $child ];
	ok(!eval { $service->delete_volume($uuid, 'disk.raw',
					   $review->{'revision'}, 1); 1 },
	   'relative backing disk is protected');
	# Sorting puts child before disk; resolve by name
	# rather than row position.
	my ($usage) =
		map { $_->{'usage'} } grep { $_->{'name'} eq 'disk.raw' } @{
			$service->inventory()->{'pools'}->[0]->{'volumes'}};
	is($usage->{'owners'}->[0]->{'kind'}, 'backing',
	   'backing dependency identified');
	}
symlink($disk->{'path'}, "$tmp/alias") or die $!;
link($disk->{'path'}, "$tmp/hardlink") or die $!;
link($disk->{'path'}, "$tmp/space at end ") or die $!;
for my $alias ( "$tmp/alias", "$tmp/hardlink", "$tmp/space at end " ) {
	local $domain->{'xml'} =
		"<domain><devices><disk><source file='$alias'/></disk></devices></domain>";
	ok(!eval { $service->delete_volume($uuid, 'disk.raw',
					   $review->{'revision'}, 1); 1 },
	   'aliased attachment protects original volume');
	}
unlink("$tmp/alias", "$tmp/hardlink", "$tmp/space at end ");

# Imports retain ownership even after failure, and active work blocks cleanup.
for my $image (
	{ pool => $uuid, volume => 'disk.raw' },
	{ volume_path => $disk->{'path'} },
	{ volume_key => $disk->{'path'} }
) {
	local $images->{'records'} =
		[ { %$image, id => 'image-id', name => 'source image', state =>
			'failed' } ];
	ok(!eval { $service->delete_volume($uuid, 'disk.raw',
					   $review->{'revision'}, 1); 1 },
	   'import ownership prevents raw deletion');
	}
{
	local $jobs->{'active'} = [ { } ];
	ok(!eval { $service->delete_volume($uuid, 'disk.raw',
					   $review->{'revision'}, 1); 1 },
	   'queued VM operation prevents deletion');
	like($@, qr/Wait for/, 'pending work explained');
	}
{
	local $images->{'records'} = [ { id => 'pending', state => 'queued' } ];
	ok(!eval { $service->delete_volume($uuid, 'disk.raw',
					   $review->{'revision'}, 1); 1 },
	   'pending import prevents deletion');
	}
{
	local $images->{'records'} = [ { id => 'locked', state => 'ready' } ];
	local $images->{'test_lock'} = sub { 1 };
	ok(!eval { $service->delete_volume($uuid, 'disk.raw',
					   $review->{'revision'}, 1); 1 },
	   'locked import prevents deletion');
	}

# Unknown dependencies must never be treated as an unused volume.
for my $fixture ( $conn, $pool, $images ) {
	local $fixture->{'error'} = 1;
	ok(!eval { $service->delete_volume($uuid, 'disk.raw',
					   $review->{'revision'}, 1); 1 },
	   'unreadable ownership prevents deletion');
	like($@, qr/Cannot check|volume list failed/,
	     'incomplete usage is explicit');
	}
{
	local $conn->{'pools'} =
		[ $pool,
		  bless({ name => 'offline', uuid => 'other',
			  inactive => 1 },
			'VolumePool') ];
	ok(!eval { $service->delete_volume($uuid, 'disk.raw',
					   $review->{'revision'}, 1); 1 },
	   'inactive pool cannot hide a backing dependency');
	like($@, qr/Start storage pool offline/,
	     'inactive dependency check explains next step');
	}
for my $case ( [ type => 'fs' ], [ transient => 1 ], [ inactive => 1 ] ) {
	local $pool->{$case->[0]} = $case->[1];
	ok(!eval { $service->delete_volume($uuid, 'disk.raw',
					   $review->{'revision'}, 1); 1 },
	   'unsupported pool cannot remove volumes');
	}
{
	local $adapter->{'uri'} = 'qemu+ssh://example/system';
	local *Cloudmin::Storage::same_file =
		sub { die 'remote paths were inspected' if $_[2]; return 0; };
	ok(!$service->inventory()->{'pools'}->[0]->{'manageable'},
	   'remote inventory remains read-only');
	ok(!eval { $service->delete_volume($uuid, 'disk.raw',
					   $review->{'revision'}, 1); 1 },
	   'remote deletion refused');
	}
{
	local $disk->{'fail_delete'} = 1;
	my (undef, undef, $fresh) = $service->inspect_volume($uuid,
							     'disk.raw');
	ok(!eval { $service->delete_volume($uuid, 'disk.raw',
					   $fresh->{'revision'}, 1); 1 },
	   'native deletion failure propagated');
	like($@, qr/native deletion failed/,
	     'original deletion error preserved');
	}
ok(-f $disk->{'path'} && !$disk->{'deleted'}, 'all refusals preserve the file');
{
	local $disk->{'fail_path'} = 1;
	ok(!eval { $service->inspect_volume($uuid, 'disk.raw'); 1 },
	   'partial native identity cannot hide a file reference');
	like($@, qr/volume path unavailable/, 'identity failure is propagated');
	}

# A replacement that reuses the name and key must not inherit confirmation.
rename($disk->{'path'}, "$tmp/original.raw") or die $!;
open($file, '>', $disk->{'path'}) or
	die $!; print $file 'replacement'; close($file);
ok(!eval { $service->delete_volume($uuid, 'disk.raw', $review->{'revision'},
				   1); 1 }, 'same-name replacement rejected');
like($@, qr/volume changed/, 'replacement requires a fresh review');
unlink($disk->{'path'});
symlink("$tmp/original.raw", $disk->{'path'}) or die $!;
ok(!eval { $service->inspect_volume($uuid, 'disk.raw'); 1 },
   'symlink is not a deletable regular volume');
unlink($disk->{'path'});
rename("$tmp/original.raw", $disk->{'path'}) or die $!;
(undef, undef, $review) = $service->inspect_volume($uuid, 'disk.raw');
is($service->delete_volume($uuid, 'disk.raw', $review->{'revision'},
			   1)->{'name'}, 'disk.raw',
   'unused volume deleted after fresh review');
ok(!-e $disk->{'path'} && $disk->{'deleted'}, 'exact reviewed file removed');
ok(!$jobs->{'locked'}, 'host lock released after deletion');

# The shared image reader retains permissive UI reads but
# supports strict guards.
make_path("$tmp/images");
my $store = Cloudmin::Images->new(directory => "$tmp/images");
open($file, '>', "$tmp/images/".('a' x 32).'.json') or
	die $!; print $file 'corrupt'; close($file);
is_deeply($store->list(), [ ],
	  'ordinary image inventory retains existing behavior');
ok(!eval { $store->list(undef, undef, 1); 1 },
   'strict image ownership read reports corruption');
{
	local $store->{'directory'} = "$tmp/images/".('a' x 32).'.json';
	ok(!eval { $store->list(undef, undef, 1); 1 },
	   'damaged image job directory cannot imply no owners');
	}

# Thin destinations list native logical volumes under a derived pool ID. The
# native record is not an owner, but a snapshot still protects its origin.
{
	my $context = { references => [
		{ kind => 'backing', pool => 'native-uuid', name =>
								    'guest',
		  path => '/dev/vg/guest', paths =>
						   [ '/dev/vg/guest' ],
		  sources => [ ] },
		{ kind => 'backing', pool => 'native-uuid', name =>
								    'saved',
		  path => '/dev/vg/saved', paths =>
						   [ '/dev/vg/saved',
						     '/dev/vg/guest' ],
		  sources => [ ] },
	], images => [ ], errors => [ ], busy => 0 };
	my $thin =
		{ uuid => 'derived-uuid', name => 'vg/thin',
		  volume_manageable => 1 };
	my $usage =
		$service->volume_usage($thin,
				       { name => 'saved', key => 'lvm:vg:saved',
					 path => '/dev/vg/saved' },
				       $context);
	is_deeply($usage->{'owners'}, [ ],
		  'a native record of the same logical volume is not an owner');
	is($usage->{'reason'}, '', 'unused thin volume can be deleted');
	$usage =
		$service->volume_usage($thin,
				       { name => 'guest', key => 'lvm:vg:guest',
					 path => '/dev/vg/guest' },
				       $context);
	is(scalar(@{$usage->{'owners'}}), 1,
	   'a snapshot volume still protects its origin');
	$usage =
		$service->volume_usage($thin,
				       { name => 'guest',
					 key => '/dev/vg/guest',
					 path => '/dev/vg/guest' },
				       { %$context,
					 references => [ $context->{'references'}->[0] ] });
	is(scalar(@{$usage->{'owners'}}), 1,
	   'file volumes are matched only by their own pool ID');
	}

# A same-named disk in another pool can depend on an LV. Its backing path must
# not be mistaken for the LV's own native inventory entry.
{
	my $dependent =
		bless({ name => $disk->{'name'}, path => "$tmp/other/disk.raw",
			backing => $disk->{'path'} }, 'TestVolume');
	my $other =
		bless({ name => 'other', uuid => 'other-uuid',
			path => "$tmp/other",
			volumes => [ $dependent ] }, 'VolumePool');
	local $conn->{'pools'} = [ $pool, $other ];
	my $usage = $service->volume_usage(
		{ uuid => 'derived-uuid', name => 'vg/thin',
		  volume_manageable =>
			  1 },
		{ name => $disk->{'name'}, key => 'lvm:vg:disk', path =>
									 $disk->{'path'} },
		$service->volume_context());
	is(scalar(@{$usage->{'owners'}}), 1,
	   'same-named dependent disk prevents LV deletion');
	is($usage->{'owners'}->[0]->{'pool'}, 'other-uuid',
	   'dependency belongs to the other pool');
	}
# Reviews report owners without allowing deletion of an owned volume.
{
	open(my $keep, '>', $disk->{path}) or
		die $!; print $keep 'preserve'; close($keep);
	local $conn->{domains} = [ $domain ];
	local $domain->{xml} = $source;
	my (undef, undef, $blocked) =
		$service->review_volume($uuid, 'disk.raw');
	is($blocked->{usage}->{owners}->[0]->{kind}, 'vm',
	   'review reports stopped guest owner');
	ok(!$blocked->{revision}, 'blocked review grants no deletion revision');
	}
# Pool removal checks all persistent references, even with the pool inactive.
{
	local $pool->{inactive} = 1;
	local $pool->{jobs} = $jobs;
	local $conn->{domains} = [ ];
	my (undef, $plan) = $service->review_pool($uuid);
	is($plan->{usage}->{reason}, '',
	   'inactive unused pool can be unregistered');
	# Any saved guest definition can keep a stopped pool in use.
	for my $case ( [ xml => $source ], [ inactive_xml => $source ],
		       [ saved => $source ],
		       [ snapshots => [ bless({ xml => $source },
					      'VolumeSnapshot') ] ],
		       [ checkpoints => [ bless({ xml => $source },
						'VolumeSnapshot') ] ] ) {
		local $conn->{domains} = [ $domain ];
		local $domain->{$case->[0]} = $case->[1];
		ok(!eval { $service->unregister($uuid, $plan->{revision},
						1); 1 },
		   "$case->[0] protects pool registration");
		like($@, qr/still referenced/,
		     'pool refusal explains reference');
		}
	# Imported images retain their registration even without a guest owner.
	{
		local $images->{records} =
			[ { id => 'image', pool => $uuid, state => 'ready' } ];
		ok(!eval { $service->unregister($uuid, $plan->{revision},
						1); 1 },
		   'import protects inactive pool');
		}
	# An unfinished job may acquire a volume after the review.
	{
		local $jobs->{active} = [ { } ];
		ok(!eval { $service->unregister($uuid, $plan->{revision},
						1); 1 },
		   'pending job protects pool');
		}
	# Failed ownership discovery must not look like an unused pool.
	{
		local $images->{error} = 1;
		ok(!eval { $service->unregister($uuid, $plan->{revision},
						1); 1 },
		   'unknown imports fail closed');
		}
	# A dependent disk in another pool keeps its backing pool registered.
	{
		my $dependent =
			bless({ name => 'child',
				path => "$tmp/elsewhere/child",
				backing => $disk->{path} }, 'TestVolume');
		my $other =
			bless({ name => 'other', uuid => 'other-id',
				volumes =>
					[ $dependent ] }, 'VolumePool');
		local $conn->{pools} = [ $pool, $other ];
		ok(!eval { $service->unregister($uuid, $plan->{revision},
						1); 1 },
		   'another pool backing chain protects registration');
		}
	# Confirmation cannot substitute for a current review, or vice versa.
	ok(!eval { $service->unregister($uuid, 'stale', 1); 1 },
	   'stale unregister revision rejected');
	ok(!eval { $service->unregister($uuid, $plan->{revision}, 0); 1 },
	   'unregister requires confirmation');
	# Plain unregistration never implies permission to stop an active pool.
	{
		local $pool->{inactive} = 0;
		my (undef, $active) = $service->review_pool($uuid);
		like($active->{usage}->{reason}, qr/--stop/,
		     'active pool needs explicit stop permission');
		ok(!eval { $service->unregister($uuid, $active->{revision},
						1); 1 },
		   'active pool is not deactivated');
		}
	# Removing an unused registration leaves its volume file intact.
	is($service->unregister($uuid, $plan->{revision}, 1)->{name}, 'fixture',
	   'inactive registration removed');
	ok($pool->{undefined} && -f $disk->{path},
	   'unregister preserves disk data');
	}
# Inactive LVM registrations still protect thin destinations and device aliases.
{
	local $pool->{type} = 'logical';
	local $pool->{path} = '/dev/guests-vg';
	local $pool->{inactive} = 1;
	local $pool->{jobs} = $jobs;
	local $conn->{domains} = [ ];
	my $lv =
		{ lv_name => 'disk-one', lv_path => '/dev/guests-vg/disk-one',
		  segtype => 'thin' };
	my $thin =
		{ lv_name => 'thin', lv_uuid => 'thin-uuid',
		  segtype => 'thin-pool' };
	my $driver =
		bless({ groups =>
				{ 'guests-vg' => { vg_name => 'guests-vg',
						   vg_uuid => 'vg-id',
						   volumes => { 'disk-one' => $lv,
								thin => $thin } } } },
		      'VolumeLVM');
	local $adapter->{lvm} = $driver;
	my (undef, $plan) = $service->review_pool($uuid);
	is($plan->{usage}->{reason}, '',
	   'unused inactive LVM registration can be removed');
	# Native paths, mapper aliases and derived pool IDs
	# identify the same LV.
	my $thin_id = Cloudmin::LVM::thin_id($uuid, 'thin-uuid');
	for my $source ( "dev='/dev/guests-vg/disk-one'",
			 "dev='/dev/mapper/guests--vg-disk--one'",
			 "pool='fixture/thin' volume='disk-one'",
			 "pool='$thin_id' volume='disk-one'" ) {
		local $conn->{domains} = [ $domain ];
		local $domain->{xml} =
			"<domain><devices><disk><source $source/></disk></devices></domain>";
		my (undef, $blocked) = $service->review_pool($uuid);
		like($blocked->{usage}->{reason}, qr/still referenced/,
		     'thin disk reference protects parent registration');
		}
	# Images assigned to a derived thin destination protect the parent pool.
	{
		local $images->{records} =
			[ { id => 'thin-image', pool => $thin_id,
			    state => 'ready' } ];
		ok(!eval { $service->unregister($uuid, $plan->{revision},
						1); 1 },
		   'thin import protects parent registration');
		}
	# Cloudmin snapshots need the group registration to remain discoverable.
	{
		local $lv->{lv_tags} = 'cloudmin_snapshot';
		my (undef, $blocked) = $service->review_pool($uuid);
		like($blocked->{usage}->{reason},
		     qr/Remove Cloudmin snapshots/,
		     'native snapshot prevents unregistering its VG');
		}
	# Unreadable metadata cannot establish that a group is unused.
	{
		local $driver->{error} = 1;
		ok(!eval { $service->unregister($uuid, $plan->{revision},
						1); 1 },
		   'unreadable LVM metadata fails closed');
		}
	# A stop-enabled review grants only its explicit, unchanged stop choice.
	{
		local $pool->{inactive} = 0;
		my (undef, $blocked) = $service->review_pool($uuid);
		like($blocked->{usage}->{reason}, qr/--stop/,
		     'active LVM refusal explains the stop option');
		ok(!eval { $service->unregister($uuid, $blocked->{revision},
						1); 1 },
		   'unregister without stop permission leaves the group active');
		my (undef, $active) = $service->review_pool($uuid, 1);
		is($active->{usage}->{reason}, '',
		   'unused active group permits reviewed stop and removal');
		ok($active->{stop_required},
		   'review identifies whole-group stop');
		ok(!eval { $service->unregister($uuid, $blocked->{revision},
						1,
						1); 1 },
		   'stop permission is bound to the review');
		# Stop permission cannot override a guest
		# reference added after review.
		{
			local $conn->{domains} = [ $domain ];
			local $domain->{xml} =
				"<domain><devices><disk><source dev='/dev/guests-vg/disk-one'/></disk></devices></domain>";
			ok(!eval { $service->unregister($uuid,
							$active->{revision}, 1,
							1); 1 },
			   'explicit stop still refuses a stopped guest reference');
			like($@, qr/still referenced/,
			     'combined operation explains the dependency');
			}
		# Recheck host users at submission, not just at review time.
		{
			local $driver->{host_busy} = 1;
			my (undef, $busy) = $service->review_pool($uuid,
								  1);
			like($busy->{usage}->{reason},
			     qr/mounted on the host/,
			     'host-only use blocks the review');
			ok(!eval { $service->unregister($uuid,
							$active->{revision}, 1,
							1); 1 },
			   'host use added after review is refused');
			}
		# A new LV changes the group identity bound into the revision.
		{
			local $driver->{groups}->{'guests-vg'}->{volumes}->{new} = { lv_uuid => 'new-lv', lv_name => 'new', segtype => 'linear' };
			ok(!eval { $service->unregister($uuid,
							$active->{revision}, 1,
							1); 1 },
			   'added LV invalidates reviewed group');
			like($@, qr/settings changed/,
			     'changed group requires another review');
			}
		# A failed stop must preserve the registration
		# and the native error.
		{
			local $pool->{fail_stop} = 1;
			ok(!eval { $service->unregister($uuid,
							$active->{revision}, 1,
							1); 1 },
			   'native stop failure prevents unregistration');
			like($@, qr/registration was kept.*device busy/,
			     'stop failure preserves its diagnostic');
			ok($pool->is_active(),
			   'failed stop leaves the pool registered and active');
			}
		# If only undefine fails, report that the stop
		# already took effect.
		{
			local $pool->{fail_undefine} = 1;
			ok(!eval { $service->unregister($uuid,
							$active->{revision}, 1,
							1); 1 },
			   'partial failure is not reported as success');
			like($@, qr/pool is stopped.*Review and retry/,
			     'partial failure explains recovery');
			ok(!$pool->is_active(),
			   'successful stop is retained after undefine failure');
			$pool->{inactive} = 0;
			}
		# With no intervening users or metadata
		# changes, both steps succeed.
		is($service->unregister($uuid, $active->{revision}, 1,
					1)->{type}, 'logical',
		   'explicit stop and unregistration succeed');
		ok(!$pool->is_active(),
		   'confirmed removal stops the native pool');
		ok($driver->{checks} >= 4,
		   'host usage is rechecked at submission');
		}
	# Both entry points explain derived IDs without removing their parent.
	my $removed = $pool->{undefined};
	for my $inactive ( 0, 1 ) {
		local $pool->{inactive} = $inactive;
		ok(!eval { $service->review_pool($thin_id); 1 },
		   'thin destination review is refused');
		is($@,
		   "LVM-thin destinations cannot be unregistered separately. Unregister the parent LVM pool instead.\n",
		   'thin destination error directs the caller to the parent pool');
		ok(!eval { $service->unregister($thin_id, $plan->{revision},
						1); 1 },
		   'direct thin unregistration is refused');
		like($@, qr/Unregister the parent LVM pool instead/,
		     'direct removal gives the same guidance');
		}
	is($pool->{undefined}, $removed,
	   'thin destination refusals preserve the parent registration');
	ok(
		!eval { $service->review_pool(
			'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'); 1 },
		'unknown pool still fails');
	like($@, qr/^missing pool/,
	     'unknown ID keeps its original lookup error');
	# Failed derived-pool discovery must preserve the original lookup error.
	{
		local $driver->{error} = 1;
		ok(!eval { $service->review_pool($thin_id); 1 },
		   'unreadable thin metadata still refuses removal');
		like($@, qr/^missing pool/,
		     'failed discovery does not replace the original lookup error');
		}
	# A verified missing VG permits removal of an inactive definition only.
	{
		my $group = $driver->{groups}->{'guests-vg'};
		local $driver->{groups} = { };
		local $pool->{undefined} = 0;
		local $pool->{stops} = 0;
		my (undef, $missing) = $service->review_pool($uuid);
		is($missing->{usage}->{reason}, '',
		   'missing VG permits inactive registration review');
		ok($missing->{usage}->{checked} &&
		   !$missing->{stop_required},
		   'missing VG review needs no stop');
		ok(!eval { $service->unregister($uuid, $plan->{revision},
						1); 1 },
		   'disappeared VG invalidates an older review');
		like($@, qr/settings changed/,
		     'missing VG requires its own review');
		# Reappearing metadata also invalidates a
		# review made while absent.
		{
			local $driver->{groups} =
				{ 'guests-vg' => $group };
			ok(!eval { $service->unregister($uuid,
							$missing->{revision},
							1); 1 },
			   'reappearing VG invalidates stale removal review');
			like($@, qr/settings changed/,
			     'reappearing group requires another review');
			}
		# Both LVM aliases and named references remain
		# meaningful without nodes.
		for my $source ( "dev='/dev/guests-vg/disk-one'",
				 "dev='/dev/mapper/guests--vg-disk--one'",
				 "pool='fixture' volume='disk-one'",
				 "pool='fixture/thin' volume='disk-one'" ) {
			local $conn->{domains} = [ $domain ];
			local $domain->{xml} =
				"<domain><devices><disk><source $source/></disk></devices></domain>";
			ok(!eval { $service->unregister($uuid,
							$missing->{revision},
							1); 1 },
			   'missing VG still protects stopped guest references');
			like($@, qr/still referenced/,
			     'missing VG reports its remaining references');
			}
		# Saved state still needs its original disk
		# even without live nodes.
		{
			local $conn->{domains} = [ $domain ];
			local $domain->{saved} =
				"<domain><devices><disk><source dev='/dev/mapper/guests--vg-disk--one'/></disk></devices></domain>";
			ok(!eval { $service->unregister($uuid,
							$missing->{revision},
							1); 1 },
			   'saved-state alias protects a missing VG');
			like($@, qr/still referenced/,
			     'saved-state refusal explains the dependency');
			}
		# The import's path identifies its group when the
		# thin ID cannot resolve.
		{
			local $images->{records} =
				[ { id => 'thin-image', pool => $thin_id,
				    state =>
					    'ready',
				    volume_path => '/dev/mapper/guests--vg-disk--one' } ];
			ok(!eval { $service->unregister($uuid,
							$missing->{revision},
							1); 1 },
			   'thin import path protects a missing VG');
			like($@, qr/still referenced/,
			     'thin import refusal explains the dependency');
			}
		# Backing paths remain dependencies after
		# device nodes disappear.
		{
			my $dependent =
				bless({ name => 'child', path =>
								 "$tmp/elsewhere/child",
					backing => '/dev/mapper/guests--vg-disk--one' }, 'TestVolume');
			my $other =
				bless({ name => 'other', uuid => 'other-id',
					volumes => [ $dependent ] },
				      'VolumePool');
			local $conn->{pools} = [ $pool, $other ];
			ok(!eval { $service->unregister($uuid,
							$missing->{revision},
							1); 1 },
			   'backing alias protects a missing VG');
			like($@, qr/still referenced/,
			     'backing refusal explains the dependency');
			}
		# Escaped hyphens in another VG name must not
		# match the LV separator.
		{
			local $conn->{domains} = [ $domain ];
			local $domain->{xml} =
				"<domain><devices><disk><source dev='/dev/mapper/guests--vg--other-disk'/></disk></devices></domain>";
			my (undef, $other) =
				$service->review_pool($uuid);
			is($other->{usage}->{reason}, '',
			   'a longer group name is not mistaken for a missing-group disk');
			}
		# The exception requires an inactive pool and a
		# successful VG lookup.
		for my $stop ( 0, 1 ) {
			# Active pools still require known metadata,
			# with or without stop.
			{
				local $pool->{inactive} = 0;
				ok(!eval { $service->review_pool($uuid, $stop);
					1 },
				   'active pool with missing metadata still fails closed');
				like($@, qr/LVM volume group is missing/,
				     'active refusal keeps the missing-group diagnostic');
				}
			# A command failure is different from a
			# verified absent group.
			{
				local $driver->{error} = 1;
				ok(!eval { $service->review_pool($uuid, $stop);
					1 },
				   'failed inventory never counts as an absent group');
				like($@, qr/LVM metadata unavailable/,
				     'inventory failure keeps its diagnostic');
				}
			# Either stop choice can remove a verified
			# inactive registration.
			my (undef, $review) =
				$service->review_pool($uuid, $stop);
			is($service->unregister($uuid, $review->{revision},
						1,
						$stop)->{type}, 'logical',
			   'inactive stale registration can be removed with either stop permission');
			}
		is($pool->{stops}, 0,
		   'removing an inactive stale registration never deactivates storage');
		is($pool->{undefined}, 2,
		   'only reviewed stale definitions were removed');
		}
	is($service->unregister($uuid, $plan->{revision}, 1)->{type}, 'logical',
	   'inactive parent registration can be removed');
	}
done_testing();
