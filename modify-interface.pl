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
		&check_ipnetmask($newnetmask) ||
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
	else {
		&usage();
		}
	}
$address || $name || &usage("Missing --address or --name parameter");
$newaddress || $newnetmask || $newether || $noether || &usage("Nothing to do");

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

# Update the object
$oldiface = { %$iface };
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

# Call the modify function
$mfunc = "type_".$server->{'manager'}."_modify_interface";
$err = &$mfunc($server, $iface, $oldiface);
if ($err) {
	&usage("Interface modification failed : $err");
	}

# Update DHCPd config, if enabled
if (&supports_dhcpd(1) && $iface->{'virtual'} ne '') {
	if ($iface->{'ether'}) {
		&save_iface_dhcpd($server, $iface, $oldiface);
		}
	else {
		&delete_iface_dhcpd($server, $oldiface);
		}
	}

# Check for change in main IP, which effects DNS
if ($iface->{'address'} ne $oldiface->{'address'} &&
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
exit(1);
}

