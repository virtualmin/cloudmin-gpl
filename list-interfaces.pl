#!/usr/local/bin/perl

=head1 list-interfaces.pl

Lists network interfaces on some system

This command outputs a list of virtual interfaces on some managed system,
selected using the C<--host> command-line parameter. By default they are shown
in a table, but you can select a more machine-readable format with the
optional C<--multiline> parameter, or get a list of just IP addresses with
C<--name-only>.

=head1 Example usage

  cloudmin list-interfaces --host vvirtualmin.home
  Interface  Address         Netmask         Use
  ---------- --------------- --------------- -----------------------------------
  eth0:0     193.9.101.224   255.255.255.0   Virtualmin shared address default
  eth0:1     193.9.101.225   255.255.255.0   Virtualmin domain vservervirt.com
  eth0:2     193.9.101.227   255.255.255.0   Virtualmin domain autoip.com

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
$0 = "$pwd/list-interfaces.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";

# Parse command line
while(@ARGV > 0) {
	my $a = shift(@ARGV);
	if ($a eq "--host") {
		$host = shift(@ARGV);
		}
	elsif ($a eq "--multiline") {
		$multi = 1;
		}
	elsif ($a eq "--name-only") {
		$nameonly = 1;
		}
	else {
		&usage();
		}
	}

# Get the server
$host || &usage("Missing --host parameter");
$server = &get_managed_server_by("host", $host);
$server || &usage("System with hostname $host does not exist");
&can_action_usage($server, "ifaces");

# Get the interfaces
$ifunc = "type_".$server->{'manager'}."_list_interfaces";
defined(&$ifunc) || &usage("System type $server->{'manager'} does not support ".
			   "network interface management");
$cfunc = "type_".$server->{'manager'}."_can_interfaces";
defined(&$cfunc) && &$cfunc($server) ||
	&usage("Interfaces cannot be managed on this system");
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
		if ($i->{'ether'}) {
			print "    Ethernet address: $i->{'ether'}\n";
			if (&supports_dhcpd(1)) {
				$d = &get_iface_dhcpd($server, $i);
				print "    DHCP entry: ",
				      ($d ? "Yes" : "No"),"\n";
				}
			}
		if ($i->{'gateway'}) {
			print "    Gateway: $i->{'gateway'}\n";
			}
		if ($use) {
			print "    Use: ",&strip_html_tags($use),"\n";
			print "    Use type: ",
			      ($ucode == 0 ? "none" :
			       $ucode == 1 ? "default" : "virt"),"\n";
			}
		}
	}
elsif ($nameonly) {
	# Show IPs only
	foreach $i (@$ifaces) {
		print $i->{'address'},"\n";
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
			     &strip_html_tags($use);
		}
	}

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Lists all network interfaces on some virtual system.\n";
print "\n";
print "cloudmin list-interfaces --host hostname\n";
print "                        [--multiline | --name-only]\n";
exit(1);
}

