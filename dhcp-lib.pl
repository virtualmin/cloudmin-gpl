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

# supports_dhcpd()
# Returns 1 if a DHCP server is configured and running on the Cloudmin master
# system, or 0 if not. In an array context, returns an error message too.
sub supports_dhcpd
{
my @rv;
if (!&foreign_check("dhcpd")) {
	@rv = ( 0, $text{'dhcpd_emod'} );
	}
elsif (!&foreign_installed("dhcpd")) {
	@rv = ( 0, $text{'dhcpd_eserver'} );
	}
else {
	&foreign_require("dhcpd");
	if (!&dhcpd::is_dhcpd_running()) {
		@rv = ( 0, $text{'dhcpd_erunning'} );
		}
	else {
		@rv = ( 1 );
		}
	}
return wantarray ? @rv : $rv[0];
}

# get_iface_dhcpd(&server, &iface)
# Returns undef if there is no DHCP server configuration entry for some 
# system and network interface, the host object otherwise
sub get_iface_dhcpd
{
my ($server, $iface) = @_;
&foreign_require("dhcpd");
my $pconf = &get_parent_config();
my ($host, $par) = &recursive_dhcpd_search($pconf, $server);
return wantarray ? ( $host, $par ) : $host;
}

# recursive_dhcpd_search(&parent-object, &server)
# Checks an object and all children to see if it is a host for some server
sub recursive_dhcpd_search
{
my ($pconf, $server) = @_;
foreach my $obj (@{$pconf->{'members'}}) {
	if ($obj->{'name'} eq 'host' &&
	    $obj->{'values'}->[0] eq $server->{'host'}) {
		return ( $obj, $pconf );
		}
	if ($obj->{'type'}) {
		my @rv = &recursive_dhcpd_search($obj, $server);
		return @rv if (@rv);
		}
	}
return ( );
}

# save_iface_dhcpd(&server, &iface, &old-iface)
# Updates the DHCP server configuration for some system and network interface,
# perhaps for a MAC or IP change
sub save_iface_dhcpd
{
my ($server, $iface, $oldiface) = @_;
}

# delete_iface_dhcpd(&server, &iface)
# Removes any DHCPd configuration entry for an interface
sub delete_iface_dhcpd
{
}

1;

