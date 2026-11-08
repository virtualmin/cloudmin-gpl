#!/usr/bin/perl
# Run inside a disposable host against the dedicated VG made by the fixture.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use CloudminTest;
use WebminCore;
use Test::More;
use IPC::Open3;
use Symbol qw(gensym);

my ($group, $source) = @ARGV;
die "Supply the fixture volume group and source directory\n"
	if (($group || '') !~ /^cloudmin_lvm_test_[a-f0-9]+$/ || !-d ($source ||
								      ''));
$ENV{'WEBMIN_CONFIG'} = '/etc/webmin';
$ENV{'WEBMIN_VAR'} = '/var/webmin';
$ENV{'REMOTE_USER'} = 'root';
$0 = Cwd::abs_path("$Bin/../../api.pl");
chdir("$Bin/../..") or die $!;
WebminCore::init_config();
require "$Bin/../../lib/Cloudmin/Libvirt.pm";
require "$Bin/../../lib/Cloudmin/Snapshots.pm";
require "$Bin/../../lib/Cloudmin/Jobs.pm";
require "$Bin/../../lib/Cloudmin/Storage.pm";
{
	package LVMFixtureImages;

	# list(self) supplies the empty import set for these
	# private raw test disks.
	sub list
	{
	[ ]
	}
	}
my $jobs = Cloudmin::Jobs->new(directory => "$source/jobs",
			       lock_file => \&WebminCore::lock_file,
			       unlock_file =>
				       \&WebminCore::unlock_file,
			       test_lock => \&WebminCore::test_lock,
			       log => sub { });
my $service = Cloudmin::Snapshots->new(jobs => $jobs,
				       images => bless({ }, 'LVMFixtureImages'),
				       adapter => sub { Cloudmin::Libvirt->new(readonly => 0) });

# snapshot_job(action, domain, [snapshot]) exercises the
# real durable controller.
sub snapshot_job
{
my ($action, $domain, $snapshot) = @_;
my $id = substr(Cloudmin::Images::generate_id(), 0, 32);
my $request = $service->prepare('snapshot_'.$action, {
	id => $domain->get_uuid_string(), revision =>
						  Cloudmin::Snapshots::revision($domain),
	label => 'LVM fixture', mode => 'unprepared', snapshot =>
							      $snapshot,
	confirm => 1 }, $id);
$jobs->submit($id, 'root', 'guest:'.$domain->get_uuid_string(), $request);
$service->run($id);
my $result = $jobs->get($id);
is($result->{'state'}, 'complete', "native snapshot $action completes");
die $result->{'error'} if ($result->{'state'} ne 'complete');
return $request->{'snapshot'};
}

# storage_api(action, input) exercises the installed root
# API and its audit path.
sub storage_api
{
my ($action, $input) = @_;
# Use a fresh root API process so its token and audit context are real.
my $error = gensym();
my $pid = open3(my $in, my $out, $error, $^X, "$Bin/../../api.pl", $action);
# Close stdin after the JSON body so the API can finish reading it.
print $in WebminCore::convert_to_json($input); close($in);
local $/;
my $body = <$out>;
my $message = <$error>;
waitpid($pid, 0);
# Preserve failures and reject diagnostics before decoding a success.
die $message if ($?);
die "Unexpected API diagnostics: $message" if ($message);
return WebminCore::convert_from_json($body)->{'result'};
}
my $adapter = Cloudmin::Libvirt->new(readonly => 0);
# Register only the loop-backed VG passed by the Python fixture wrapper.
my $connection = $adapter->connect();
my $storage = Cloudmin::Storage->new(adapter => $adapter, jobs => $jobs,
				     images => bless({ }, 'LVMFixtureImages'));
storage_api('register_pool',
	    { type => 'logical', name => $group, group => $group,
	      autostart => 0 });
my $pool = $connection->get_storage_pool_by_name($group);
my @created;
my @domains;
my $error;
my $files;
my $mounted;
eval {
	ok($pool->is_active(),
	   'Cloudmin registers and activates the existing fixture VG');
	ok(!eval { storage_api('register_pool',
			       { type => 'logical', name => $group.'-duplicate',
				 group =>
					 $group }); 1 },
	   'duplicate volume group registration is rejected');
	my $driver = Cloudmin::LVM->new(readonly => 0);
	my @pools = $driver->pools($pool);
	is(scalar(@pools), 2, 'VG and thin pool discovered');
	# Read-only validation of the host's root LV must refuse guest disk use.
	open(my $mounts, '<', '/proc/self/mountinfo') or die $!;
	my ($root_device) =
		map { (split)[2] } grep { (split)[4] eq '/' } <$mounts>;
	close($mounts);
	my ($root) =
		grep { ($_->{'lv_kernel_major'} // '').':'.
			($_->{'lv_kernel_minor'} // '') eq $root_device }
		map { values %{$_->{'volumes'}} } values %{$driver->inventory()};
	SKIP: {
		skip 'Host root is not an LVM volume', 1 if (!$root);
		ok(!eval { Cloudmin::LVM::host_use($root); 1 } &&
		   $@ =~ /mounted on the host/,
		   'mounted host root is rejected without changing it');
		}
	SKIP: {
		skip 'mkfs.btrfs is not installed', 11
			if (!WebminCore::has_command('mkfs.btrfs'));
		# Format only newly allocated fixture LVs, never
		# an existing host disk.
		my @members;
		for my $name ( 'btrfs-first', 'btrfs-second' ) {
			my $volume =
				$pools[0]->create_volume(
					"<volume><name>$name</name>".
					"<capacity unit='bytes'>268435456</capacity><target><format type='raw'/></target></volume>");
			push(@created, $volume);
			push(@members, $volume);
			}
		system('mkfs.btrfs', '-f',
		       map { $_->get_path() } @members) == 0 or
			die 'Cannot format fixture Btrfs';
		my $mount = "$source/btrfs";
		mkdir($mount, 0700) or die $!;
		system('mount', $members[0]->get_path(), $mount) == 0 or
			die 'Cannot mount fixture Btrfs';
		$mounted = $mount;
		for my $volume (@members) {
			# Mountinfo names only the first member; both
			# disks need protection.
			ok(!eval { Cloudmin::LVM::host_use($volume->record(
				1)); 1 } && $@ =~ /mounted on the host/,
			   $volume->get_name().
			   ' is protected while Btrfs is mounted');
			ok(!eval { $volume->delete(); 1 } &&
			   $@ =~ /mounted on the host/,
			   $volume->get_name().' deletion is refused');
			ok(-b $volume->get_path(),
			   'refused deletion leaves the member intact');
			}
		# A host mount protects the entire group as
		# well as its member LVs.
		my $blocked =
			storage_api('pool_review',
				    { id => $pool->get_uuid_string(),
				      stop => 1 });
		like($blocked->{'usage'}->{'reason'}, qr/mounted on the host/,
		     'mounted VG refuses stop and unregistration');
		ok(!eval { storage_api('unregister_pool',
				       { id => $pool->get_uuid_string(),
					 stop => 1, confirm => 1,
					 revision => $blocked->{'revision'} }); 1 },
		   'API refuses to stop a host-mounted group');
		ok($pool->is_active(),
		   'host-use refusal leaves the group active');
		system('umount', $mounted) == 0 or
			die 'Cannot unmount fixture Btrfs';
		undef($mounted);
		for my $volume (@members) {
			ok(Cloudmin::LVM::host_use($volume->record(1)),
			   'unmounted Btrfs member is available again');
			}
		}
	# Convert a real QCOW2 chain into each backend through
	# the isolated worker.
	mkdir("$source/images", 0700) or die $!;
	system('qemu-img', 'create', '-q', '-f', 'qcow2',
	       "$source/images/base.qcow2", '16M') == 0 or
		die 'Cannot create base';
	system('qemu-io', '-f', 'qcow2', '-c', 'write -P 17 0 512',
	       "$source/images/base.qcow2") == 0 or die 'Cannot write base';
	system('qemu-img', 'create', '-q', '-f', 'qcow2', '-F', 'qcow2', '-b',
	       "$source/images/base.qcow2",
	       "$source/images/overlay.qcow2") == 0 or
		die 'Cannot create overlay';
	system('qemu-io', '-f', 'qcow2', '-c', 'write -P 34 4096 512',
	       "$source/images/overlay.qcow2") == 0 or
		die 'Cannot write overlay';
	$files =
		$connection->define_storage_pool(
			"<pool type='dir'><name>$group-files</name><target><path>$source/images</path></target></pool>");
	$files->create();
	my ($overlay) =
		grep {
			$_->get_name() eq
				'overlay.qcow2' } $files->list_all_volumes();
	die 'Overlay not discovered' if (!$overlay);
	# A fully populated archive disk includes QCOW2 metadata
	# beyond its capacity.
	my $full = "$source/full.qcow2";
	system('qemu-img', 'create', '-q', '-f', 'qcow2', $full, '16M') == 0 or
		die 'Cannot create full disk';
	system('qemu-io', '-f', 'qcow2', '-c', 'write -P 51 0 16M',
	       $full) == 0 or
		die 'Cannot fill disk';
	ok(-s $full > 16 * 1024**2,
	   'fully written QCOW2 exceeds its virtual capacity');
	for my $destination (@pools) {
		# Import a fully written image and verify the last sector,
		# not just its header.
		my $restored_name = $destination->{'thin'}
			? 'full-restore-thin'
			: 'full-restore-thick';
		my $restored_record =
			$adapter->upload_seed($destination->get_uuid_string(),
					      $restored_name, $full, sub { },
					      'qcow2',
					      16 * 1024**2);
		my (undef, $restored_volume) =
			$adapter->volume($destination->get_uuid_string(),
					 $restored_name,
					 $restored_record->{'key'});
		push(@created, $restored_volume);
		open(my $restored_disk, '<', $restored_volume->get_path()) or
			die $!;
		seek($restored_disk, 16 * 1024**2 - 512, 0) or die $!;
		read($restored_disk, my $restored_tail, 512) == 512 or
			die 'Short restored read';
		close($restored_disk);
		is($restored_tail, chr(51) x 512,
		   'full QCOW2 restore retains the final disk sector');
		# Flatten both backing layers and check
		# distinct patterns from each.
		my $flat_name = $destination->{'thin'}
			? 'flattened-thin'
			: 'flattened-thick';
		my $copy =
			$adapter->clone_disk($destination->get_uuid_string(),
					     $flat_name,
					     { pool => $files->get_uuid_string(),
					       volume =>
						       $overlay->get_name(),
					       volume_key =>
						       $overlay->get_key() },
					     16 * 1024**2, 'raw', sub { });
		my (undef, $flattened) =
			$adapter->volume($destination->get_uuid_string(),
					 $flat_name, $copy->{'key'});
		push(@created, $flattened);
		open(my $flat, '<', $flattened->get_path()) or die $!;
		read($flat, my $base_data, 512) == 512 or die 'Short base read';
		seek($flat, 4096, 0) or die $!;
		read($flat, my $overlay_data, 512) == 512 or
			die 'Short overlay read';
		close($flat);
		is($base_data, chr(17) x 512,
		   'conversion retains backing-layer bytes');
		is($overlay_data, chr(34) x 512,
		   'conversion retains overlay bytes');
		# Use a separate empty disk for zeroing, growth
		# and snapshot checks.
		my $name = $destination->{'thin'} ? 'thin-disk' : 'thick-disk';
		my $volume =
			$destination->create_volume(
				"<volume><name>$name</name>".
				"<capacity unit='bytes'>67108864</capacity><target><format type='raw'/></target></volume>");
		push(@created, $volume);
		ok(-b $volume->get_path(), "$name is a real block device");
		is($volume->get_info()->{'capacity'}, 67108864,
		   "$name has expected capacity");
		is(Cloudmin::LVM::identity($volume->get_path()),
		   $volume->get_key(), "$name has stable identity");
		# Storage must offer an unused logical volume for deletion
		# without mistaking its own native libvirt record for another
		# owner. Allocate through the service adapter so its LVM
		# inventory includes the volume.
		my $spare = "$name-spare";
		my $spare_pool =
			Cloudmin::Libvirt::storage_pool($adapter,
							$destination->get_uuid_string());
		my $spare_volume =
			$spare_pool->create_volume(
				"<volume><name>$spare</name>".
				"<capacity unit='bytes'>8388608</capacity><target><format type='raw'/></target></volume>");
		my ($pool_record) =
			grep { $_->{'uuid'} eq $destination->get_uuid_string() }
			@{$storage->inventory()->{'pools'}};
		my ($listed) =
			grep { $_->{'name'} eq
				$spare } @{$pool_record->{'volumes'} ||
					[ ]};
		ok($listed && $pool_record->{'volume_manageable'},
		   "$spare is listed in a volume-manageable pool");
		is($listed ? $listed->{'usage'}->{'reason'} : 'missing',
		   '', "$spare is deletable from Storage");
		my $review =
			storage_api('volume_review',
				    { pool => $destination->get_uuid_string(),
				      volume =>
					      $spare });
		# A same-named QCOW2 in another pool must
		# invalidate an earlier review.
		my $dependent = "$source/images/$spare";
		system('qemu-img', 'create', '-q', '-f', 'qcow2', '-F', 'raw',
		       '-b', $spare_volume->get_path(), $dependent) == 0 or
			die 'Cannot create dependent disk';
		ok(!eval { storage_api('delete_volume',
				       { pool => $destination->get_uuid_string(),
					 volume => $spare,
					 revision => $review->{'revision'},
					 confirm => 1 }); 1 },
		   "$spare cannot be deleted while a same-named disk depends on it");
		like($@, qr/owned or referenced/,
		     'backing dependency is reported');
		ok(-b $spare_volume->get_path(),
		   'refused deletion preserves the logical volume');
		unlink($dependent) or die $!;
		storage_api('delete_volume',
			    { pool => $destination->get_uuid_string(),
			      volume => $spare,
			      revision => $review->{'revision'},
			      confirm => 1 });
		$destination->refresh();
		ok(!grep({ $_->get_name() eq $spare }
			 $destination->list_all_volumes()),
		   "$spare is deleted through Storage");
		my $input = "$source/input.raw";
		open(my $raw, '>', $input) or die $!;
		print($raw 'x' x 512) && close($raw) or die $!;
		$volume->write_file($input);
		if (!$destination->{'thin'}) {
			# Thick initialization must erase prior bytes,
			# not just extend a file.
			$volume->zero_range(0);
			open(my $cleared, '<', $volume->get_path()) or die $!;
			read($cleared, my $zeros, 512) == 512 or
				die 'Short zeroed read';
			close($cleared);
			is($zeros, "\0" x 512,
			   'thick initialization erases existing disk bytes');
			$volume->write_file($input);
			}
		unlink($input) or die $!;
		open(my $fh, '<', $volume->get_path()) or die $!;
		read($fh, my $data, 1024) == 1024 or die 'Short volume read';
		close($fh);
		is($data, ('x' x 512).("\0" x 512),
		   "$name has uploaded data and zeroed space");
		# Growth must expose zeroed sectors and clear
		# its recovery marker.
		$volume->resize(100663296);
		is($volume->get_info()->{'capacity'}, 100663296, "$name grows");
		ok(!$volume->initialization_pending(),
		   "$name growth initialization completed");
		open(my $grown, '<', $volume->get_path()) or die $!;
		seek($grown, 67108864, 0) or die $!;
		read($grown, my $tail, 4096) == 4096 or die 'Short growth read';
		close($grown);
		is($tail, "\0" x 4096, "$name new space is zeroed");
		# A minimal guest tests real libvirt metadata
		# without an installed OS.
		my $caps = $adapter->get_host_capabilities();
		my $domain =
			$connection->define_domain(
				"<domain type='kvm'><name>$group-$name</name>".
				"<memory unit='MiB'>256</memory><vcpu>1</vcpu><cpu mode='host-passthrough'/><os><type arch='$caps->{architecture}' machine='$caps->{machine}'>hvm</type></os>".
				"<devices><disk type='block' device='disk'><driver name='qemu' type='raw' cache='none'/><source dev='".
				$volume->get_path().
				"'/><target dev='vda' bus='virtio'/></disk></devices></domain>");
		push(@domains, $domain);
		my $metadata =
			$domain->create_snapshot(
				"<domainsnapshot><name>native-test</name>".
				"<state>disk-snapshot</state><creationTime>".
				time()."</creationTime>".
				"<memory snapshot='no'/><disks><disk name='vda' snapshot='manual'/></disks>".
				$domain->get_xml_description(3).
				"</domainsnapshot>", 1 | 2);
		ok($metadata,
		   "$name supports libvirt manual snapshot metadata");
		# Write the origin after capture to prove the
		# native snapshot is stable.
		my $snapshot = $volume->snapshot($name.'-saved');
		push(@created, $snapshot);
		ok($snapshot->snapshot_health(), "$name snapshot is healthy");
		open(my $changed, '>', $input) or die $!;
		print($changed 'y' x 512) && close($changed) or die $!;
		$volume->write_file($input);
		unlink($input) or die $!;
		open(my $saved, '<', $snapshot->get_path()) or die $!;
		read($saved, my $original, 512) == 512 or
			die 'Short snapshot read';
		close($saved);
		is($original, 'x' x 512,
		   "$name snapshot retains data after origin writes");
		$metadata->delete(2);
		# Exercise create, restore and delete through the controller
		# journal. Remove the primitive snapshot so its untracked
		# dependency is absent.
		$snapshot->delete();
		pop(@created);
		my $point = snapshot_job('create', $domain);
		open(my $latest, '>', $input) or die $!;
		print($latest 'z' x 512) && close($latest) or die $!;
		$volume->write_file($input);
		unlink($input) or die $!;
		snapshot_job('restore', $domain, $point);
		open(my $restored, '<', $volume->get_path()) or die $!;
		read($restored, my $restored_data, 512) == 512 or
			die 'Short restored read';
		close($restored);
		is($restored_data, 'y' x 512,
		   "$name controller restores the saved data");
		snapshot_job('delete', $domain, $point);
		# A running manual capture must release QEMU's
		# pause before completing.
		$domain->create();
		my $live_point = snapshot_job('create', $domain);
		is(($domain->get_state())[0], 1,
		   "$name running snapshot resumes QEMU");
		$domain->destroy();
		snapshot_job('delete', $domain, $live_point);
		}
	1;
	} or $error = $@;
# A failed assertion must not leave the fixture filesystem mounted for cleanup.
if ($mounted) {
	system('umount', $mounted) == 0 or
		die "Cannot unmount fixture Btrfs: $error";
	}
# Tear down only recorded fixture domains and volumes, retaining cleanup errors.
for my $domain (reverse(@domains)) {
	eval {
		$domain->destroy() if ($domain->is_active());
		$_->delete(2) for $domain->list_all_snapshots();
		$domain->undefine();
		1;
		} or $error .= $@;
	}
for my $volume (reverse(@created)) {
	eval { $volume->delete(); 1 } or $error .= $@;
	}
eval { $files->destroy(); $files->undefine(); 1 } or $error .= $@ if ($files);
eval {
	my $id = $pool->get_uuid_string();
	# Confirmation without stop permission must leave
	# the active group alone.
	my $blocked = storage_api('pool_review', { id => $id });
	like($blocked->{'usage'}->{'reason'}, qr/--stop/,
	     'API requires permission to stop active LVM');
	ok(!eval { storage_api('unregister_pool',
			       { id => $id, revision => $blocked->{'revision'},
				 confirm => 1 }); 1 },
	   'API does not deactivate the group without stop permission');
	ok($pool->is_active(), 'refused removal leaves the pool active');
	# Unused thick and thin disks survive confirmed
	# whole-group deactivation.
	my @destinations = Cloudmin::LVM->new(readonly => 0)->pools($pool);
	for my $destination (@destinations) {
		my $volume =
			$destination->create_volume('<volume><name>kept-'.
						    $destination->{'thin'}.
						    '</name><capacity unit="bytes">4194304</capacity><target><format type="raw"/></target></volume>');
		open(my $data, '>', $volume->get_path()) or die $!;
		print($data 'preserved bytes') && close($data) or die $!;
		}
	# A stop-enabled review can remove an unused pool
	# while preserving its LVs.
	my $review = storage_api('pool_review', { id => $id, stop => 1 });
	is($review->{'usage'}->{'reason'}, '',
	   'unused active LVM registration passes stop review');
	ok($review->{'stop_required'},
	   'API review identifies whole-group stop');
	storage_api('unregister_pool',
		    { id => $id, revision => $review->{'revision'},
		      confirm => 1,
		      stop =>
			      1 });
	my $inventory = Cloudmin::LVM->new()->inventory();
	ok($inventory->{$group}->{'volumes'}->{'thin'},
	   'unregistration preserves the VG and thin pool');
	ok(!eval { $connection->get_storage_pool_by_uuid($id); 1 },
	   'native registration is removed');
	# Registering again activates the saved volumes without formatting them.
	storage_api('register_pool',
		    { type => 'logical', name => $group, group => $group,
		      autostart =>
			      0 });
	$pool = $connection->get_storage_pool_by_name($group);
	for my $name ( 'kept-', 'kept-thin' ) {
		open(my $data, '<', "/dev/$group/$name") or die $!;
		read($data, my $bytes, 15) == 15 or die 'Short preserved read';
		close($data);
		is($bytes, 'preserved bytes',
		   "$name data survives unregistration and activation");
		}
	# The named CLI follows the same review and confirmation path for LVM.
	system($^X, "$Bin/../../cli.pl", 'unregister-pool', '--pool', $group,
	       '--stop', '--yes') == 0 or
		die 'CLI stop and unregister failed';
	ok(!eval { $connection->get_storage_pool_by_name($group); 1 },
	   'CLI removes the reactivated LVM registration');
	1;
	} or $error .= $@;
die $error if ($error);
done_testing();
