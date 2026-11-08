#!/usr/bin/perl
# machine_fixture.pl inspect|cleanup job-id, or forget-passwords
# Inspect or remove only VMs created by the disposable creation fixture.
use strict;
use FindBin;
use Cwd qw(abs_path);
my $webmin_root;
use warnings;

BEGIN
{
$webmin_root = abs_path("$FindBin::Bin/../../..");
die "Run on a disposable Linux VM as root\n" unless $^O eq 'linux' &&
	$< == 0;
$ENV{'WEBMIN_CONFIG'} = '/etc/webmin';
$ENV{'WEBMIN_VAR'} = '/var/webmin';
$ENV{'REMOTE_USER'} = 'root';
chdir("$webmin_root/server-manager") || die $!;
$0 = "$webmin_root/server-manager/api.pl";
}
require './server-manager-lib.pl';
my ($action, $id) = @ARGV;
my $jobs = get_vm_jobs();
if ($action eq 'forget-passwords') {
	# Validation failures can leave drafts without a VM job to clean up.
	$jobs->write_data(sub {
		$_[0]->do('DELETE FROM credentials WHERE owner = ?', undef,
			  'cloudmin-ui-check');
		});
	print "Fixture password drafts removed\n";
	exit;
	}
my $job = $jobs->get($id) || die "Fixture job is missing\n";
die "Not a fixture job\n"
	if ($job->{'request'}->{'name'} !~ /\Acloudmin-create-check-/ ||
	    ($job->{'owner'} ne 'cloudmin-ui-check' &&
	     !($job->{'owner'} eq 'root' &&
	       (
		       $job->{'request'}->{'name'} =~ /\Acloudmin-create-check-platform-/ ||
		       # Root-owned installation checks have
		       # their own exact fixture name.
		       ($job->{'request'}->{'name'} =~ /\Acloudmin-create-check-virtualmin-[a-f0-9]{8}\z/ &&
			($job->{'request'}->{'software'} || '') eq 'virtualmin-gpl')))));
die "Fixture worker is still active\n" if ($jobs->busy($id));
my $adapter = get_libvirt(1);
my $r = $job->{'request'};
# Return creation state without exposing private provisioning contents.
if ($action eq 'inspect') {
	my $vm = $adapter->get_domain($r->{'uuid'}) || die "VM is missing\n";
	# The fixture never returns passwords or public keys in its diagnostics.
	delete(@$vm{qw(console graphics xml)});
	my $pid =
		read_file_contents('/run/libvirt/qemu/'.$r->{'name'}.'.pid');
	# Use a validated live QEMU PID to check its effective host user.
	if ($pid && $pid =~ /\A(\d+)\s*\z/) {
		my $status = read_file_contents("/proc/$1/status");
		my ($uid) = $status =~ /^Uid:\s+(\d+)/m;
		$vm->{'qemu_uid'} = 0 + $uid if (defined($uid));
		}
	print convert_to_json({ vm => $vm, resources => $job->{'resources'},
				mac => $r->{'mac'},
				source => $r->{'source_image'}->{'volume_path'} });
	}
elsif ($action eq 'cleanup') {
	# Read the journal even if the browser failed before
	# recording added disks.
	my $db = $jobs->connect(0);
	my $rows = $db->selectall_arrayref(
		'SELECT record FROM jobs WHERE resource = ?', undef,
		'guest:'.$r->{'uuid'});
	$db->disconnect();
	my @extra;
	foreach my $row (@$rows) {
		my $change = convert_from_json($row->[0]);
		die "Fixture management worker is still active\n"
			if ($jobs->busy($change->{'id'}) ||
			    $change->{'state'} !~ /\A(?:complete|failed|cancelled)\z/);
		push(@extra,
		     values %{$change->{'resources'}->{'new_volumes'} ||
				{ }});
		}
	# Ownership checks in the adapter protect non-fixture
	# domains and volumes.
	$adapter->remove_created_guest($r->{'uuid'}, $id);
	foreach my $kind (qw(seed disk)) {
		my $v = $job->{'resources'}->{$kind} || next;
		$adapter->remove_created_volume($r->{'pool'}, $v->{'name'},
						$v->{'key'});
		}
	foreach my $v (@extra) {
		# Keep files adopted by another guest or
		# replaced since allocation.
		my (undef,
		    $volume) = $adapter->volume(@$v{qw(pool name key)});
		next if (!$volume);
		get_vm_manager()->check_volume($adapter, $v);
		$adapter->remove_created_volume(@$v{qw(pool name key)});
		}
	get_vm_service()->cleanup_work($id);
	die "Fixture SSH key was not removed\n"
		if (get_ssh_keys()->find($r->{'uuid'}, $id));
	# Removing the guest must also remove its saved Webmin login.
	die "Fixture Webmin entry was not removed\n"
		if (vm_webmin_server($r->{'uuid'}, $id));
	print "Fixture resources removed\n";
	}
# Refuse actions that are not part of this fixture interface.
else {
	die "Unknown fixture action\n";
	}
