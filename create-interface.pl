#!/usr/local/bin/perl

=head1 create-interface.pl

Adds a new network interface to some system

This program adds a virtual interface to some Cloudmin-managed system. You must
specify the system with the C<--host> parameter, and the base interface with
C<--name>. The IP address can be either explitly set with C<--address>, or
Cloudmin can allocate a free IP from the range defined for the host system with
C<--allocate>.

On Xen and KVM systems an additional real network interface can be created
with the C<--real> flag. In this case, the C<--name> parameter must be followed
by an interface that does not exist yet, like I<eth1>. If the host system has
multiple bridges, the C<--bridge> flag can be used to select a bridge, like
I<xenbr0>.

Xen, KVM and physical systems running Linux can also have IPv6 addresses
added to new real interfaces using this command. To add an address, use the
C<--add-address6> flag followed by an IPv6 address or address/netmask.

For KVM and Xen systems using HVM, the C<--model> flag can be used to set
the type of network card that is emulated on the virtual system. This is
only possible for real interfaces though.

Either way, the full interface name and IP address will be displayed if the
command completes successfully.

=head1 Example usage

  cloudmin create-interface --host vvirtualmin.home --name eth0 --address 193.9.101.250
  Created interface eth0:3 with address 193.9.101.250

=cut

package server_manager;
$main::no_acl_check++;
$ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
$ENV{'WEBMIN_VAR'} ||= "/var/webmin";
if ($0 =~ /^(.*)\/[^\/]+$/) {
	chdir($pwd = $1);
	}
else {
	chop($pwd = `pwd`);
	}
$0 = "$pwd/create-interface.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";
@OLDARGV = @ARGV;
&usage_if_cloudmin_replica();

# Parse command line
while(@ARGV > 0) {
	my $a = shift(@ARGV);
	if ($a eq "--host") {
		$host = shift(@ARGV);
		}
	elsif ($a eq "--name") {
		$name = shift(@ARGV);
		}
	elsif ($a eq "--address") {
		$address = shift(@ARGV);
		}
	elsif ($a eq "--netmask") {
		$netmask = shift(@ARGV);
		}
	elsif ($a eq "--allocate") {
		$allocate = 1;
		}
	elsif ($a eq "--real") {
		$nonvirt = 1;
		}
	elsif ($a eq "--bridge") {
		$bridge = shift(@ARGV);
		}
	elsif ($a eq "--model") {
		$model = shift(@ARGV);
		}
	elsif ($a eq "--address6") {
		$address6 = shift(@ARGV);
		&check_ip6address($address6) ||
		    $address6 =~ /^(\S+)\/\d+$/ && &check_ip6address("$1") ||
			&usage("--address6 must be followed by an ".
			       "IPv6 address");
		push(@add6, $address6);
		}
	elsif ($a eq "--multiline") {
		$multiline = 1;
		}
	else {
		&usage();
		}
	}
$name || &usage("Missing --name parameter");

# Get the server
$host || &usage("Missing --host parameter");
$server = &get_managed_server_by("host", $host);
$server || &usage("System with hostname $host does not exist");
$cfunc = "type_".$server->{'manager'}."_can_interfaces";
defined(&$cfunc) && &$cfunc($server) ||
	&usage("Interfaces cannot be managed on this system");
$can = &$cfunc($server);
$can || &usage("Network interfaces cannot be managed on this system");

# Validate params against server
if ($can == 3) {
	($address || $allocate || $netmask) &&
	    &usage("No address can be set for network interfaces on this system");
	}
else {
	$address || $allocate ||
		&usage("One of --address or --allocate must be given");
	!$address || &check_ipaddress($address) || &usage("Invalid IP address");
	!$netmask || &check_ipaddress($netmask) || &usage("Invalid netmask");
	}
&can_action_usage($server, "ifaces");

&obtain_lock_server($server);

# Check if over limit
$limits = &get_owner_limits();
if ($limits && $limits->{'max_ips'}) {
	if ($limits->{'ips'} + 1 > $limits->{'max_ips'}) {
		&usage("Adding this interface would exceed your IP address ",
		       "limit of ",$limits->{'max_ips'});
		}
	}

# Check the function and status
$ifunc = "type_".$server->{'manager'}."_create_interface";
defined(&$ifunc) || &usage("System type $server->{'manager'} does not support ".
			   "network interface management");
$server->{'status'} eq 'nohost' && &usage("Host for system is down");

# Get the parent network interfaces
$pfunc = "type_".$server->{'manager'}."_list_parent_interfaces";
$parents = &$pfunc($server);
ref($parents) || &usage("Failed to get parent network interfaces : $parents");
($piface) = grep { $_->{'fullname'} eq $name &&
		   $_->{'virtual'} eq '' } @$parents;
if ($nonvirt) {
	&can_action_usage($server, "realifaces");
	$can >= 2 || &usage("Real interfaces cannot be added ".
			    "to this virtual system");
	$piface && &usage("A real interface named $name already exists");
	if ($bridge) {
		$vhost = &get_parent_server($server);
		@bridges = &list_host_bridges($vhost);
		&indexof($bridge, @bridges) >= 0 ||
			&usage("Bridge $bridge does not exist on host system. ".
			       "Available bridges are : ".join(" ", @bridges));
		}
	}
else {
	$can >= 3 && &usage("Only real interfaces can be created on ".
			    "this system");
	$bridge && &usage("The --bridge parameter can only be used ".
			  "with --real");
	$model && &usage("The --model parameter can only be used ".
			 "with --real");
	$piface || &usage("No real interface named $name found. ".
			  "Existing interfaces are : ".
			  join(" ", map { $_->{'fullname'} }
				grep { $_->{'virtual'} eq '' } @$parents));
	}

# Check for clashes
%used = &used_ip_addresses();
if ($address) {
	$u = $used{$address};
	$u && &usage("The IP address $address is already in use by $u->{'host'}");
	&ping_server_host($address) &&
		&usage("The IP address $address is being used by another ".
		       "system on your network");
	}
foreach $ip (@add6) {
	$u = $used{$ip};
	$u && &usage("The IPv6 address $ip is already in use by $u->{'host'}");
	&ping_server_host($ip) &&
		&usage("The IPv6 address $ip is being used by another ".
		       "system on your network");
	}

# Create the interface object
$iface = { 'name' => $name };
if ($can != 3) {
	if (!$allocate) {
		&can_action($server, "ips") ||
			&usage("You are not allowed to specify IP addresses - ".
			       "use the --allocate flag instead");
		$iface->{'address'} = $address;
		}
	if ($netmask) {
		$iface->{'netmask'} = $netmask;
		}
	else {
		$iface->{'netmask'} = $piface->{'netmask'};
		}
	}
if ($bridge) {
	$iface->{'bridge'} = $bridge;
	}

# Validate and store the model
if ($model) {
	$lfunc = "type_".$server->{'manager'}."_list_models";
	defined(&$lfunc) || &usage("This virtual system type does not support ".
				   "setting the network interface model");
	$models = &$lfunc($server);
	ref($models) || &usage("Failed to list models : $models");
	($m) = grep { $_->[0] eq $model } @$models;
	$m || &usage("Model $model is not valid - options are : ".
		     join(" ", map { $_->[0] } @$models));
	$iface->{'model'} = $model;
	}
else {
	# Use default model
	$dmfunc = "type_".$server->{'manager'}."_get_default_model";
	$iface->{'model'} = defined(&$dmfunc) ? &$dmfunc($server) : undef;
	}

# Add IPv6 interfaces
if (@add6) {
	$iface->{'virtual'} eq '' ||
		&usage("IPv6 addresses can only be added to real interfaces");
	$cfunc = "type_".$server->{'manager'}."_can_ipv6";
	defined(&$cfunc) && &$cfunc($server) ||
		&usage("IPv6 interfaces cannot be managed on this system");
	&can_action($server, "ips") ||
		&usage("You are not allowed to add IPv6 addresses");
	foreach my $a (@add6) {
		my ($ip, $nm) = split(/\//, $a);
		$nm ||= 64;
		push(@{$iface->{'address6'}}, $ip);
		push(@{$iface->{'netmask6'}}, $nm);
		}
	}

# Call the create function
$err = &$ifunc($server, $iface, $nonvirt);
if ($err) {
	&usage("Interface creation failed : $err");
	}
elsif ($iface->{'address'}) {
	print "Created interface $iface->{'fullname'} with address $iface->{'address'}\n";
	}
else {
	print "Created interface $iface->{'fullname'}\n";
	}

# Update DHCPd config, if enabled
if ($config{'dhcp_add'} && &supports_dhcpd(1) &&
    $iface->{'virtual'} eq '' && $iface->{'ether'}) {
	&save_iface_dhcpd($server, $iface, undef);
	}

&compute_ip_addresses($server);
&save_managed_server($server);
&release_lock_server($server);
if ($iface->{'reboot'} && $server->{'status'} ne 'down') {
	print "The virtual system must be rebooted before the new interface will be active.\n";
	}
&cloudmin_api_log(\@OLDARGV);

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Adds a network interface to some virtual system.\n";
print "\n";
print "cloudmin create-interfaces --host hostname\n";
print "                           --name interface\n";
print "                           --address ip.address | --allocate\n";
print "                          [--netmask ip.netmask]\n";
print "                          [--real [--bridge name] [--model type]]\n";
print "                          [--address6 ipv6-address]*\n";
exit(1);
}

