use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib", "$Bin/../lib";
use CloudminTest;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);
use Cloudmin::Storage;

{
	package StoragePool;
	# Pool methods model libvirt state and record calls that could alter files.
	# get_name(self) supplies the fixture pool label.
	sub get_name { $_[0]->{'name'} }
	# get_uuid_string(self) identifies the fixture pool.
	sub get_uuid_string { '11111111-2222-3333-4444-555555555555' }
	# get_xml_description(self, [flags]) supplies pool type and location.
	sub get_xml_description { $_[0]->{'xml'} }
	# is_active(self) models whether native pool operations are available.
	sub is_active { $_[0]->{'active'} || 0 }
	# is_persistent(self) distinguishes saved and transient pools.
	sub is_persistent { !$_[0]->{'transient'} }
	# get_autostart(self) supplies the simulated start-at-boot setting.
	sub get_autostart { $_[0]->{'boot'} || 0 }
	# set_autostart(self, enabled) records a setting or injects a write failure.
	sub set_autostart { die "boot failure\n" if $_[0]->{'fail_boot'}; $_[0]->{'boot'} = $_[1] }
	# build(self, [flags]) records initialization without touching real storage.
	sub build { $_[0]->{'built'}++ }
	# create(self, [flags]) simulates activation or a native start failure.
	sub create { die "start failure\n" if $_[0]->{'fail_start'}; $_[0]->{'active'} = 1 }
	# destroy(self) clears simulated active state without removing files.
	sub destroy { $_[0]->{'active'} = 0 }
	# undefine(self) records rollback or injects a cleanup failure.
	sub undefine { die "cleanup failure\n" if $_[0]->{'fail_cleanup'}; $_[0]->{'undefined'}++ }
	# get_info(self) supplies fixed capacity counters for inventory tests.
	sub get_info { { state => 2, capacity => 1000, available => 600, allocation => 400 } }
	# list_all_volumes(self, [flags]) supplies volumes or an inventory failure.
	sub list_all_volumes { die "volume inventory failure\n" if $_[0]->{'fail_volumes'}; return () }
	package StorageConnection;
	# list_all_storage_pools(self, [flags]) supplies the fixture pool list.
	sub list_all_storage_pools { @{$_[0]->{'pools'} || []} }
	# list_all_domains(self, [flags]) supplies guests for reference checks.
	sub list_all_domains { @{$_[0]->{'domains'} || []} }
	# get_storage_pool_by_uuid(self, uuid) resolves the fixture pool.
	sub get_storage_pool_by_uuid { $_[0]->{'pools'}->[0] || die "pool not found\n" }
	# define_storage_pool(self, xml, [flags]) records a new fixture definition.
	sub define_storage_pool {
		my ($self, $xml) = @_;
		my $doc = Cloudmin::Libvirt::parse_xml_document($xml);
		return $self->{'created'} = bless({xml => $xml, name => $doc->findvalue('/pool/name'),
			%{$self->{'failure'} || {}}}, 'StoragePool');
		}
	package StorageJobs;
	# lock(self, name, callback) records entry and runs the guarded callback.
	sub lock { $_[0]->{'locks'}++; $_[2]->() }
	# list(self, [owner], [active]) supplies jobs that can block storage changes.
	sub list { $_[0]->{'active'} || [] }
	package StorageImages;
	# list(self, [owner], [active], [strict]) supplies import ownership records.
	sub list { $_[0]->{'records'} || [] }
	# path(self, id) supplies a fixed filename for mocked import-lock checks.
	sub path { '/fixture/job.json' }
}
my $tmp = abs_path(tempdir('/tmp/cloudmin-storage-unit-XXXXXX', CLEANUP => 1));
my $conn = bless({}, 'StorageConnection');
my $adapter = Cloudmin::Libvirt->new(connection_factory => sub { $conn });
my $jobs = bless({}, 'StorageJobs');
my $images = bless({ test_lock => sub { 0 } }, 'StorageImages');
my $service = Cloudmin::Storage->new(adapter => $adapter, jobs => $jobs, images => $images);
no warnings 'redefine';
local *Cloudmin::Libvirt::log_call = sub {};
my %input = (name => 'extra', path => "$tmp/pool", autostart => 1);

# Reject invalid destinations before defining pools or creating directories.
for my $case (
	[{name => ''}, qr/name/], [{path => ''}, qr/absolute/],
	[{name => '../escape'}, qr/name/], [{name => 'space name'}, qr/name/],
	[{path => 'relative'}, qr/absolute/], [{path => '/'}, qr/absolute|root/],
	[{path => '///'}, qr/root/], [{path => "$tmp/../pool"}, qr/components/],
	[{path => "$tmp/./pool"}, qr/components/], [{path => "$tmp/missing/pool"}, qr/parent/],
	[{path => "$tmp/pool\n"}, qr/absolute/], [{autostart => 'yes'}, qr/setting/],
) {
	ok(!eval { $service->prepare({%input, %{$case->[0]}}); 1 }, 'invalid creation rejected');
	like($@, $case->[1], 'validation explains invalid input');
}
open(my $file, '>', "$tmp/file") or die $!; print $file 'keep'; close($file);
ok(!eval { $service->prepare({%input, path => "$tmp/file"}); 1 }, 'regular file is not a directory');
symlink("$tmp/missing", "$tmp/broken") or die $!;
ok(!eval { $service->prepare({%input, path => "$tmp/broken"}); 1 }, 'dangling link rejected');
my $plan = $service->prepare({%input, path => "$tmp/a & b"});
like(Cloudmin::Libvirt::parse_xml_document($plan->{'xml'})->findvalue('/pool/uuid'),
	qr/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/, 'creation assigns an independent UUID');
is(Cloudmin::Libvirt::parse_xml_document($plan->{'xml'})->findvalue('/pool/target/path'),
	"$tmp/a & b", 'directory XML safely preserves special characters');

# Build only a new directory; never rebuild or chmod an existing one.
is($service->create(\%input), 'extra', 'new directory pool created');
my $pool = $conn->{'created'};
ok($pool->{'built'} && $pool->{'active'} && $pool->{'boot'}, 'pool built, started and saved for boot');
make_path("$tmp/existing", {mode => 0750});
is($service->create({%input, path => "$tmp/existing", autostart => 0}), 'extra', 'existing directory registered');
ok(!$conn->{'created'}->{'built'}, 'existing directory never passed to libvirt build');
is((stat("$tmp/existing"))[2] & 0777, 0750, 'existing mode preserved');
$conn->{'pools'} = [$pool];
make_path("$tmp/pool");
for my $path ("$tmp/pool", "$tmp/pool/nested", $tmp) {
	ok(!eval { $service->prepare({%input, name => 'other', path => $path}); 1 }, 'same, nested or parent directory refused');
	like($@, qr/overlaps storage pool/, 'overlap itself causes the refusal');
}
make_path("$tmp/pool"); symlink("$tmp/pool", "$tmp/alias") or die $!;
ok(!eval { $service->prepare({%input, name => 'other', path => "$tmp/alias"}); 1 }, 'symlink alias refused');
ok(!eval { $service->prepare({%input, path => "$tmp/separate"}); 1 }, 'duplicate name refused');
ok($service->prepare({%input, name => 'other', path => "$tmp/pool-other"}), 'similar path prefix is not an overlap');

# Re-read boot and activation state so stale forms cannot undo a newer action.
my $uuid = $pool->get_uuid_string();
my $revision = Cloudmin::Storage::revision($pool);
{
	local $pool->{'xml'} = $pool->{'xml'};
	$pool->{'xml'} =~ s{</pool>}{<capacity>2000</capacity><allocation>900</allocation><available>1100</available></pool>};
	is(Cloudmin::Storage::revision($pool), $revision, 'changing capacity counters do not invalidate forms');
}
is($service->change('autostart', $uuid, $revision, 0), 'extra', 'boot disabled');
ok(!$pool->{'boot'} && $pool->{'active'}, 'boot toggle does not stop pool');
ok(!eval { $service->change('stop', $uuid, $revision); 1 }, 'stale boot revision rejected');
$revision = Cloudmin::Storage::revision($pool);
for my $enabled (undef, '', 'yes', '2') {
	ok(!eval { $service->change('autostart', $uuid, $revision, $enabled); 1 }, 'invalid boot target rejected');
}
$jobs->{'active'} = [{state => 'queued'}];
ok(!eval { $service->change('stop', $uuid, $revision); 1 }, 'queued VM work protects pool');
delete $jobs->{'active'};
for my $state (qw(waiting queued downloading verifying importing)) {
	$images->{'records'} = [{id => 'fixture', pool => $uuid, state => $state}];
	ok(!eval { $service->change('stop', $uuid, $revision); 1 }, "$state image protects pool");
}
$images->{'records'} = [{id => 'fixture', pool => $uuid, state => 'ready'}];
{
	local $images->{'test_lock'} = sub { 1 };
	ok(!eval { $service->change('stop', $uuid, $revision); 1 }, 'locked image still finishing protects pool');
}

# Running guests protect both file-backed disks and named volume references.
my $vm = bless({name => 'guest', active => 1}, 'StoragePool');
$conn->{'domains'} = [$vm];
for my $source ("file='$tmp/pool/disk.raw'", "pool='extra' volume='disk.raw'") {
	$vm->{'xml'} = "<domain><devices><disk><source $source/></disk></devices></domain>";
	ok(!eval { $service->change('stop', $uuid, $revision); 1 }, 'running guest prevents stop');
	like($@, qr/Stop virtual machines/, 'running guest refusal explains next step');
}
$vm->{'active'} = 0;
is($service->change('stop', $uuid, $revision), 'extra', 'stopped guests retain files while pool stops');
ok(!$pool->{'active'} && !$pool->{'undefined'}, 'stop keeps persistent definition');
ok(!eval { $service->change('start', $uuid, $revision); 1 }, 'stale active-state revision refused');
is($service->change('start', $uuid, Cloudmin::Storage::revision($pool)), 'extra', 'pool restarts');
for my $action ('delete', 'unknown') {
	ok(!eval { $service->change($action, $uuid, Cloudmin::Storage::revision($pool)); 1 }, 'unsupported operation refused');
}
{
	local $pool->{'transient'} = 1;
	ok(!eval { $service->change('stop', $uuid, Cloudmin::Storage::revision($pool)); 1 }, 'transient pool cannot be inadvertently undefined');
}
{
	local $pool->{'xml'} = '<pool type="fs"><name>extra</name><target><path>/fixture</path></target></pool>';
	ok(!eval { $service->change('stop', $uuid, Cloudmin::Storage::revision($pool)); 1 }, 'other backends remain read-only');
}
{
	local $adapter->{'uri'} = 'qemu+ssh://host/system';
	ok(!eval { $service->create(\%input); 1 }, 'remote creation refused before local filesystem checks');
	ok(!eval { $service->change('stop', $uuid, Cloudmin::Storage::revision($pool)); 1 }, 'remote lifecycle changes refused');
	ok(!$service->inventory()->{'pools'}->[0]->{'manageable'}, 'remote pools have no controls');
}

# Preserve failed creation details and never delete data during rollback.
$conn->{'pools'} = [];
for my $failure ({fail_start => 1}, {fail_boot => 1}, {fail_start => 1, fail_cleanup => 1}) {
	$conn->{'failure'} = $failure;
	ok(!eval { $service->create({%input, path => "$tmp/new-failed"}); 1 }, 'native creation failure reported');
	like($@, qr/(?:start|boot) failure/, 'original failure retained');
	like($@, qr/directory was kept/, 'retained directory explained');
	# Rollback errors must remain visible alongside the original failure.
	if ($failure->{'fail_cleanup'}) { like($@, qr/cleanup failure/, 'rollback failure is visible'); }
	# Successful rollback removes only the newly created definition.
	else { ok($conn->{'created'}->{'undefined'} && !$conn->{'created'}->{'active'}, 'only the new pool definition rolled back'); }
}
$conn->{'pools'} = [$pool];
$pool->{'fail_volumes'} = 1;
like($service->inventory()->{'pools'}->[0]->{'volume_error'}, qr/volume inventory failure/, 'partial inventory errors retained');
ok($jobs->{'locks'} > 0, 'mutations take shared host lock');

# Shared storage is counted once; missing information never becomes a zero.
my $fs1 = {active => 1, filesystem => 'ext4:one', capacity => 1000, available => 600, volume_count => 2};
my $fs2 = {active => 1, filesystem => 'xfs:two', capacity => 2000, available => 800, volume_count => 3};
my $summary = Cloudmin::Storage::overview([$fs1, {%$fs1, available => 590}, $fs2, {%$fs2, active => 0}]);
is_deeply([@$summary{qw(pools active volumes filesystems capacity available)}],
	[4, 3, 7, 2, 3000, 1390], 'distinct filesystems sum once and inactive pools contribute no live data');
for my $unknown ({%$fs1, filesystem => undef}, {%$fs1, capacity => 0}) {
	$summary = Cloudmin::Storage::overview([$fs1, $unknown]);
	ok(!defined($summary->{'available'}) && !defined($summary->{'capacity'}), 'unknown storage does not produce a misleading partial total');
}
$summary = Cloudmin::Storage::overview([{%$fs1, volume_error => 'failed'}]);
ok(!defined($summary->{'volumes'}) && $summary->{'available'} == 600, 'volume failure hides its count without discarding known capacity');
{
	local $adapter->{'uri'} = 'qemu+ssh://remote/system';
	local *Cloudmin::Storage::filesystem_id = sub { die 'must not inspect a remote path locally' };
	my $remote = $service->inventory();
	ok(!defined($remote->{'overview'}->{'available'}), 'remote inventory never resolves paths on the local host');
}
# Group choices exclude existing registrations, including inactive pools.
{
	my $reads = 0;
	local *Cloudmin::LVM::inventory = sub {
		$reads++;
		return {used => {}, guests => {}, archives => {}};
		};
	local $conn->{'pools'} = [bless({active => 0, xml =>
		'<pool type="logical"><source><name>used</name></source></pool>'}, 'StoragePool')];
	is_deeply($service->lvm_groups(), ['archives', 'guests'],
		'existing unregistered volume groups are sorted for selection');
	{
		local $adapter->{'uri'} = 'qemu+ssh://remote/system';
		ok(!eval { $service->lvm_groups(); 1 }, 'remote connections cannot enumerate local groups');
		is($reads, 1, 'remote group lookup never reads host LVM');
		}
	local *Cloudmin::LVM::inventory = sub { die "LVM metadata unavailable\n" };
	ok(!eval { $service->lvm_groups(); 1 }, 'group discovery failures propagate');
	like($@, qr/LVM metadata unavailable/, 'group failure retains its diagnostic');
}
ok(!eval { $service->create({name => 'guests', type => 'logical', group => ''}); 1 },
	'empty group selection is rejected before storage changes');
like($@, qr/Select an existing LVM volume group/, 'empty selection has a clear error');

done_testing();
