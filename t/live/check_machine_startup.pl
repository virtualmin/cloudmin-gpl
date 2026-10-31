#!/usr/bin/perl
# Check startup memory against real QEMU without changing existing guests.
use strict;
use warnings;
use FindBin qw($Bin);
use Cwd qw(abs_path);
use Test::More;
BEGIN {
	die "Run on an authorized Linux test host as root\n" unless $^O eq 'linux' && $< == 0;
	my $root = $ENV{'WEBMIN_ROOT'} || abs_path("$Bin/../../..");
	$ENV{'WEBMIN_CONFIG'} = '/etc/webmin';
	$ENV{'WEBMIN_VAR'} = '/var/webmin';
	$ENV{'REMOTE_USER'} = 'root';
	unshift(@INC, $root);
	chdir("$root/server-manager") or die $!;
	$0 = "$root/server-manager/api.pl";
	}
require './server-manager-lib.pl';
require './cloudmin-lib.pl';
require Sys::Virt;
my $adapter = get_libvirt(1);
my $conn = $adapter->connect();
my $arch = Cloudmin::Libvirt::parse_xml_document($conn->get_capabilities())
	->findvalue('/capabilities/host/cpu/arch');
my $machine = $arch eq 'aarch64' ? 'virt' : 'q35';
my $name = 'cloudmin-startup-check-'.time().'-'.$$;
my ($domain, $uuid);
my $ok = eval {
	# Firmware has no balloon driver, keeping the startup mismatch observable.
	$domain = $conn->define_domain("<domain type='kvm'><name>$name</name>".
		"<memory unit='MiB'>256</memory><currentMemory unit='MiB'>224</currentMemory>".
		"<vcpu>1</vcpu><cpu mode='host-passthrough'/><os firmware='efi'>".
		"<type arch='$arch' machine='$machine'>hvm</type><firmware>".
		"<feature enabled='no' name='secure-boot'/>".
		"<feature enabled='no' name='enrolled-keys'/></firmware></os>".
		"<features><acpi/></features><devices><memballoon model='virtio'/></devices></domain>");
	$uuid = $domain->get_uuid_string();
	$adapter->start_domain($uuid);
	# Inventory obtains a new handle; pre-start handles retain an inactive ID.
	$domain = $adapter->find_domain($uuid);
	my $record = $adapter->get_domain_record($domain, 1);
	my $live = Cloudmin::Libvirt::resource_settings(
		Cloudmin::Libvirt::parse_xml_document($domain->get_xml_description(0)));
	ok($live->{'memory_mib'} > 224, 'real startup memory still exceeds the saved balloon target');
	is_deeply($record->{'pending'}, {}, 'inventory has no false power-cycle warning immediately after start');
	is_deeply(get_libvirt()->get_domain($uuid, 1)->{'pending'}, {},
		'a separate read-only page request has no false warning');
	is_deeply(get_vm_manager()->settings($uuid)->{'pending'}, {},
		'the editor uses the same startup comparison');

	# A later saved CPU change stays visible while memory is still settling.
	my $doc = Cloudmin::Libvirt::parse_xml_document($domain->get_xml_description(2));
	Cloudmin::VMManage::set_text($doc->documentElement(), 'vcpu', 2);
	$conn->define_domain($doc->toString());
	$record = get_libvirt()->get_domain($uuid, 1);
	ok($record->{'pending'}->{'cpus'}, 'new CPU change remains pending');
	ok(!$record->{'pending'}->{'memory_mib'}, 'startup memory is still excluded');

	# A changed memory target retires the exception immediately.
	Cloudmin::VMManage::set_text($doc->documentElement(), 'currentMemory', 200, {unit => 'MiB'});
	$conn->define_domain($doc->toString());
	$record = get_libvirt()->get_domain($uuid, 1);
	is($record->{'pending'}->{'memory_mib'}->{'saved'}, 200,
		'a newly saved memory target produces a real warning');
	1;
	};
my $error = $@;
# Remove only this run's diskless guest, firmware variables and startup record.
if ($domain) {
	$domain->destroy() if ($domain->is_active());
	$domain->undefine(Sys::Virt::Domain::UNDEFINE_NVRAM());
	}
# Remove only startup tracking created for this fixture UUID.
if ($uuid) {
	unlink("$main::module_var_directory/vm-startup/$uuid");
	unlink("$main::module_var_directory/vm-startup/$uuid.lock");
	}
die $error if (!$ok);
done_testing();
