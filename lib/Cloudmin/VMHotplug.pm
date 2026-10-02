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

# hotplug_device(doc, kind, identity)
# Finds a disk by target or a network interface by MAC without XPath input.
sub hotplug_device
{
my ($doc, $kind, $identity) = @_;
return (grep { ($kind eq 'disk' ? $_->findvalue('target/@dev') :
	lc($_->findvalue('mac/@address'))) eq $identity }
	$doc->findnodes('/domain/devices/'.$kind))[0];
}

# device_value(node)
# Serializes editable fields for comparison; an absent node becomes ''.
# QEMU-assigned aliases and addresses do not identify an attachment change.
sub device_value
{
my ($node) = @_;
return '' if (!$node);
my %value;
foreach my $path (qw(@type @device driver/@type source/@file source/@dev
	source/@pool source/@volume source/@network target/@dev target/@bus
	mac/@address model/@type link/@state bandwidth/inbound/@average
	bandwidth/outbound/@average)) {
	# Host tap names are runtime details, unlike stable disk targets.
	next if ($node->nodeName() eq 'interface' && $path =~ /^target/);
	$value{$path} = ''.$node->findvalue($path);
	}
$value{'source/@bridge'} = ''.$node->findvalue('source/@bridge')
	if ($node->getAttribute('type') eq 'bridge');
$value{'readonly'} = $node->findnodes('readonly') ? 1 : 0;
# Libvirt omits the driver format for an empty live CD drive.
$value{'driver/@type'} = '' if ($value{'@device'} eq 'cdrom' &&
	!grep { length($value{'source/@'.$_}) } qw(file dev pool volume));
# Omitted link and bandwidth elements mean connected and unlimited.
$value{'link/@state'} ||= 'up';
$value{'bandwidth/'.$_.'/@average'} ||= '0' foreach qw(inbound outbound);
return convert_to_json(\%value, 0, 0, 1);
}

# hotplug_reason(domain, plan)
# Reports a device change that blocks live execution; resource limits defer.
sub hotplug_reason
{
my ($domain, $plan) = @_;
return $plan->{'offline_reason'} if ($plan->{'offline_reason'});
my $doc = Cloudmin::Libvirt::parse_xml_document($domain->get_xml_description(0));
my $ports = free_pcie_ports($doc);
# Compare planned additions with the running guest's spare port count.
my $additions = grep { ($_->{'method'} || '') eq 'attach_device' } @{$plan->{'live_ops'}};
return 'Shut down once and enable hardware expansion before adding more devices'
	if (defined($ports) && $additions > $ports);
return undef;
}

1;
