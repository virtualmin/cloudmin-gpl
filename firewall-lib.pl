# Functions for managing firewall rules to limit the IPs or MACs used by a VM

# get_firewall_allowed_ips(&server)
# Returns a list of IP addresses and MAC addresses that a VM is allowed to use,
# as an array ref. On error returns an error message.
sub get_firewall_allowed_ips
{
my ($server) = @_;
my $vhost = &get_parent_server($server);
if (!$vhost) {
	return "No host system found!";
	}
if (!&has_command_on_server($vhost, "ebtables")) {
	return "The ebtables command was not found on $vhost->{'host'}";
	}
# XXX
return [ ];
}

# save_firewall_allowed_ips(&server, &ips)
# Updates the list of IPs and mac addresses that a VM is allowed to use. Returns
# undef on success, or an error mesage on failure.
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
push(@rv, "ebtables -D FORWARD -j $chain");
if (@ips) {
	push(@rv, "ebtables -X $chain");
	push(@rv, "ebtables -N $chain");
	push(@rv, "ebtables -I FORWARD -j $chain");
	}
foreach my $ip (@ips) {
	# Allow if from the IP and one of the MACs
	my $proto = &check_ipaddress($ip) ? "IPv4" : "IPv6";
	foreach my $mac (@macs) {
		push(@rv, "ebtables -A $chain -p $proto -i $iface -s $mac --ip-source $ip -j ACCEPT");
		push(@rv, "ebtables -A $chain -p $proto -i $iface -d $mac --ip-destination $ip -j ACCEPT");
		}
	}
if (@ips) {
	push(@rv, "ebtables -A $chain -i $iface -j DROP");
	}
return @rv;
}

1;
