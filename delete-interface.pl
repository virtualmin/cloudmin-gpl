#!/usr/local/bin/perl
# Removes a network interface from some system

package server_manager;
$main::no_acl_check++;
$ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
$ENV{'WEBMIN_VAR'} ||= "/var/webmin";
if ($0 =~ /^(.*\/)[^\/]+$/) {
	chdir($1);
	}
chop($pwd = `pwd`);
$0 = "$pwd/delete-interface.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";

# Parse command line
while(@ARGV > 0) {
	local $a = shift(@ARGV);
	if ($a eq "--host") {
		$host = shift(@ARGV);
		}
	elsif ($a eq "--address") {
		$address = shift(@ARGV);
		}
	else {
		&usage();
		}
	}
$address || &usage("Missing --address parameter");

# Get the server
$host || &usage("Missing --host parameter");
$server = &get_managed_server_by("host", $host);
$server || &usage("System with hostname $host does not exist");

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
($iface) = grep { $_->{'address'} eq $address } @$ifaces;
$iface || &usage("No interface with address $address found");

# Call the deletion function
$dfunc = "type_".$server->{'manager'}."_delete_interface";
$err = &$dfunc($server, $iface);
if ($err) {
	&usage("Interface deletion failed : $err");
	}
else {
	print "Deleted interface $iface->{'fullname'}\n";
	}

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Deletes a network interface from some virtual system.\n";
print "\n";
print "usage: delete-interfaces.pl --host hostname\n";
print "                            --address ip.address\n";
exit(1);
}

