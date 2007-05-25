#!/usr/local/bin/perl
# Lists network interfaces on some system

package server_manager;
$main::no_acl_check++;
$ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
$ENV{'WEBMIN_VAR'} ||= "/var/webmin";
if ($0 =~ /^(.*\/)[^\/]+$/) {
	chdir($1);
	}
chop($pwd = `pwd`);
$0 = "$pwd/list-interfaces.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";

# Parse command line
while(@ARGV > 0) {
	local $a = shift(@ARGV);
	if ($a eq "--host") {
		$host = shift(@ARGV);
		}
	elsif ($a eq "--multiline") {
		$multi = 1;
		}
	else {
		&usage();
		}
	}

# Get the server
$host || &usage("Missing --host parameter");
$server = &get_managed_server_by("host", $host);
$server || &usage("System with hostname $host does not exist");

# Get the interfaces
$ifunc = "type_".$server->{'manager'}."_list_interfaces";
defined(&$ifunc) || &usage("System type $server->{'manager'} does not support ".
			   "network interface management");
$server->{'status'} eq 'nohost' && &usage("Host for system is down");
$ifaces = &$ifunc($server);
ref($ifaces) || &usage("Failed to list interfaces : $ifaces");

$info = &get_server_collected($server);
@doms = &get_server_domains($server);

if ($multi) {
	# Show one per block
	foreach $i (@$ifaces) {
		if ($info) {
			($ucode, $use) = &get_interface_use($server, $info,
							    \@doms, $i);
			}
		print "$i->{'fullname'}\n";
		print "    Physical interface: $i->{'name'}\n";
		print "    Interface number: $i->{'virtual'}\n";
		print "    IP address: $i->{'address'}\n";
		print "    Netmask: $i->{'netmask'}\n";
		if ($use) {
			print "    Use: $use\n";
			print "    Use type: ",
			      ($ucode == 0 ? "none" :
			       $ucode == 1 ? "default" : "virt"),"\n";
			}
		}
	}
else {
	# Show one per line
	$fmt = "%-10.10s %-15.15s %-15.15s %-35.35s\n";
	printf $fmt, "Interface", "Address", "Netmask", "Use";
	printf $fmt, ("-" x 10), ("-" x 15), ("-" x 15), ("-" x 35);
	foreach $i (@$ifaces) {
		if ($info) {
			($ucode, $use) = &get_interface_use($server, $info,
							    \@doms, $i);
			}
		printf $fmt, $i->{'fullname'}, $i->{'address'}, $i->{'netmask'},
			     $use;
		}
	}

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Lists all network interfaces on some virtual system.\n";
print "\n";
print "usage: list-interfaces.pl --host hostname\n";
print "                          [--multiline]\n";
exit(1);
}

