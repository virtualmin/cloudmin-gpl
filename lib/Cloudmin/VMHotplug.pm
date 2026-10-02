package Cloudmin::VMManage;

# Loaded by VMManage.pm so live operations share its validation and job methods.
use strict;
use warnings;
use Time::HiRes qw(time sleep);

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
