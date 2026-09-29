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

1;
