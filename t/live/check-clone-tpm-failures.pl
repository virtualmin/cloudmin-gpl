#!/usr/bin/perl
# check-clone-tpm-failures.pl network
# Exercise real TPM allocation and rollback without a guest operating system.
use strict;
use warnings;
use FindBin qw($Bin);
use Cwd qw(abs_path);
use File::Temp qw(tempdir);
use File::Path qw(make_path remove_tree);
use Digest::SHA qw(sha256_hex);
use POSIX ();
use Test::More;

BEGIN
{
# Load Webmin's root context only on an authorized Linux test host.
die "Run as root on an authorized Linux test host\n" unless $^O eq 'linux' &&
	$< == 0;
$ENV{'WEBMIN_CONFIG'} = '/etc/webmin'; $ENV{'WEBMIN_VAR'} = '/var/webmin';
$ENV{'REMOTE_USER'} = 'root';
chdir("$Bin/../..") or die $!;
$0 = abs_path('./api.pl');
}
require './server-manager-lib.pl';
require './lib/Cloudmin/Clones.pm';
{
	package TPMCloneFailure;
	our @ISA = ('Cloudmin::Clones');

	# step(self, id, name, callback) faults only after a
	# real TPM copy completes.

	sub step
	{
	my ($self, $id, $name, $callback) = @_;
	my $result = $self->SUPER::step($id, $name, $callback);
	# Reach the real allocation before injecting any failure.
	if ($name eq 'clone_tpm') {
		# Exit without unwinding to leave a recoverable
		# interrupted journal.
		POSIX::_exit(0) if ($self->{'fault'} eq 'interrupt');
		if ($self->{'fault'} eq 'cancel') {
			# Let the next worker checkpoint handle cancellation.
			$self->{'jobs'}->update($id,
						sub { $_[0]->{'cancel'} = 1 });
			}
		else {
			# Exercise normal exception cleanup
			# after the completed copy.
			die "Fixture failure after copying TPM state\n";
			}
		}
	return $result;
	}
	}
$| = 1;
# Use an existing active network without changing its configuration.
my $network_name = shift(@ARGV) || die "Supply an active test network\n";
my $service = get_clone_service();
my $adapter = get_libvirt(1);
my $conn = $adapter->connect();
my $network = $conn->get_network_by_name($network_name);
die "Selected network must be active\n" unless $network->is_active();
# Keep both disks and journals private to this fault-injection run.
my $dir = tempdir('/var/lib/libvirt/images/cloudmin-tpm-failure-XXXXXX');
chmod(0755, $dir) or die $!;
make_path("$dir/disks", { mode => 0755 });
my $jobs = $service->{'jobs'};
$jobs->{'directory'} = "$dir/jobs";
my $name = 'cloudmin-tpm-failure-'.substr(sha256_hex($dir), 0, 8);
my ($pool, $domain);
my $ok = eval {
	# The sparse fixture disk never contains user data or an installed OS.
	$pool =
		$conn->define_storage_pool(
			"<pool type='dir'><name>$name</name><target><path>$dir/disks</path></target></pool>");
	$pool->create();
	my $volume =
		$pool->create_volume(
			"<volume><name>source.qcow2</name><capacity unit='GiB'>1</capacity><target><format type='qcow2'/></target></volume>");
	my $disk = $volume->get_path();
	# Select a TPM device supported by the host architecture's machine type.
	my $arch =
		Cloudmin::Libvirt::parse_xml_document(
			$conn->get_capabilities())->findvalue(
				'/capabilities/host/cpu/arch');
	my ($machine, $model) = $arch eq 'aarch64'
		? ( 'virt', 'tpm-tis' )
		: ( 'q35', 'tpm-crb' );
	$domain =
		$conn->define_domain(
			"<domain type='kvm'><name>$name</name><memory unit='MiB'>512</memory><vcpu>1</vcpu><cpu mode='host-passthrough'/>".
			"<os firmware='efi'><type arch='$arch' machine='$machine'>hvm</type></os><features><acpi/></features><devices>".
			"<disk type='file' device='disk'><driver name='qemu' type='qcow2'/><source file='$disk'/><target dev='vda' bus='virtio'/></disk>".
			"<tpm model='$model'><backend type='emulator' version='2.0'/></tpm></devices></domain>");
	# A short firmware boot creates real swtpm state before
	# taking its checksum.
	$domain->create(); sleep(2); $domain->destroy();
	my $uuid = $domain->get_uuid_string();
	my $state = Cloudmin::TPM::path($uuid).'/tpm2-00.permall';
	my $original = sha256_hex(Cloudmin::TPM::read_state($state));
	foreach my $fault (qw(fail cancel interrupt)) {
		# Exercise production preparation and submission
		# with a fresh job ID.
		my $id = substr(sha256_hex($dir.$fault), 0, 32);
		my $request =
			$service->prepare({ id => $uuid, revision =>
								 Cloudmin::Snapshots::revision($domain),
					    name => "$name-$fault",
					    clone_mode => 'unchanged',
					    confirm_unchanged => 1,
					    confirm_license => 1,
					    start => 0, autostart => 0,
					    pool => $pool->get_uuid_string(),
					    network => 'network:'.
						       $network->get_uuid_string() },
					  $id);
		$jobs->submit($id, 'root', 'vm:'.$request->{'name'},
			      $request);
		bless($service, 'TPMCloneFailure'); $service->{'fault'} =
			$fault;
		if ($fault eq 'interrupt') {
			# A separate process leaves allocation intact, just
			# like a killed worker.
			my $pid = fork(); die "Cannot fork fixture\n"
				if (!defined($pid));
			# The child must exit at TPM allocation,
			# before run() returns.
			if (!$pid) { $service->run($id); POSIX::_exit(1); }
			waitpid($pid, 0); is($?, 0,
					     'worker interrupted after TPM copy');
			ok(-d Cloudmin::TPM::path($request->{'uuid'}),
			   'interrupted copy retained for recovery');
			# Recovery uses the ordinary service, with
			# fault injection removed.
			bless($service, 'Cloudmin::Clones');
			$jobs->update($id,
				      sub { $_[0]->{'state'} = 'recovering' });
			}
		# Run ordinary rollback, including recovery of
		# the interrupted child.
		$service->run($id);
		my $job = $jobs->get($id);
		# Each fault must reach TPM allocation and
		# leave no pending cleanup.
		is($job->{'state'}, $fault eq 'cancel' ? 'cancelled' : 'failed',
		   "$fault reports correct state");
		ok($job->{'resources'}->{'tpm'},
		   "$fault reached actual TPM allocation");
		ok(!$job->{'cleanup_pending'}, "$fault cleanup completed");
		# Destination resources must be gone while the
		# source bytes stay intact.
		ok(!-d Cloudmin::TPM::path($request->{'uuid'}),
		   "$fault removed copied TPM");
		is(sha256_hex(Cloudmin::TPM::read_state($state)), $original,
		   "$fault left source TPM unchanged");
		ok(!$adapter->find_domain($request->{'uuid'}),
		   "$fault left no clone domain");
		ok(!grep({ -e $_->{'path'} } @{$job->{'resources'}->{'volumes'} ||
			[ ]}), "$fault removed copied disks");
		bless($service, 'Cloudmin::Clones');
		}
	1;
	};
my $error = $@;
# Cleanup never reaches another VM or a pool outside this fixture directory.
if ($domain) {
	# An early failure may leave firmware running; stop
	# it before undefining.
	$domain->destroy() if ($domain->is_active());
	# Drop the fixture's NVRAM and TPM state with its definition.
	$domain->undefine(4 | 32);
	}
# Remove only volumes from the pool allocated by this run.
if ($pool) {
	$pool->refresh();
	$_->delete(0) foreach $pool->list_all_volumes();
	$pool->destroy(); $pool->undefine();
	}
remove_tree($dir);
# Report setup or runtime errors after attempting fixture cleanup.
die $error if (!$ok);
done_testing();
