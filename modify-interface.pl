#!/usr/local/bin/perl

=head1 modify-interface.pl

Changes the IP or MAC address of an interface on some system.

This changes a virtual interface on some system, selected with the C<--host>
parameter. The interface to modify is set either with the C<--address> flag
followed by an IP, or the C<--name> flag followed by an name like I<eth0:1>.

The new IP address can be set with the C<--new-address> flag, the new MAC
with the C<--new-ether> flag, or the new netmask with the C<--new-netmask>
parameter. Alternately you can have Cloudmin tell the system to generate a MAC
address automatically with the C<--no-ether> flag.

Xen, KVM and physical systems running Linux can also have IPv6 addresses
added and removed using this command. To add an address, use the
C<--add-address6> flag followed by an IPv6 address or address/netmask. To
delete an existing v6 address, use the C<--remove-address6> flag.

For real network interfaces on KVM or Xen systems using HVM, you can set
the type of network card that is emulated on the virtual system with the
C<--new-model> flag followed by a model name. Or you can revert to the default
with the C<--no-model> flag.

For real network interfaces on Xen or KVM systems, you can change the host
network bridge the interface is connected to with the C<--new-bridge> 
flag, followed by a bridge name like C<br1> or C<xenbr1>. Alternately the
C<--no-bridge> flag can be used to revert the interface to the host's
default bridge.

=head1 Example usage

  cloudmin modify-interface --host vvirtualmin.home --address 193.9.101.250 --new-mac 02:54:00:50:DE:44
  Modified interface eth0

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
$0 = "$pwd/modify-interface.pl";
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
	elsif ($a eq "--address") {
		$address = shift(@ARGV);
		}
	elsif ($a eq "--name") {
		$name = shift(@ARGV);
		}
	elsif ($a eq "--new-address") {
		$newaddress = shift(@ARGV);
		&check_ipaddress($newaddress) ||
		    &usage("--new-address must be followed by an IP address");
		}
	elsif ($a eq "--new-netmask") {
		$newnetmask = shift(@ARGV);
		&check_ipaddress($newnetmask) ||
		    &usage("--new-netmask must be followed by an IP netmask");
		}
	elsif ($a eq "--new-ether") {
		$newether = shift(@ARGV);
		$newether =~ /^[A-Fa-f0-9:]+$/ ||
		    &usage("--new-ether must be followed by a MAC address");
		}
	elsif ($a eq "--no-ether") {
		$noether = 1;
		}
	elsif ($a eq "--new-model") {
		$newmodel = shift(@ARGV);
		}
	elsif ($a eq "--no-model") {
		$nomodel = 1;
		}
	elsif ($a eq "--add-address6") {
		$address6 = shift(@ARGV);
		&check_ip6address($address6) ||
		    $address6 =~ /^(\S+)\/\d+$/ && &check_ip6address("$1") ||
			&usage("--add-address6 must be followed by an ".
			       "IPv6 address");
		push(@add6, $address6);
		}
	elsif ($a eq "--remove-address6") {
		$address6 = shift(@ARGV);
		&check_ip6address($address6) ||
			&usage("--remove-address6 must be followed by an ".
			       "IPv6 address");
		push(@del6, $address6);
		}
	elsif ($a eq "--new-bridge") {
		$newbridge = shift(@ARGV);
		}
	else {
		&usage();
		}
	}
$address || $name || &usage("Missing --address or --name parameter");
$newaddress || $newnetmask || $newether || $noether || $newmodel || $nomodel ||
	$newbridge || $nobridge || @add6 || @del6 || &usage("Nothing to do");

# Get the server
$host || &usage("Missing --host parameter");
$server = &get_managed_server_by("host", $host);
$server || &usage("System with hostname $host does not exist");
&can_action_usage($server, "ifaces");
&obtain_lock_server($server);
$oldip = &get_server_ip($server);

# Check the function and status
$ifunc = "type_".$server->{'manager'}."_list_interfaces";
defined(&$ifunc) || &usage("System type $server->{'manager'} does not support ".
			   "network interface management");
$cfunc = "type_".$server->{'manager'}."_can_interfaces";
defined(&$cfunc) && &$cfunc($server) ||
	&usage("Interfaces cannot be managed on this system");
$server->{'status'} eq 'nohost' && &usage("Host for system is down");

# Validate the model
if ($newmodel) {
	$iface->{'virtual'} eq '' ||
		&usage("The --new-model parameter can only be used with ".
		       "real interfaces");
	$lfunc = "type_".$server->{'manager'}."_list_models";
	defined(&$lfunc) || &usage("This virtual system type does not support ".
				   "setting the network interface model");
	$models = &$lfunc($server);
	ref($models) || &usage("Failed to list models : $models");
	($m) = grep { $_->[0] eq $newmodel } @$models;
	$m || &usage("Model $newmodel is not valid - options are : ".
		     join(" ", map { $_->[0] } @$models));
	}

# Validate the bridge
if ($newbridge) {
	$vhost = &get_parent_server($server);
	$iface->{'virtual'} eq '' ||
		&usage("The --new-bridge parameter can only be used with ".
		       "real interfaces");
	@bridges = &list_host_bridges($vhost);
	&indexof($newbridge, @bridges) >= 0 ||
		&usage("Bridge $newbridge is not valid - options are : ".
		       join(" ", @bridges));
	}

# Get the interface
$ifaces = &$ifunc($server);
ref($ifaces) || &usage("Failed to list network interfaces : $ifaces");
if ($address) {
	($iface) = grep { $_->{'address'} eq $address } @$ifaces;
	$iface || &usage("No interface with address $address found");
	}
else {
	($iface) = grep { $_->{'fullname'} eq $name } @$ifaces;
	$iface || &usage("No interface named $name found");
	}
$iface->{'noedit'} && &usage("This interface cannot be edited");

# Check if we can manage IPv6
if (@add6 || @del6) {
	$iface->{'unknown'} &&
		&usage("Network interface addresses cannot be changed on ".
		       "this system");
	$iface->{'virtual'} eq '' ||
		&usage("IPv6 addresses can only be added to or remove from ".
		       "real interfaces");
	$cfunc = "type_".$server->{'manager'}."_can_ipv6";
	defined(&$cfunc) && &$cfunc($server) ||
		&usage("IPv6 interfaces cannot be managed on this system");
	&can_action($server, "ips") ||
		&usage("You are not allowed to add or remove IPv6 addresses");
	}

# Check for clashes
%used = &used_ip_addresses();
if ($newaddress) {
	$iface->{'unknown'} &&
		&usage("Network interface addresses cannot be changed on ".
		       "this system");
	$u = $used{$newaddress};
	if ($u && $u->{'id'} eq $server->{'id'}) {
		foreach $ii (@$ifaces) {
			if ($ii->{'address'} eq $newaddress &&
			    $ii ne $iface) {
				&usage("The IP address $newaddress is already ".
				       "in use by $u->{'host'}");
				}
			}
		}
	elsif ($u) {
		&usage("The IP address $newaddress is already in use ".
		       "by $u->{'host'}");
		}
	&ping_server_host($newaddress) &&
		&usage("The IP address $newaddress is being used by another ".
		       "system on your network");
	}
foreach $ip (@add6) {
	$u = $used{$ip};
	$u && &usage("The IPv6 address $ip is already in use by $u->{'host'}");
	&ping_server_host($ip) &&
		&usage("The IPv6 address $ip is being used by another ".
		       "system on your network");
	}

# Update the object
$oldiface = &clone_interface($iface);
if ($newaddress) {
	$iface->{'address'} = $newaddress;
	}
if ($newnetmask) {
	$iface->{'netmask'} = $newnetmask;
	}
if ($newether) {
	$iface->{'ether'} = $newether;
	}
elsif ($noether) {
	$iface->{'ether'} = '';
	}
if ($newmodel) {
	$iface->{'model'} = $newmodel;
	}
elsif ($nomodel) {
	$iface->{'model'} = '';
	}
if ($newbridge) {
	$iface->{'bridge'} = $newbridge;
	}
elsif ($nobridge) {
	$iface->{'bridge'} = '';
	}

# Add and remove IPv6 addresses
foreach my $a (@add6) {
	my ($ip, $nm) = split(/\//, $a);
	$nm ||= 64;
	push(@{$iface->{'address6'}}, $ip);
	push(@{$iface->{'netmask6'}}, $nm);
	}
foreach my $a (@del6) {
	my ($ip, $nm) = split(/\//, $a);
	my $idx = &indexof($ip, @{$iface->{'address6'}});
	if ($idx >= 0) {
		splice(@{$iface->{'address6'}}, $idx, 1);
		splice(@{$iface->{'netmask6'}}, $idx, 1);
		}
	}

# Call the modify function
$mfunc = "type_".$server->{'manager'}."_modify_interface";
$err = &$mfunc($server, $iface, $oldiface);
if ($err) {
	&usage("Interface modification failed : $err");
	}

# Update DHCPd config, if enabled
if (&supports_dhcpd(1) && $iface->{'virtual'} eq '') {
	if ($iface->{'ether'}) {
		&save_iface_dhcpd($server, $iface, $oldiface);
		}
	elsif ($oldiface->{'ether'}) {
		&delete_iface_dhcpd($server, $oldiface);
		}
	}

# Check for change in main IP, which effects DNS
if (!$iface->{'unknown'} &&
    $iface->{'address'} ne $oldiface->{'address'} &&
    $oldiface->{'address'} eq $oldip) {
	&remote_finished();
	$server->{'ip'} = $iface->{'address'};
	&delete_ip_address($server, $oldiface->{'address'});
	&add_ip_address($server, $iface->{'address'});
	&modify_primary_ip_address($server, $oldiface->{'address'},
					    $iface->{'address'});
	}
else {
	&compute_ip_addresses($server);
	}

&save_managed_server($server);
&release_lock_server($server);
print "Modified interface $iface->{'fullname'}\n";
&cloudmin_api_log(\@OLDARGV);

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Changes the IP or MAC address of an interface on some system.\n";
print "\n";
print "cloudmin modify-interface --host hostname\n";
print "                          --address ip.address | --name ethN\n";
print "                         [--new-address ip.address]\n";
print "                         [--new-netmask mask]\n";
print "                         [--new-ether mac-address | --no-ether]\n";
print "                         [--new-model type | --no-model]\n";
print "                         [--new-bridge interface]\n";
print "                         [--add-address6 ipv6-address]*\n";
print "                         [--remove-address6 ipv6-address]*\n";
exit(1);
}

