# Functions for managing firewall rules to limit the IPs or MACs used by a VM

# check_firewall_allowed_ips(&server)
# Checks if a firewall to limit allowed IPs can be setup for some system.
# Returns undef on success, or an error message on failure.
sub check_firewall_allowed_ips
{
my ($server) = @_;
my $vhost = &get_parent_server($server);
if (!$vhost) {
	return "No host system found!";
	}
if (!&has_command_on_server($vhost, "ebtables")) {
	return "The ebtables command was not found on $vhost->{'host'}";
	}
return undef;
}

# save_firewall_allowed_ips(&server, &ips)
# Updates the list of IPs and mac addresses that a VM is allowed to use. Returns
# undef on success, or an error mesage on failure.
# XXX delete?
sub save_firewall_allowed_ips
{
my ($server, $ips) = @_;
my $vhost = &get_parent_server($server);
if (!$vhost) {
	return "No host system found!";
	}

# Update eth0.sh file

# Apply firewall rules, if VM is running

return undef;
}

# get_firewall_commands(&server, &addrs, interface)
# Returns a list of ebtables commands to limit traffic to given addrs on some
# interface. The commands will allow traffic whose source or dest is on the 
# list, and then block everything else on the interface.
sub get_firewall_commands
{
my ($server, $addrs, $iface) = @_;
my @rv;
my @ips = grep { &check_ipaddress($_) || &check_ip6address($_) } @$addrs;
my @macs = grep { &check_macaddress($_) } @$addrs;
my $chain = $server->{'id'};
push(@rv, "ebtables -D INPUT -j $chain 2>/dev/null");
push(@rv, "ebtables -D OUTPUT -j $chain 2>/dev/null");
push(@rv, "ebtables -D FORWARD -j $chain 2>/dev/null");
push(@rv, "ebtables -X $chain 2>/dev/null");
if (@ips || @macs) {
	push(@rv, "ebtables -N $chain");
	push(@rv, "ebtables -I INPUT -j $chain");
	push(@rv, "ebtables -I OUTPUT -j $chain");
	push(@rv, "ebtables -I FORWARD -j $chain");
	push(@rv, "ebtables -A $chain -p ARP -i $iface -j ACCEPT");
	}
foreach my $ip (@ips) {
	# Allow if from the IP and one of the MACs
	foreach my $mac (@macs) {
		if (&check_ipaddress($ip)) {
			push(@rv, "ebtables -A $chain -p IPv4 -i $iface ".
				  "-s $mac --ip-source $ip -j ACCEPT");
			push(@rv, "ebtables -A $chain -p IPv4 -i $iface ".
				  "-d $mac --ip-destination $ip -j ACCEPT");
			}
		else {
			push(@rv, "ebtables -A $chain -p IPv6 -i $iface ".
				  "-s $mac --ip6-source $ip -j ACCEPT");
			push(@rv, "ebtables -A $chain -p IPv6 -i $iface ".
				  "-d $mac --ip6-destination $ip -j ACCEPT");
			}
		}
	}
if (!@ips && @macs) {
	# If only MAC addresses are known (like for a Windows VM), allow them
	# regardless of IP
	foreach my $mac (@macs) {
		push(@rv, "ebtables -A $chain -i $iface -s $mac -j ACCEPT");
		push(@rv, "ebtables -A $chain -i $iface -d $mac -j ACCEPT");
		}
	}
if (@ips || @macs) {
	push(@rv, "ebtables -A $chain -i $iface -j DROP");
	}
return @rv;
}

# get_all_firewall_addresses(&server)
# Returns a list of IPv4, v6 and MAC addresses for a system
sub get_all_firewall_addresses
{
my ($server) = @_;
return ( &get_server_ip($server),
	 &get_server_ip6($server),
	 &get_server_mac($server) );
}

# activate_firewall_commands(&server, ips-list, iface)
# Run the ebtables commands to limit the allowed IPs for a server, or allow all
sub activate_firewall_commands
{
my ($server, $ipslist, $iface) = @_;
my $vhost = &type_kvm_parent($server);
my @ips = $ipslist eq '' ? ( ) :
	  $ipslist eq '*' ? &get_all_firewall_addresses($server) :
			    ( split(/\s+/, $ipslist),
			       &get_server_mac($server) );
my @cmds = &get_firewall_commands($server, \@ips, $iface);
my $cmd = join(" ; ", @cmds);
my ($out, $ex, $err) = &execute_command_on_server($vhost, $cmd);
return $err ? $err : $ex ? $out : undef;
}

1;
