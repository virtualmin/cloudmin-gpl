# Functions for adding and removing DHCPd entries for virtual systems

# generate_mac_address(&server, interface-num)
# Returns a MAC address for use by a virtual system
sub generate_mac_address
{
my ($server, $ifacenum) = @_;
my $dec = (int(substr($server->{'id'}, -10)) & 0xffffff) + $ifacenum;
my $hex = sprintf("%6.6X", $dec);
$hex =~ /^(..)(..)(..)$/;
return ($type_mac_prefix{$server->{'manager'}} || "00:1c:c0").
       ":".$1.":".$2.":".$3;
}

1;

