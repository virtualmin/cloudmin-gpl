#!/usr/local/bin/perl

=head1 create-interface.pl

Adds a new network interface to some system

This program adds a virtual interface to some Cloudmin-managed system. You must
specify the system with the C<--host> parameter, and the base interface with
C<--name>. The IP address can be either explitly set with C<--address>, or Cloudmin
can allocate a free IP from the range defined for the host system with
C<--allocate>.

Either way, the full inteface name and IP address will be displayed if the
command completes successfully.

=head1 Example usage

  cloudmin create-interface --host vvirtualmin.home --name eth0 --address 193.9.101.250
  Created interface eth0:3 with address 193.9.101.250

=cut

package server_manager;
$main::no_acl_check++;
$ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
$ENV{'WEBMIN_VAR'} ||= "/var/webmin";
if ($0 =~ /^(.*\/)[^\/]+$/) {
	chdir($1);
	}
chop($pwd = `pwd`);
$0 = "$pwd/create-interface.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";

# Parse command line
while(@ARGV > 0) {
	local $a = shift(@ARGV);
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
	else {
		&usage();
		}
	}
$name || &usage("Missing --name parameter");
$address || $allocate || &usage("One of --address or --allocate must be given");
!$address || &check_ipaddress($address) || &usage("Invalid IP address");
!$netmask || &check_ipaddress($netmask) || &usage("Invalid netmask");

# Get the server
$host || &usage("Missing --host parameter");
$server = &get_managed_server_by("host", $host);
$server || &usage("System with hostname $host does not exist");

# Check the function and status
$ifunc = "type_".$server->{'manager'}."_create_interface";
defined(&$ifunc) || &usage("System type $server->{'manager'} does not support ".
			   "network interface management");
$cfunc = "type_".$server->{'manager'}."_can_interfaces";
defined(&$cfunc) && &$cfunc($server) ||
	&usage("Interfaces cannot be managed on this system");
$server->{'status'} eq 'nohost' && &usage("Host for system is down");

# Get the parent network interfaces
$pfunc = "type_".$server->{'manager'}."_list_parent_interfaces";
$parents = &$pfunc($server);
ref($parents) || &usage("Failed to get parent network interfaces : $parents");
($piface) = grep { $_->{'fullname'} eq $name &&
		   $_->{'virtual'} eq '' } @$parents;
$piface || &usage("No real interface named $name found on parent system. ".
		  "Existing interfaces are : ".
		  join(" ", map { $_->{'fullname'} }
				grep { $_->{'virtual'} eq '' } @$parents));

# Create the interface object
$iface = { 'name' => $name };
if (!$allocate) {
	$iface->{'address'} = $address;
	}
if ($netmask) {
	$iface->{'netmask'} = $netmask;
	}
else {
	$iface->{'netmask'} = $piface->{'netmask'};
	}

# Call the create function
$err = &$ifunc($server, $iface);
if ($err) {
	&usage("Interface creation failed : $err");
	}
else {
	print "Created interface $iface->{'fullname'} with address $iface->{'address'}\n";
	}

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Adds a network interface to some virtual system.\n";
print "\n";
print "cloidmin create-interfaces --host hostname\n";
print "                           --name interface\n";
print "                           --address ip.address | --allocate\n";
print "                          [--netmask ip.netmask]\n";
exit(1);
}

