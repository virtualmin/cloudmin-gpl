#!/usr/bin/perl
# check_machine_delete_snapshots.pl Deletes isolated VMs with real branched
# snapshot chains and verifies kept data.
use strict;
use warnings;
use FindBin qw($Bin);
use Cwd qw(abs_path);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Digest::SHA qw(sha256_hex);
use Test::More;
my $root;

# All fixtures and libvirt mutations belong on the authorized Linux test host.

BEGIN
{
die "Run on an authorized Linux test host as root\n" unless $^O eq 'linux' &&
	$< == 0;
$root = abs_path("$Bin/../../..");
$ENV{'WEBMIN_CONFIG'} = '/etc/webmin'; $ENV{'WEBMIN_VAR'} = '/var/webmin';
$ENV{'REMOTE_USER'} = 'root';
# Use the installed theme only when its directory exists.
$ENV{'THEME_ROOT'} = "$root/authentic-theme" if (-d "$root/authentic-theme");
chdir("$root/server-manager") or die $!;
unshift(@INC, $root);
$0 = "$root/server-manager/check_machine_delete_snapshots.pl";
}
require './server-manager-lib.pl';
require './lib/Cloudmin/Snapshots.pm';
$| = 1;
my $adapter = get_libvirt(1);
my $conn = $adapter->connect();
my $arch = Cloudmin::Libvirt::parse_xml_document($conn->get_capabilities())
	   ->findvalue('/capabilities/host/cpu/arch');
my $machine = $arch eq 'aarch64' ? 'virt' : 'q35';

foreach my $mode (qw(keep partial all shared)) {
	# Every scenario owns a separate pool, job store and guest definition.
	my $dir =
		tempdir(
			'/var/lib/libvirt/images/cloudmin-delete-history-XXXXXX',
			CLEANUP => 1);
	chmod(0755, $dir) or die $!;
	make_path("$dir/disks", { mode => 0755 });
	my $name = 'cloudmin-delete-history-'.substr(sha256_hex($dir), 0, 10);
	my $jobs = get_vm_jobs();
	$jobs->{'directory'} = "$dir/jobs";
	my $manager =
		Cloudmin::VMManage->new(jobs => $jobs,
					images => get_image_jobs(),
					adapter => sub { get_libvirt(1) });
	my $snapshots =
		Cloudmin::Snapshots->new(jobs => $jobs,
					 images => get_image_jobs(),
					 adapter => sub { get_libvirt(1) });
	my ($pool, $domain, $uuid);
	my $serial = 0;
	my $ok = eval {
		# Two writable disks and one read-only disk exercise
		# stop-method selection.
		$pool =
			$conn->define_storage_pool(
				"<pool type='dir'><name>$name</name><target><path>$dir/disks</path></target></pool>");
		$pool->create();
		my @paths;
		foreach my $index (1 .. 3) {
			my $volume =
				$pool->create_volume(
					"<volume><name>disk$index.qcow2</name><capacity unit='MiB'>32</capacity><target><format type='qcow2'/></target></volume>");
			push(@paths, $volume->get_path());
			}
		$domain =
			$conn->define_domain(
				"<domain type='kvm'><name>$name</name><memory unit='MiB'>256</memory><vcpu>1</vcpu>".
				"<cpu mode='host-passthrough'/><os firmware='efi'><type arch='$arch' machine='$machine'>hvm</type></os><features><acpi/></features><devices>".
				join('',
				     map {
						"<disk type='file' device='disk'><driver name='qemu' type='qcow2'/><source file='$paths[$_]'/><target dev='vd".( 'a', 'b', 'c' )[$_]."' bus='virtio'/>".
							($_ == 2
								? '<readonly/>'
								: '').'</disk>' } (0 .. 2)).'</devices></domain>');
		$uuid = $domain->get_uuid_string();
		# Initialize firmware once, before recording the
		# snapshot definitions.
		$domain->create(); $domain->destroy();
		# pattern(operation, byte) reads/writes a marker through
		# each writable chain.
		my $pattern = sub {
			my ($operation, $byte) = @_;
			my $doc =
				Cloudmin::Libvirt::parse_xml_document(
					$domain->get_xml_description(2));
			foreach my $source (
				$doc->findnodes(
					'/domain/devices/disk[not(readonly)]/source')) {
				is(system('qemu-io', '-f', 'qcow2',
					  $operation eq 'read' ? ('-r') : (),
					  '-c', "$operation -P $byte 0 4096",
					  $source->getAttribute('file')), 0,
				   "$mode: $operation pattern $byte");
				}
			};
		# snapshot(action, fields) uses Cloudmin's actual
		# snapshot journal and worker.
		my $snapshot = sub {
			my ($action, $fields) = @_;
			my $id = substr(sha256_hex($dir.++$serial), 0, 32);
			my $request =
				$snapshots->prepare('snapshot_'.$action,
						    { id => $uuid,
						      revision => Cloudmin::Snapshots::revision($domain), confirm => 1, %$fields }, $id);
			$jobs->submit($id, 'root', 'guest:'.$uuid, $request);
			$snapshots->run($id);
			my $job = $jobs->get($id);
			die "$action failed: $job->{error}\n"
				if ($job->{'state'} ne 'complete');
			return $request->{'snapshot'};
			};
		$pattern->('write', 17);
		# Restore the first point and write again, leaving a
		# separate older branch.
		my $first = $snapshot->('create', { label => 'First' });
		$pattern->('write', 34);
		$snapshot->('create', { label => 'Later branch' });
		$snapshot->('restore', { snapshot => $first });
		$pattern->('read', 17);
		$pattern->('write', 51);
		my @history = $domain->list_all_snapshots(0);
		is(scalar(@history), 2,
		   "$mode: history includes the older branch");
		# An unrelated managed overlay must keep the base it
		# shares with this VM.
		if ($mode eq 'shared') {
			is(system('qemu-img', 'create', '-f', 'qcow2', '-F',
				  'qcow2', '-b', $paths[0],
				  "$dir/disks/foreign.qcow2"), 0,
			   'create unrelated shared overlay');
			}
		$pool->refresh(0);
		my @before = map { $_->get_path() } $pool->list_all_volumes();
		my $current =
			Cloudmin::Libvirt::parse_xml_document(
				$domain->get_xml_description(2));
		my @kept = map { $_->getAttribute('file') }
			   $current->findnodes(
				   '/domain/devices/disk[not(readonly)]/source');
		# The all-disks cases also exercise forced power-off
		# with snapshots present.
		$domain->create() if ($mode eq 'all' || $mode eq 'shared');
		my $settings = $manager->settings($uuid);
		my $id = substr(sha256_hex($dir.++$serial), 0, 32);
		my $request =
			$manager->prepare('delete',
					  { id => $uuid,
					    revision => $settings->{'revision'},
					    history_revision => $settings->{'history_revision'}, confirm_name => $name, shutdown => 1,
					    disks => $mode eq 'keep'
						    ? [ ]
						    : $mode eq 'partial'
							    ? [ 'vda' ]
							    : [ 'vda', 'vdb',
								'vdc' ] }, $id);
		$jobs->submit($id, 'root', 'guest:'.$uuid, $request);
		if ($mode eq 'partial') {
			# Fail the base deletion after its children and
			# VM metadata are gone.
			my $delete = \&Sys::Virt::StorageVol::delete;
			{
				no warnings 'redefine';
				local *Sys::Virt::StorageVol::delete = sub {
					# Refuse only this fixture's base; other
					# native deletes proceed.
					die "Fixture storage failure\n" if ($_[0]->get_path() eq $paths[0]);
					return $delete->(@_);
					};
				ok(!$manager->run($id),
				   'partial chain removal reports storage failure');
				}
			ok($jobs->get($id)->{'cleanup_pending'},
			   'failed chain removal can be recovered');
			$jobs->update($id,
				      sub { $_[0]->{'state'} = 'recovering'; });
			}
		$manager->run($id);
		# Confirm definition removal and each file's expected
		# retained/deleted state.
		my $job = $jobs->get($id);
		die "Deletion failed: $job->{error}\n"
			if ($job->{'state'} ne 'complete');
		ok(!$adapter->find_domain($uuid),
		   "$mode: VM and its metadata removed");
		foreach my $path (@before) {
			# Names here come from this fixture and libvirt's
			# controlled vda overlays.
			my $keep = $mode eq 'keep' || ($mode eq 'partial' &&
						       $path !~ /(?:disk1[.]|-vda[.])/) ||
				   ($mode eq 'shared' && ($path eq $paths[0] ||
							  $path eq "$dir/disks/foreign.qcow2"));
			is(-e $path ? 1 : 0, $keep ? 1 : 0,
			   "$mode: expected storage disposition for $path");
			}
		if ($mode eq 'keep' || $mode eq 'partial') {
			# Reading the retained top proves every backing
			# layer is still usable.
			foreach my $path ($mode eq 'keep' ? @kept : $kept[1]) {
				is(system('qemu-io', '-r', '-f', 'qcow2', '-c',
					  'read -P 51 0 4096', $path), 0,
				   'kept disk data remains readable');
				}
			}
		else {
			# Deleting every writable disk skips a
			# cooperative guest shutdown.
			is($job->{'events'}->[0]->{'step'}, 'delete_power_off',
			   'snapshot VM used immediate power-off');
			}
		1;
		};
	my $error = $@;
	# Cleanup is limited to this fixture's definition,
	# metadata and private pool.
	if ($domain && eval { $adapter->find_domain($uuid) }) {
		# A failed scenario can leave its guest active or still defined.
		eval { $domain->destroy()
			if ($domain->is_active()); $domain->undefine(
				$Cloudmin::Libvirt::UNDEFINE_FLAGS); };
		}
	eval { $pool->destroy() if ($pool->is_active()); $pool->undefine(); }
		if ($pool);
	die $error if (!$ok);
	}
done_testing();
