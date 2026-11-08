#!/usr/bin/perl
# networkd-dhcp-settings.pl module interface mac [restore-address] [operation]
# Reads production DHCP settings or exercises recovery in the isolated fixture.
# Without restore-address, prints settings for interface using mac. Otherwise,
# requests that address; operation defaults to creation recovery, or is remove.
use strict;
use warnings;

BEGIN
{
# The caller supplies private namespaces; this helper requires Linux root.
die "Linux test guest as root only\n" unless $^O eq 'linux' && $< == 0;
$ENV{'WEBMIN_CONFIG'} = '/etc/webmin';
$ENV{'WEBMIN_VAR'} = '/var/webmin';
$ENV{'REMOTE_USER'} = 'root';
chdir($ARGV[0]) || die $!;
$0 = "$ARGV[0]/network-worker.pl";
}
require './server-manager-lib.pl';
require './cloudmin-network-lib.pl';
my $host = get_host_network();
if ($ARGV[3]) {
	# This plan names only the fixture link inside its
	# private network namespace.
	my $remove = ($ARGV[4] || '') eq 'remove';
	$host->restore_netplan_dhcp4({ id => 'fixture',
				       source => $remove ? 'cmport' : $ARGV[1],
				       name => $ARGV[1],
				       operation => $remove
					       ? 'remove'
					       : 'create',
				       mode => 'netplan',
				       saved => { dhcp => 1 },
				       addresses =>
					       [ "$ARGV[3]/24" ] });
	}
else {
	# Return production settings for the fixture's
	# currently leased interface.
	print $host->netplan_dhcp4_identity(@ARGV[1, 2]);
	}
