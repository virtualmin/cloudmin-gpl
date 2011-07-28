# Functions for adding and removing DHCPd entries for virtual systems

# generate_mac_address(&server, interface-num)
# Returns a MAC address for use by a virtual system
sub generate_mac_address
{
my ($server, $ifacenum) = @_;
my $dec = (int(substr($server->{'id'}, -8)) & 0xffffff) + $ifacenum;
$dec += (time() & 0xffffff);
my $hex = sprintf("%6.6X", $dec);
$hex =~ /^(..)(..)(..)$/ || &error("Invalid MAC address $hex");
return ($type_mac_prefix{$server->{'manager'}} || "00:1c:c0").
       ":".$1.":".$2.":".$3;
}

# supports_dhcpd([ignore-running])
# Returns 1 if a DHCP server is configured and running on the Cloudmin master
# system, or 0 if not. In an array context, returns an error message too.
sub supports_dhcpd
{
my ($ignore) = @_;
my @rv;
if (!&foreign_check("dhcpd")) {
	# Webmin module not installed
	@rv = ( 0, $text{'dhcpd_emod'} );
	}
elsif (!&foreign_installed("dhcpd")) {
	# DHCPd not installed
	@rv = ( 0, $text{'dhcpd_eserver'} );
	}
elsif ($ignore) {
	# Don't care if running
	@rv = ( 1 );
	}
else {
	# Check if running
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
my ($host, $par) = &recursive_dhcpd_search_host($pconf, $server, $iface);
return wantarray ? ( $host, $par ) : $host;
}

# recursive_dhcpd_search(&parent-object, &server, &iface)
# Checks an object and all children to see if it is a host for some server
# and interface.
sub recursive_dhcpd_search_host
{
my ($pconf, $server, $iface) = @_;
my $hostname = $iface->{'name'} eq 'eth0' ?
		$server->{'host'} : $iface->{'name'}.'-'.$server->{'host'};
foreach my $obj (@{$pconf->{'members'}}) {
	if ($obj->{'name'} eq 'host' &&
	    $obj->{'type'} &&
	    $obj->{'values'}->[0] eq $hostname) {
		# Matches the host .. check the IP and MAC address too
		my $fixed = &dhcpd::find("fixed-address", $obj->{'members'});
		if ($fixed->{'values'}->[0] eq $iface->{'address'}) {
			return ( $obj, $pconf );
			}
		}
	if ($obj->{'type'}) {
		my @rv = &recursive_dhcpd_search_host($obj, $server, $iface);
		return @rv if (@rv);
		}
	}
return ( );
}

# recursive_dhcpd_search_subnet(&parent-object)
# Check an object and all its children to find the configured subnet to add to
sub recursive_dhcpd_search_subnet
{
my ($pconf) = @_;
foreach my $obj (@{$pconf->{'members'}}) {
	if ($obj->{'name'} eq 'subnet' &&
	    $obj->{'values'}->[0] eq $config{'dhcp_subnet'}) {
		# Found the subnet by IP address
		return $obj;
		}
	elsif ($obj->{'name'} eq 'group' &&
	       $obj->{'comment'} eq $config{'dhcp_subnet'}) {
		# Found the group by description
		return $obj;
		}
	if ($obj->{'type'}) {
		my $rv = &recursive_dhcpd_search_subnet($obj);
		return $rv if ($rv);
		}
	}
return undef;
}

# recursive_dhcpd_search_all_hosts(&parent-object, &server)
# Checks an object and all children to see if it is a host for some server,
# and returns a list of objects found
sub recursive_dhcpd_search_all_hosts
{
my ($pconf, $server) = @_;
my @rv;
foreach my $obj (@{$pconf->{'members'}}) {
	if ($obj->{'name'} eq 'host' &&
	    ($obj->{'values'}->[0] eq $server->{'host'} ||
	     $obj->{'values'}->[0] =~ /^eth(\d+)\.(\S+)$/ &&
	      $2 eq $server->{'host'})) {
		push(@rv, [ $obj, $pconf ]);
		}
	if ($obj->{'type'}) {
		push(@rv, &recursive_dhcpd_search_all_hosts($obj, $server));
		}
	}
return @rv;
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
my $hostname = $iface->{'name'} =~ /(\d+)$/ && $1 == 0 ? 
			$server->{'host'} :
			$iface->{'name'}.'-'.$server->{'host'};
if (!$host) {
	# Add new host object
	$host = { 'name' => 'host',
		  'comment' => 'Cloudmin system '.$server->{'id'}.
			       ' interface '.$iface->{'name'},
		  'type' => 1,
		  'values' => [ $hostname ],
		  'members' => [
			{ 'name' => 'fixed-address',
                          'values' => [ $iface->{'address'} ] },
			{ 'name' => 'hardware',
                          'values' => [ 'ethernet', $iface->{'ether'} ] },
			]
		};
	my $pconf = &dhcpd::get_parent_config();
	if ($config{'dhcp_subnet'}) {
		my $subnet = &recursive_dhcpd_search_subnet($pconf);
		if (!$subnet) {
			return &text('dhcpd_esubnet', $config{'dhcp_subnet'});
			}
		$pconf = $subnet;
		}
	&dhcpd::save_directive($pconf, [ ], [ $host ],
			       $config{'dhcp_subnet'} ? 1 : 0);
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
return undef;
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

# add_all_iface_dhcpd(&server, [&interfaces])
# Add a DHCPd entry for all interfaces with MAC addresses
sub add_all_iface_dhcpd
{
my ($server, $ifaces) = @_;
&$first_print($text{'create_xendhcpsetup'});
if (!$ifaces) {
	my $ifunc = "type_".$server->{'manager'}."_list_interfaces";
	if (!defined(&$ifunc)) {
		&$second_print($text{'create_exendhcpifaces'});
		return 0;
		}
	$ifaces = &$ifunc($server);
	if (!ref($ifaces)) {
		&$second_print(&text('create_xendhcperr', $ifaces));
		return 0;
		}
	}
my ($ok, $err) = &supports_dhcpd();
if (!$ok) {
	&$second_print(&text('create_exendhcpsupport', $err));
	return 0;
	}
&$indent_print();
my $ok = 0;
foreach my $iface (@$ifaces) {
	if ($iface->{'ether'}) {
		&$first_print(&text('create_xendhcp', $iface->{'address'},
						      $iface->{'ether'}));
		my $err = &save_iface_dhcpd($server, $iface);
		if ($err) {
			&$second_print(&text('create_exendhcp', $err));
			}
		else {
			&$second_print($text{'create_done'});
			$ok++;
			}
		}
	}
&$outdent_print();
&$second_print($text{'create_xendhcpdone'});
return $ok;
}

# delete_all_iface_dhcpd(&server)
# Remove all DHCPd entries for some host
sub delete_all_iface_dhcpd
{
my ($server) = @_;
if (!&supports_dhcpd(1)) {
	return 0;
	}
&foreign_require("dhcpd");
my $pconf = &dhcpd::get_parent_config();
my @hosts = &recursive_dhcpd_search_all_hosts($pconf, $server);
foreach my $h (@hosts) {
	my ($host, $par) = @$h;
	&lock_file($host->{'file'});
	&dhcpd::save_directive($par, [ $host ], [ ]);
	&flush_file_lines($host->{'file'});
	&unlock_file($host->{'file'});
	}
if (@hosts) {
	&dhcpd::restart_dhcpd();
	}
return scalar(@hosts);
}

1;

