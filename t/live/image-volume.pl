#!/usr/bin/perl
# image-volume.pl action job-id [expected-sha256]
# Checks or removes only the volume and private records owned by one test job.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../..";
use WebminCore ();
use Digest::SHA;
use Sys::Virt;
die "Run on an authorized Linux test host as root\n" unless $^O eq 'linux' &&
	$< == 0;
my ($action, $id, $expected) = @ARGV;
die "Invalid test job" if (($id || '') !~ /\A[a-f0-9]{32}\z/);
my $root = '/var/webmin/modules/server-manager/image-jobs';
open(my $fh, '<', "$root/$id.json") || die $!;
my $job = do { local $/; WebminCore::convert_from_json(<$fh>) };
close($fh);
die "Not a fixture job" if ($job->{'owner'} ne 'cloudmin-ui-check');
my $conn = Sys::Virt->new(uri => 'qemu:///system');
my $pool = $conn->get_storage_pool_by_uuid($job->{'pool'});
my $volume = eval { $pool->get_volume_by_name($job->{'volume'}) };
my $domain_name = 'cloudmin-image-test-'.substr($id, 0, 12);
# Verify the committed volume independently of the import status response.
if ($action eq 'verify') {
	die "No ready volume" if (!$volume || $job->{'state'} ne 'ready');
	my $path = $volume->get_path();
	open(my $disk, '<', $path) || die $!;
	binmode($disk);
	my $digest = Digest::SHA->new(256)->addfile($disk)->hexdigest();
	close($disk);
	die "Imported bytes differ from source"
		if ($expected && $digest ne $expected);
	die "Staging file remains" if (-e "$root/$id.part");
	die "Webmin staging file remains"
		if (glob("$root/$id.part.webmintmp.*"));
	print WebminCore::convert_to_json({ volume => $volume->get_name(), path => $path,
			    bytes => -s $path, sha256 => $digest }, 0, 1), "\n";
	}
# Failed imports must leave neither a volume nor staging files.
elsif ($action eq 'absent') {
	die "Failed import left a volume" if ($volume);
	die "Failed import left staging data" if (-e "$root/$id.part");
	die "Failed import left Webmin staging data"
		if (glob("$root/$id.part.webmintmp.*"));
	}
# Remove only this fixture guest, job record and staging files.
elsif ($action eq 'cleanup') {
	my $domain = eval { $conn->get_domain_by_name($domain_name) };
	$domain->undefine() if ($domain);
	die "Fixture is still active"
		if ($job->{'state'} !~ /\A(?:ready|failed|waiting|deleted)\z/);
	$volume->delete(0) if ($volume);
	unlink("$root/$id.$_") for qw(json lock part cancel);
	}
# Attach the image to a stopped test guest to exercise deletion protection.
elsif ($action eq 'protect') {
	die "Missing fixture volume" if (!$volume);
	my $path = $volume->get_path();
	$path =~ s/&/&amp;/g; $path =~ s/'/&apos;/g;
	$conn->define_domain("<domain type='kvm'><name>$domain_name</name>".
			     "<memory unit='MiB'>64</memory><vcpu>1</vcpu><os><type>hvm</type></os>".
			     "<devices><disk type='file' device='disk'><driver name='qemu' type='qcow2'/>".
			     "<source file='$path'/><target dev='vda' bus='virtio'/></disk></devices></domain>");
	}
# Remove the test attachment so normal cleanup can proceed.
elsif ($action eq 'unprotect') {
	$conn->get_domain_by_name($domain_name)->undefine();
	}
# Reject unknown actions before performing any additional fixture work.
else {
	die "Unknown test action";
	}
