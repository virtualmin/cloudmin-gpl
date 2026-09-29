package Cloudmin::Networks;

# Local network inventory and libvirt changes. Host bridge transactions live in
# HostNetwork so host configuration can be restored independently.
use strict;
use warnings;
use Socket qw(AF_INET AF_INET6 inet_pton inet_ntop);
use Digest::SHA qw(sha256_hex);
use File::Basename qw(dirname);
require(dirname(__FILE__).'/Libvirt.pm');

# new(class, adapter => object, host => object, jobs => object)
# Shares the VM controller lock with creation and hardware changes.
sub new
{
my ($class, %opts) = @_;
return bless(\%opts, $class);
}

# cidr(value, [family])
# Validates an IP/prefix and returns its canonical address and network bits.
sub cidr
{
# Parse the family and prefix before comparing or building network ranges.
my ($value, $family) = @_;
die "Enter an IP address followed by /prefix\n"
	if (!defined($value) || ref($value) || $value !~ /\A([^\/\s]+)\/(\d{1,3})\z/);
my ($address, $prefix) = ($1, int($2));
my $af = $address =~ /:/ ? AF_INET6 : AF_INET;
my $bits = $af == AF_INET6 ? 128 : 32;
die "Use an IPv$family address\n" if ($family && $family != ($bits == 128 ? 6 : 4));
my $packed = inet_pton($af, $address);
die "Invalid IP address or prefix\n" if (!$packed || $prefix < 1 || $prefix > $bits);
my $binary = unpack('B*', $packed);
return { address => inet_ntop($af, $packed), prefix => $prefix,
	family => $bits == 128 ? 6 : 4, bits => $binary,
	network => substr($binary, 0, $prefix),
	cidr => inet_ntop($af, $packed).'/'.$prefix };
}

# overlap(first, second)
# Compares validated subnets without losing IPv6 precision.
sub overlap
{
my ($a, $b) = @_;
return 0 if ($a->{'family'} != $b->{'family'});
my $length = $a->{'prefix'} < $b->{'prefix'} ? $a->{'prefix'} : $b->{'prefix'};
return substr($a->{'bits'}, 0, $length) eq substr($b->{'bits'}, 0, $length);
}

# name(value)
# Restricts names used by libvirt, interface backends and unit arguments.
sub name
{
my ($value) = @_;
die "Use a name starting with a letter, followed by letters, numbers, _ or - (15 characters maximum)\n"
	if (!defined($value) || ref($value) || $value !~ /\A[a-zA-Z][a-zA-Z0-9_-]{0,14}\z/);
return $value;
}

# guest_links(self)
# Includes live and saved NICs, so pending hardware changes still protect a network.
sub guest_links
{
my ($self) = @_;
my @links;
foreach my $domain ($self->{'adapter'}->connect()->list_all_domains(0)) {
	my %seen;
	my @flags = ($domain->is_persistent() ? (2) : (), $domain->is_active() ? (0) : ());
	foreach my $flag (@flags) {
		my $doc = Cloudmin::Libvirt::parse_xml_document($domain->get_xml_description($flag));
		foreach my $nic ($doc->findnodes('/domain/devices/interface')) {
			my $network = $nic->findvalue('source/@network');
			my $bridge = $nic->findvalue('source/@bridge');
			my $device = $nic->findvalue('source/@dev');
			next if ((!$network && !$bridge && !$device) || $seen{"$network\0$bridge\0$device"}++);
			push(@links, { uuid => $domain->get_uuid_string(), name => $domain->get_name(),
				network => $network, bridge => $bridge, device => $device, active => $domain->is_active() ? 1 : 0 });
			}
		}
	}
return \@links;
}

# inventory(self)
# Combines libvirt networks with persistent and live host bridge information.
sub inventory
{
my ($self) = @_;
my $host = $self->{'host'}->inventory();
my $links = $self->guest_links();
my (@networks, %owned);
foreach my $net ($self->{'adapter'}->connect()->list_all_networks(0)) {
	my $xml = $net->get_xml_description(0);
	my $doc = Cloudmin::Libvirt::parse_xml_document($xml);
	my $record = $self->{'adapter'}->get_network_record($net);
	$record->{'revision'} = sha256_hex($xml);
	$record->{'uplink'} = $doc->findvalue('/network/forward/@dev');
	$record->{'addresses'} = [];
	$record->{'ranges'} = [];
	foreach my $ip ($doc->findnodes('/network/ip')) {
		my $prefix = $ip->getAttribute('prefix') // '';
		my $mask = $ip->getAttribute('netmask') // '';
		# Show existing dotted netmasks in the same CIDR form as new networks.
		$prefix = eval { $self->{'host'}->mask_prefix($mask) } // ''
			if ($prefix eq '' && $mask);
		push(@{$record->{'addresses'}}, $ip->getAttribute('address').
			($prefix ne '' ? '/'.$prefix : $mask ? ' / '.$mask : ''));
		push(@{$record->{'ranges'}}, map { $_->getAttribute('start').' - '.$_->getAttribute('end') }
			$ip->findnodes('dhcp/range'));
		}
	$record->{'guests'} = [grep { $_->{'network'} eq $record->{'name'} ||
		($record->{'bridge'} && $_->{'bridge'} eq $record->{'bridge'}) } @$links];
	$owned{$record->{'bridge'}} = 1 if ($record->{'bridge'} &&
		$record->{'forward'} =~ /\A(?:nat|route|isolated)\z/);
	push(@networks, $record);
	}
my @bridges = grep { $_->{'bridge'} && !$owned{$_->{'name'}} } @{$host->{'interfaces'}};
# Associate bridges with guests attached through a libvirt bridge network.
foreach my $bridge (@bridges) {
	my %networks = map { $_->{'name'} => 1 } grep {
		($_->{'bridge'} || '') eq $bridge->{'name'} } @networks;
	$bridge->{'guests'} = [grep { $_->{'bridge'} eq $bridge->{'name'} ||
		$networks{$_->{'network'}} } @$links];
	# Even an unused libvirt network can still depend on this host bridge.
	$bridge->{'networks'} = [map { $_->{'name'} } grep {
		($_->{'bridge'} || '') eq $bridge->{'name'} ||
		($_->{'uplink'} || '') eq $bridge->{'name'} } @networks];
	}
return { %$host, networks => [sort { lc($a->{'name'}) cmp lc($b->{'name'}) } @networks],
	bridges => \@bridges };
}

# prepare_bridge(self, name, source)
# Refuses to move an interface still named by a guest or libvirt forwarding rule.
sub prepare_bridge
{
my ($self, $name, $source) = @_;
die "This interface is used directly by a virtual machine\n"
	if (grep { ($_->{'device'} || '') eq $source } @{$self->guest_links()});
foreach my $network ($self->{'adapter'}->connect()->list_all_networks(0)) {
	my $doc = Cloudmin::Libvirt::parse_xml_document($network->get_xml_description(0));
	die "This interface is an explicit uplink for network ".$network->get_name()."; update that network first\n"
		if (grep { $_->getValue() eq $source }
			$doc->findnodes('/network/forward/@dev | /network/forward/interface/@dev'));
	}
return $self->{'host'}->prepare($name, $source);
}

# prepare_bridge_removal(self, name)
# Includes saved VM and network references, not just currently attached ports.
# name is the host bridge; returns the host controller's reviewed removal plan.
sub prepare_bridge_removal
{
my ($self, $name) = @_;
name($name);
my $plan = $self->{'host'}->prepare_remove($name);
my %devices = map { $_ => 1 } ($name, $plan->{'source'});
# Stopped guests and direct Ethernet attachments also reserve these devices.
die "Detach virtual machines from this bridge and its Ethernet port before removing it\n"
	if (grep { $devices{$_->{'bridge'} || ''} || $devices{$_->{'device'} || ''} }
		@{$self->guest_links()});
foreach my $network ($self->{'adapter'}->connect()->list_all_networks(0)) {
	# Check inactive XML as well as live XML for pending persistent changes.
	foreach my $flag ($network->is_persistent() ? (0, 1) : (0)) {
		my $doc = Cloudmin::Libvirt::parse_xml_document($network->get_xml_description($flag));
		# A network can depend on the bridge as its device or as its uplink.
		die "Network ".$network->get_name()." uses this bridge or its port; update that network first\n"
			if (grep { $devices{$_->getValue()} } $doc->findnodes(
				'/network/bridge/@name | /network/forward/@dev | /network/forward/interface/@dev'));
		}
	}
return $plan;
}

# assert_idle(self)
# A queued VM may already reference a network even before libvirt has its NIC.
sub assert_idle
{
my ($self) = @_;
die "Wait for the pending bridge change to finish\n" if ($self->{'host'}->pending());
my @active = grep { $_->{'state'} !~ /\A(?:complete|failed|cancelled)\z/ }
	@{$self->{'jobs'}->list(undef, 1)};
die "Wait for virtual machine operations to finish before changing networking\n" if (@active);
}

# prepare_network(self, input)
# Builds a persistent NAT, routed or isolated network after subnet validation.
sub prepare_network
{
my ($self, $in) = @_;
my $name = name($in->{'name'});
my $mode = $in->{'mode'} || '';
die "Select NAT, routed or isolated networking\n" if ($mode !~ /\A(?:nat|route|isolated)\z/);
# Validate gateways and subnet sizes before checking host route conflicts.
my $v4 = cidr($in->{'ipv4'}, 4);
die "Use an IPv4 prefix from 8 to 30\n" if ($v4->{'prefix'} < 8 || $v4->{'prefix'} > 30);
my $hostbits = substr($v4->{'bits'}, $v4->{'prefix'});
die "The gateway must be a host address, not the subnet or broadcast address\n"
	if ($hostbits !~ /1/ || $hostbits !~ /0/);
my @subnets = ($v4);
push(@subnets, cidr($in->{'ipv6'}, 6)) if (length($in->{'ipv6'} || ''));
die "Use an IPv6 /64 network\n" if (@subnets > 1 && $subnets[1]->{'prefix'} != 64);
foreach my $subnet (@subnets) {
	# Gateways must be ordinary unicast addresses, never loopback or multicast.
	my $address = $subnet->{'address'};
	die "Use a unicast gateway address\n" if ($subnet->{'family'} == 4
		? $address =~ /\A(?:0|127|169\.254|22[4-9]|23\d|24\d|25[0-5])\./
		: $address !~ /\A(?:[23][0-9a-f]{3}|f[cd][0-9a-f]{2}):/i);
	}
my $host = $self->{'host'}->inventory();
# An explicit uplink must be live; isolated networks cannot forward through it.
my $uplink = $in->{'uplink'} || '';
die "Select an existing uplink interface\n" if ($uplink && !grep {
	$_->{'name'} eq $uplink && $_->{'active'} && !$_->{'loopback'} } @{$host->{'interfaces'}});
die "An isolated network cannot have an uplink\n" if ($mode eq 'isolated' && $uplink);
# Reserve names and include inactive libvirt subnets in overlap detection.
my @existing = @{$host->{'subnets'}};
foreach my $net ($self->{'adapter'}->connect()->list_all_networks(0)) {
	die "A network with this name already exists\n" if ($net->get_name() eq $name);
	my $doc = Cloudmin::Libvirt::parse_xml_document($net->get_xml_description(0));
	foreach my $ip ($doc->findnodes('/network/ip')) {
		my $prefix = $ip->getAttribute('prefix') // '';
		$prefix = $self->{'host'}->mask_prefix($ip->getAttribute('netmask'))
			if ($prefix eq '' && $ip->getAttribute('netmask'));
		$prefix = ($ip->getAttribute('family') || '') eq 'ipv6' ? 64 : 24 if ($prefix eq '');
		push(@existing, $ip->getAttribute('address').'/'.$prefix);
		}
	}
foreach my $new (@subnets) {
	# Compare binary prefixes so IPv6 checks retain all address bits.
	foreach my $old (@existing) {
		my $parsed = eval { cidr($old) };
		die "The proposed subnet overlaps $old; choose an unused subnet\n"
			if ($parsed && overlap($new, $parsed));
		}
	}
require XML::LibXML;
my $doc = XML::LibXML::Document->new('1.0', 'UTF-8');
my $root = $doc->createElement('network');
$doc->setDocumentElement($root);
$root->appendTextChild('name', $name);
# Omitting forwarding creates a host-only isolated network.
if ($mode ne 'isolated') {
	my $forward = $root->addNewChild(undef, 'forward');
	$forward->setAttribute('mode', $mode);
	$forward->setAttribute('dev', $uplink) if ($uplink);
	$forward->addNewChild(undef, 'nat')->setAttribute('ipv6', 'yes')
		if ($mode eq 'nat' && @subnets > 1);
	}
# Libvirt assigns a virbr* name, covered by the installed host DHCP/DNS rules.
foreach my $subnet (@subnets) {
	my $ip = $root->addNewChild(undef, 'ip');
	$ip->setAttribute('address', $subnet->{'address'});
	$ip->setAttribute('prefix', $subnet->{'prefix'});
	$ip->setAttribute('family', 'ipv6') if ($subnet->{'family'} == 6);
	# DHCP ranges are IPv4-only and must exclude reserved subnet addresses.
	if ($subnet->{'family'} == 4 && $in->{'dhcp'}) {
		my @range;
		foreach my $field (qw(dhcp_start dhcp_end)) {
			my $item = cidr(($in->{$field} || '').'/32', 4);
			my $suffix = substr($item->{'bits'}, $v4->{'prefix'});
			die "DHCP addresses must be inside the subnet and exclude the gateway, subnet and broadcast addresses\n"
				if (!overlap($v4, $item) || $item->{'address'} eq $v4->{'address'} ||
				$suffix !~ /1/ || $suffix !~ /0/);
			push(@range, $item);
			}
		die "The DHCP range must be ordered and must not contain the gateway\n"
			if ($range[0]->{'bits'} gt $range[1]->{'bits'} ||
			($range[0]->{'bits'} le $v4->{'bits'} && $range[1]->{'bits'} ge $v4->{'bits'}));
		my $range = $ip->addNewChild(undef, 'dhcp')->addNewChild(undef, 'range');
		$range->setAttribute('start', $range[0]->{'address'});
		$range->setAttribute('end', $range[1]->{'address'});
		}
	}
return { name => $name, xml => $doc->toString(), mode => $mode,
	autostart => $in->{'autostart'} ? 1 : 0 };
}

# create(self, input)
# Defines and starts a validated network, removing only our definition on failure.
sub create
{
my ($self, $in) = @_;
return $self->{'jobs'}->lock('create-host', sub {
	$self->assert_idle();
	my $plan = $self->prepare_network($in);
	my $net;
	my $ok = eval {
		Cloudmin::Libvirt::log_call('Sys::Virt::define_network', { name => $plan->{'name'}, mode => $plan->{'mode'} });
		$net = $self->{'adapter'}->connect()->define_network($plan->{'xml'});
		$net->set_autostart($plan->{'autostart'});
		$net->create();
		1;
		};
	my $error = $@;
	# Undo a partially created network without touching existing definitions.
	if (!$ok && $net) {
		my $cleanup = eval { $net->destroy() if ($net->is_active()); $net->undefine(); 1 };
		$error .= " Network cleanup failed: $@" if (!$cleanup);
		}
	die $error if (!$ok);
	return $plan->{'name'};
	});
}

1;
