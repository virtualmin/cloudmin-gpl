#!/usr/local/bin/perl

=head1 set-default-gateway.pl

Changes the default network gateway on some system.

This command changes the default routing gateway IP address and device on
some Cloudmin-managed system. You must specify the system with the C<--host>
parameter, and the new gateway IP with the C<--gateway> flag. If changing
the gateway interface, the C<--gateway-interface> parameter can be given
as well. To remove the default gateway from a system altogether, use the
C<--no-gateway> flag instead.

This function is only available on Xen and KVM systems. OpenVZ and Vservers
virtualization does not allow virtual systems to have a different default
gateway from the host system.

=head1 Example usage

  cloudmin set-default-gateway --host xensomething.home --gateway 193.9.101.1
  Set default gateway to 193.9.101.1.

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
	elsif ($a eq "--gateway") {
		$gw = shift(@ARGV);
		}
	elsif ($a eq "--no-gateway") {
		$nogw = 1;
		}
	elsif ($a eq "--gateway-interface") {
		$gwdev = shift(@ARGV);
		}
	elsif ($a eq "--multiline") {
		$multiline = 1;
		}
	else {
		&usage("Unknown parameter $a");
		}
	}
$host || &usage("Missing --host parameter");
$nogw || $gw && &check_ipaddress($gw) ||
	&usage("Missing or invalid --gateway parameter");

# Get the server
$server = &get_managed_server_by("host", $host);
$server || &usage("System with hostname $host does not exist");
&can_action_usage($server, "ifaces");
&obtain_lock_server($server);

# Check if gateway can be set
$cgfunc = "type_".$server->{'manager'}."_can_gateway";
defined(&$cgfunc) && &$cgfunc($server) ||
	&usage("The default gateway cannot be set on this system");

# Validate gateway device if given
if ($gwdev) {
	$ifunc = "type_".$server->{'manager'}."_list_interfaces";
	$ifaces = &$ifunc($server);
	ref($ifaces) || &usage("Failed to list network interfaces : $ifaces");
	($iface) = grep { $_->{'fullname'} eq $gwdev } @$ifaces;
	$iface || &usage("No interface named $gwdev was found");
	}

# Set the gateway
if ($nogw) {
	$err = &modify_default_gateway($server, undef, undef);
	}
else {
	$err = &modify_default_gateway($server, $gw, $gwdev);
	}
if ($err) {
	&usage("Gateway change failed : $err");
	}
elsif ($nogw) {
	print "Cleared default gateway.\n";
	}
else {
	print "Set default gateway to $gw".
	      ($gwdev ? " on interface $gwdev" : "").".\n";
	}

&save_managed_server($server);
&release_lock_server($server);
&cloudmin_api_log(\@OLDARGV);

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Changes the default network gateway on some system.\n";
print "\n";
print "cloudmin set-default-gateway --host hostname\n";
print "                            [--gateway address | --no-gateway]\n";
print "                            [--gateway-interface name]\n";
exit(1);
}

