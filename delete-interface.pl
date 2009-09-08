#!/usr/local/bin/perl

=head1 delete-interface.pl

Removes a network interface from some system

This removes a virtual interface from some system. It takes two parameters :
C<--host> followed by the name of the system, and C<--address> followed by
the IP of the interface to remove. Be careful doing this though, as it may cut
off access to a Virtualmin domain, or prevent SSH logins to the system
altogether.

=head1 Example usage

  cloudmin delete-interface --host vvirtualmin.home --address 193.9.101.250
  Deleted interface eth0:3

=cut 

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
@OLDARGV = @ARGV;

# Parse command line
while(@ARGV > 0) {
	my $a = shift(@ARGV);
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
&obtain_lock_server($server);

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
&compute_ip_addresses($server);
&save_managed_server($server);
&release_lock_server($server);
&cloudmin_api_log(\@OLDARGV);

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Deletes a network interface from some virtual system.\n";
print "\n";
print "cloudmin delete-interface --host hostname\n";
print "                          --address ip.address\n";
exit(1);
}

