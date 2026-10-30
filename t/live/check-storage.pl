#!/usr/bin/perl
# check-storage.pl
# Tests directory-pool lifecycle against native libvirt, preserving host pools.
use strict;
use warnings;
use FindBin qw($Bin);
use Cwd qw(abs_path);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Test::More;
use Digest::SHA qw(sha256_hex);
my $root;
BEGIN {
	die "Run on an authorized Linux test host as root\n" unless $^O eq 'linux' && $< == 0;
	$root = abs_path("$Bin/../../..");
	$ENV{'WEBMIN_CONFIG'} = '/etc/webmin'; $ENV{'WEBMIN_VAR'} = '/var/webmin';
	$ENV{'REMOTE_USER'} = 'root';
	chdir("$root/server-manager") or die $!;
	unshift(@INC, $root);
	$0 = "$root/server-manager/check-storage.pl";
}
require './server-manager-lib.pl';
require './cloudmin-storage-lib.pl';
require Sys::Virt;
$| = 1;
my $dir = tempdir('/var/lib/libvirt/cloudmin-storage-check-XXXXXX', CLEANUP => 1);
chmod(0755, $dir) or die $!;
my $name = 'cm-storage-'.substr(sha256_hex($dir), 0, 12);
my $service = get_storage_service(1);
my $images = $service->{'images'};
$images->{'directory'} = "$dir/jobs";
make_path($images->{'directory'}, {mode => 0700});
my $conn = $service->{'adapter'}->connect();
my @before = map { [$_->get_uuid_string(), $_->is_active(), $_->is_persistent() ? $_->get_autostart() : 0] }
	$conn->list_all_storage_pools();
my (@pools, $domain);
my $ok = eval {
	# Start a new persistent pool using the production controller and host lock.
	is($service->create({name => $name, path => "$dir/new", autostart => 1}), $name, 'native directory pool created');
	my $pool = $conn->get_storage_pool_by_name($name); push(@pools, $pool);
	ok(-d "$dir/new" && $pool->is_active() && $pool->is_persistent() && $pool->get_autostart(), 'directory, activation and boot policy persisted');
	my $uuid = $pool->get_uuid_string();
	my $reopened = Sys::Virt->new(uri => 'qemu:///system')->get_storage_pool_by_uuid($uuid);
	ok($reopened->get_autostart(), 'boot policy survives a new libvirt connection');
	my $revision = Cloudmin::Storage::revision($pool);
	$service->change('autostart', $uuid, $revision, 0);
	ok(!$reopened->get_autostart(), 'boot policy change is visible to another connection');
	ok(!eval { $service->change('stop', $uuid, $revision); 1 }, 'native stale form refused');
	$service->change('autostart', $uuid, Cloudmin::Storage::revision($pool), 1);

	# Existing files keep their exact contents through stop and start.
	my $volume = $pool->create_volume('<volume><name>fixture.raw</name><capacity>1048576</capacity><allocation>4096</allocation><target><format type="raw"/></target></volume>');
	open(my $disk, '+<', $volume->get_path()) or die $!;
	print $disk 'cloudmin-storage-preserved'; close($disk);
	my $record = (grep { $_->{'uuid'} eq $uuid } @{$service->inventory()->{'pools'}})[0];
	is($record->{'volume_count'}, 1, 'live inventory includes the real volume');
	ok($record->{'capacity'} && $record->{'available'}, 'live capacity and free space available');

	# A real paused guest still has active disk I/O and must protect its pool.
	my $caps = Cloudmin::Libvirt::parse_xml_document($conn->get_capabilities());
	my $arch = $caps->findvalue('/capabilities/host/cpu/arch');
	my $machine = $arch eq 'aarch64' ? 'virt' : 'pc';
	my $path = Cloudmin::Libvirt::xml_escape($volume->get_path());
	$domain = $conn->define_domain("<domain type='qemu'><name>$name</name><memory unit='MiB'>64</memory><vcpu>1</vcpu><os><type arch='$arch' machine='$machine'>hvm</type></os><devices><disk type='file' device='disk'><driver name='qemu' type='raw'/><source file='$path'/><target dev='vda' bus='virtio'/></disk></devices></domain>");
	$domain->create(Sys::Virt::Domain::START_PAUSED());
	ok(!eval { $service->change('stop', $uuid, Cloudmin::Storage::revision($pool)); 1 }, 'running native guest protects its pool');
	like($@, qr/Stop virtual machines/, 'guest refusal comes from storage guard');
	my ($used_pool) = grep { $_->{'uuid'} eq $uuid } @{$service->inventory()->{'pools'}};
	my ($used) = grep { $_->{'name'} eq 'fixture.raw' } @{$used_pool->{'volumes'}};
	ok(grep({ $_->{'kind'} eq 'vm' && $_->{'active'} } @{$used->{'usage'}->{'owners'}}), 'native running VM appears beside its volume');
	ok(!eval { $service->inspect_volume($uuid, 'fixture.raw'); 1 }, 'running VM volume cannot be reviewed for deletion');
	$domain->destroy();
	ok(!eval { $service->inspect_volume($uuid, 'fixture.raw'); 1 }, 'stopped VM volume remains protected');
	like($@, qr/owned or referenced/, 'stopped VM refusal explains ownership');

	# A waiting import reserves its target before its worker is launched.
	my $image = $images->create('fixture', $images->form_token('fixture'),
		{source => 'upload', format => 'raw', pool => $uuid, name => 'storage fixture'});
	ok(!eval { $service->change('stop', $uuid, Cloudmin::Storage::revision($pool)); 1 }, 'native image reservation protects pool');
	like($@, qr/Finish or cancel/, 'import refusal explains recovery');
	ok($images->remove($image->{'id'}), 'waiting import cancels through coordinated deletion');
	$service->change('stop', $uuid, Cloudmin::Storage::revision($pool));
	ok(!$pool->is_active() && $pool->is_persistent(), 'stop preserves definition with stopped guest attached');
	ok(!eval { $images->create('fixture', $images->form_token('fixture'),
		{source => 'upload', format => 'raw', pool => $uuid, name => 'inactive fixture'}); 1 }, 'new import cannot reserve inactive pool');
	like($@, qr/no longer active/, 'reservation rechecks real pool under host lock');
	$service->change('start', $uuid, Cloudmin::Storage::revision($pool));
	open(my $saved, '<', "$dir/new/fixture.raw") or die $!;
	read($saved, my $marker, length('cloudmin-storage-preserved')); close($saved);
	is($marker, 'cloudmin-storage-preserved', 'file contents survive stop/start');
	my @volumes = $pool->list_all_volumes();
	is(scalar(@volumes), 1, 'volume returns after activation');
	$domain->undefine(); $domain = undef;

	# Native backing metadata protects an unattached disk until its child is gone.
	my $child = $pool->create_volume("<volume><name>child.qcow2</name><capacity>1048576</capacity>".
		"<target><format type='qcow2'/></target><backingStore><path>$path</path>".
		"<format type='raw'/></backingStore></volume>");
	ok(!eval { $service->inspect_volume($uuid, 'fixture.raw'); 1 }, 'native backing disk is protected');
	like($@, qr/owned or referenced/, 'native backing refusal comes from ownership');
	my (undef, undef, $review) = $service->inspect_volume($uuid, 'child.qcow2');
	ok(-f $review->{'path'}, 'review does not delete the child volume');
	is($service->delete_volume($uuid, 'child.qcow2', $review->{'revision'}, 1)->{'name'},
		'child.qcow2', 'unused native child can be deleted without deleting its backing file');
	ok(-f $volume->get_path(), 'backing file remains after child deletion');

	# A waiting import blocks a previously reviewed unused file under the lock.
	(undef, undef, $review) = $service->inspect_volume($uuid, 'fixture.raw');
	my $pending = $images->create('fixture', $images->form_token('fixture'),
		{source => 'upload', format => 'raw', pool => $uuid, name => 'volume guard'});
	ok(!eval { $service->delete_volume($uuid, 'fixture.raw', $review->{'revision'}, 1); 1 }, 'native pending import prevents deletion');
	like($@, qr/Wait for/, 'pending operation refusal is explicit');
	$images->remove($pending->{'id'});

	# Reusing a libvirt name/key cannot reuse the old confirmation's inode.
	my $volume_path = $volume->get_path();
	rename($volume_path, "$dir/original.raw") or die $!;
	open(my $replacement, '>', $volume_path) or die $!; print $replacement 'replacement'; close($replacement);
	ok(!eval { $service->delete_volume($uuid, 'fixture.raw', $review->{'revision'}, 1); 1 }, 'native same-name replacement invalidates confirmation');
	like($@, qr/volume changed/, 'replacement is reported');
	unlink($volume_path) or die $!;
	rename("$dir/original.raw", $volume_path) or die $!;
	(undef, undef, $review) = $service->inspect_volume($uuid, 'fixture.raw');
	ok(!eval { $service->delete_volume($uuid, 'fixture.raw', $review->{'revision'}, 0); 1 }, 'native deletion requires explicit confirmation');
	is($service->delete_volume($uuid, 'fixture.raw', $review->{'revision'}, 1)->{'name'},
		'fixture.raw', 'unused native file deleted after confirmation');
	ok(!-e $volume_path, 'only the confirmed native file is removed');

	# Registering an existing directory must preserve files, mode and ownership.
	make_path("$dir/existing", {mode => 0750});
	open(my $sentinel, '>', "$dir/existing/keep.txt") or die $!; print $sentinel 'keep'; close($sentinel);
	my @stat = stat("$dir/existing");
	$service->create({name => "$name-existing", path => "$dir/existing", autostart => 0});
	push(@pools, $conn->get_storage_pool_by_name("$name-existing"));
	is_deeply([(stat("$dir/existing"))[2,4,5]], [@stat[2,4,5]], 'existing mode and ownership preserved');
	is(-s "$dir/existing/keep.txt", 4, 'existing data preserved');
	# Two directory pools on one filesystem must not double the free space.
	my @shared = grep { $_->{'name'} eq $name || $_->{'name'} eq "$name-existing" }
		@{$service->inventory()->{'pools'}};
	ok($shared[0]->{'filesystem'}, 'native filesystem identity is available');
	is($shared[0]->{'filesystem'}, $shared[1]->{'filesystem'}, 'separate pool directories identify the same filesystem');
	my $totals = Cloudmin::Storage::overview(\@shared);
	is($totals->{'filesystems'}, 1, 'overview counts the shared filesystem once');
	ok($totals->{'capacity'} <= $shared[0]->{'capacity'} && $totals->{'available'} <= $shared[0]->{'available'},
		'overview capacity and free space are not doubled');
	ok(!eval { $service->create({name => "$name-overlap", path => "$dir/existing/child"}); 1 }, 'overlapping native pool rejected');
	ok(!-e "$dir/existing/child", 'rejected request creates no directory');
	# A concurrently defined name must be rejected by libvirt, never replaced.
	my $plan = $service->prepare({name => "$name-race", path => "$dir/race"});
	my $claimed = $conn->define_storage_pool("<pool type='dir'><name>$name-race</name><target><path>$dir/claimed</path></target></pool>");
	push(@pools, $claimed);
	ok(!eval { $conn->define_storage_pool($plan->{'xml'}); 1 }, 'native UUID prevents redefining a concurrently claimed name');
	like($claimed->get_xml_description(), qr{<path>\Q$dir/claimed\E</path>}, 'concurrent pool definition is preserved');
	1;
};
my $error = $@;
# Cleanup is limited to the unique fixture names and directories created above.
if ($domain) { eval { $domain->destroy() if $domain->is_active(); $domain->undefine(); }; die "Guest cleanup failed: $@" if $@; }
foreach my $pool (reverse @pools) {
	$pool->destroy() if $pool->is_active();
	$pool->undefine();
}
foreach my $before (@before) {
	my $pool = $conn->get_storage_pool_by_uuid($before->[0]);
	is_deeply([$pool->is_active(), $pool->is_persistent() ? $pool->get_autostart() : 0],
		[@$before[1,2]], 'pre-existing pool activation and boot policy unchanged');
}
die $error if !$ok;
done_testing();
