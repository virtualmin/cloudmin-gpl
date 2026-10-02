package Cloudmin::VMManage;

# Loaded by VMManage.pm so live operations share its validation and job methods.
use strict;
use warnings;
use Time::HiRes qw(time sleep);

# memory_kib(doc, element)
# Converts libvirt memory fields to KiB, including omitted currentMemory.
sub memory_kib
{
return Cloudmin::Libvirt::memory_kib(@_);
}

# live_limits(domain, config)
# Reads limits from running XML, or from config when the guest is stopped.
sub live_limits
{
my ($domain, $config) = @_;
my $doc = $domain->is_active()
	? Cloudmin::Libvirt::parse_xml_document($domain->get_xml_description(0)) : $config;
return { cpus => 0 + $doc->findvalue('/domain/vcpu'),
	min_cpus => $domain->is_active() ? live_cpu_minimum($doc) : 1,
	memory_mib => memory_kib($doc, 'memory') / 1024,
	pcie_ports => free_pcie_ports($doc),
	balloon => $doc->findnodes('/domain/devices/memballoon[@model="virtio"]') ? 1 : 0 };
}

# live_cpu_minimum(doc)
# Subtracts enabled, removable CPUs from the running count. Without individual
# CPU entries, conservatively treats every enabled CPU as non-removable.
sub live_cpu_minimum
{
my ($doc) = @_;
my $current = $doc->findvalue('/domain/vcpu/@current') || $doc->findvalue('/domain/vcpu');
my $removable = $doc->findvalue('count(/domain/vcpus/vcpu[@enabled="yes" and @hotpluggable="yes"])');
my $minimum = $current - $removable;
return $minimum > 0 ? $minimum : 1;
}

# free_pcie_ports(doc)
# Counts unused root-port buses; legacy PCI guests do not need these ports.
sub free_pcie_ports
{
my ($doc) = @_;
return undef if ($doc->findvalue('/domain/os/type/@machine') !~ /q35|^virt(?:-|$)/);
my %used = map { hex($_->getValue()) => 1 }
	$doc->findnodes('/domain/devices/*/address[@type="pci"]/@bus');
return scalar(grep { !$used{0 + $_->getAttribute('index')} }
	$doc->findnodes('/domain/devices/controller[@model="pcie-root-port"]'));
}

1;
