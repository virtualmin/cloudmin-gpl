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
my $pconf = &dhcpd::get_parent_config();
my ($host, $par) = &recursive_dhcpd_search($pconf, $server, $iface);
return wantarray ? ( $host, $par ) : $host;
}

# recursive_dhcpd_search(&parent-object, &server, &iface)
# Checks an object and all children to see if it is a host for some server
sub recursive_dhcpd_search
{
my ($pconf, $server, $iface) = @_;
foreach my $obj (@{$pconf->{'members'}}) {
	if ($obj->{'name'} eq 'host' &&
	    $obj->{'type'} &&
	    $obj->{'values'}->[0] eq $server->{'host'}) {
		# Matches the host .. check the IP and MAC address too
		my $fixed = &dhcpd::find("fixed-address", $obj->{'members'});
		if ($fixed->{'values'}->[0] eq $iface->{'address'}) {
			return ( $obj, $pconf );
			}
		}
	if ($obj->{'type'}) {
		my @rv = &recursive_dhcpd_search($obj, $server, $iface);
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
&foreign_require("dhcpd");
my ($host, $pconf);
if ($oldiface) {
	($host, $pconf) = &get_iface_dhcpd($server, $oldiface);
	}
my $file = $host ? $host->{'file'} : $dhcpd::config{'dhcpd_conf'};
my $changed = 0;
&lock_file($file);
if (!$host) {
	# Add new host object
	$host = { 'name' => 'host',
		  'type' => 1,
		  'values' => [ $server->{'host'} ],
		  'members' => [
			{ 'name' => 'fixed-address',
                          'values' => [ $iface->{'address'} ] },
			{ 'name' => 'hardware',
                          'values' => [ 'ethernet', $iface->{'ether'} ] },
			]
		};
	# XXX to what parent?
	# XXX indent level
	my $pconf = &dhcpd::get_parent_config();
	&dhcpd::save_directive($pconf, [ ], [ $host ]);
	$changed = 1;
	}
else {
	# Update IP and MAC in host object
	my $fixed = &dhcpd::find("fixed-address", $host->{'members'});
	if (!$fixed ||
	    $fixed->{'values'}->[0] ne $iface->{'address'}) {
		&dhcpd::save_directive($host, 'fixed-address',
			[ { 'name' => 'fixed-address',
			    'values' => [ $iface->{'address'} ] } ]);
		$changed = 1;
		}
	my $hard = &dhcpd::find("hardware", $host->{'members'});
	if (!$hard ||
	    $hard->{'values'}->[1] ne $iface->{'ether'}) {
		&dhcpd::save_directive($host, 'hardware',
			[ { 'name' => 'hardware',
			    'values' => [ 'ethernet', $iface->{'ether'} ] } ]);
		$changed = 1;
		}
	}
if ($changed) {
	&flush_file_lines($file);
	}
&unlock_file($file);
if ($changed) {
	&dhcpd::restart_dhcpd();
	}
}

# delete_iface_dhcpd(&server, &iface)
# Removes any DHCPd configuration entry for an interface
sub delete_iface_dhcpd
{
my ($server, $iface) = @_;
&foreign_require("dhcpd");
my ($host, $pconf) = &get_iface_dhcpd($server, $iface);
if ($host) {
	&lock_file($host->{'file'});
	&dhcpd::save_directive($pconf, [ $host ], [ ]);
	&flush_file_lines($host->{'file'});
	&unlock_file($host->{'file'});
	&dhcpd::restart_dhcpd();
	}
}

1;

