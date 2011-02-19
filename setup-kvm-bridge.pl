#!/usr/local/bin/perl

=head1 setup-kvm-bridge.pl

Change boot-time network settings to create a bridge interface.

This script is designed to be called from the Cloudmin installer, and will
create a br0 bridge interface with the same IP as eth0, then connect eth0
to br0.

Exist status 0 means the bridge was already setup and active, 1 means
a reboot is needed, 2 means something failed.

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
$0 = "$pwd/setup-kvm-bridge.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";
&set_all_text_print();
&usage_if_cloudmin_replica();
&can_action_usage(undef, "global");

$br_name = "br0";
$eth_name = "eth0";

# Check for supported OS
$gconfig{'os_type'} eq 'redhat-linux' ||
  $gconfig{'os_type'} eq 'debian-linux' ||
     &usage("This script can only be run on Redhat or Debian derived linuxes");
&foreign_check("net") ||
     &usage("The Network Configuration module is not installed");
&foreign_require("net", "net-lib.pl");

# Find relevant interfaces
@boot = &net::boot_interfaces();
($eth0) = grep { $_->{'fullname'} eq $eth_name } @boot;
($br0) = grep { $_->{'fullname'} eq $br_name } @boot;
@active = &net::active_interfaces();
($eth0_active) = grep { $_->{'fullname'} eq $eth_name } @active;
($br0_active) = grep { $_->{'fullname'} eq $br_name } @active;
if ($br0 && $br0_active) {
	# Already active!
	print "Bridge $br_name is already active\n";
	exit(0);
	}
elsif ($br0 && $br0->{'address'}) {
	# Bridge exists, but isn't active yet
	print "Bridge $br_name has been created but is not active yet\n";
	exit(1);
	}
elsif (!$eth0) {
	print "No ethernet interface named $eth_name was found\n";
	exit(2);
	}
elsif (!$eth0->{'address'}) {
	print "Ethernet interface $eth_name does not have a fixed address\n";
	exit(2);
	}

# Create br0 interface, with same settings as eth0
$br0 ||= { 'name' => $br_name,
	   'fullname' => $br_name };
$br0->{'up'} = 1;
$br0->{'dhcp'} = $br0->{'bootp'} = 0;
$br0->{'address'} = $eth0->{'address'};
$br0->{'netmask'} = $eth0->{'netmask'};
$br0->{'network'} = $eth0->{'network'};
$br0->{'gateway'} = $eth0->{'gateway'};
$br0->{'broadcast'} = $eth0->{'broadcast'};
$br0->{'mtu'} = $eth0->{'mtu'};
$br0->{'address6'} = $eth0->{'address6'};
$br0->{'netmask6'} = $eth0->{'netmask6'};
$br0->{'gateway6'} = $eth0->{'gateway6'};
&net::save_interface($br0);

if ($gconfig{'os_type'} eq 'redhat-linux') {
	# Set TYPE field to Bridge manually
	&read_env_file("$net::net_scripts_dir/ifcfg-$br_name", \%brconf);
	$brconf{'TYPE'} = 'Bridge';
	&write_env_file("$net::net_scripts_dir/ifcfg-$br_name", \%brconf);

	# Manually change eth0 to use br0 as a bridge
	&read_env_file("$net::net_scripts_dir/ifcfg-$eth_name", \%ethconf);
	$ethconf{'BRIDGE'} = $br0_name;
	foreach $f ('IPADDR', 'NETMASK', 'NETWORK', 'GATEWAY', 'BROADCAST',
		    'MTU', 'BOOTPROTO', 'IPV6ADDR', 'IPV6ADDR_SECONDARIES',
		    'IPV6INIT', 'IPV6_DEFAULTGW') {
		delete($ethconf{$f});
		}
	&write_env_file("$net::net_scripts_dir/ifcfg-$eth_name", \%ethconf);
	print "Created bridge $br_name connected to $eth_name\n";
	exit(1);
	}
elsif ($gconfig{'os_type'} eq 'debian-linux') {
	# Add pre-up commands to bridge interface
	@defs = &net::get_interface_defs();
	($br0_def) = grep { $_->[0] eq $br0_name &&
			    $_->[1] eq 'inet' } @defs;
	push(@{$br0_def->[3]}},
             [ 'pre-up', 'brctl addbr '.$br_name ],
	     [ 'pre-up', 'brctl addif '.$br_name.' '.$eth_name ]);
	&net::modify_interface_def($br0_def->[0], $br0_def->[1],
				   $br0_def->[2], $br0_def->[3]);

	# Make eth0 manual with no other options
	($eth0_def) = grep { $_->[0] eq $eth0_name &&
			     $_->[1] eq 'inet' } @defs;
	$eth0_def->[2] = 'manual';
	$eth0_def->[3] = [ ];
	&net::modify_interface_def($eth0_def->[0], $eth0_def->[1],
				   $eth0_def->[2], $eth0_def->[3]);
	print "Created bridge $br_name connected to $eth_name\n";
	exit(1);
	}

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Change boot-time network settings to create a bridge interface.\n";
print "\n";
print "cloudmin setup-kvm-bridge\n";
exit(2);
}

