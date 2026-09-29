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

1;
