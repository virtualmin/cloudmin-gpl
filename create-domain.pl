#!/usr/local/bin/perl
# Creates a new virtualmin domain on one system

package server_manager;
$main::no_acl_check++;
$ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
$ENV{'WEBMIN_VAR'} ||= "/var/webmin";
if ($0 =~ /^(.*\/)[^\/]+$/) {
	chdir($1);
	}
chop($pwd = `pwd`);
$0 = "$pwd/create-domain.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";

# Build a list of all known feature names
@vservers = grep { $_->{'status'} eq 'virt' } &list_managed_servers();
@allfeatures = ( );
foreach $s (@vservers) {
	$info = &get_server_collected($s);
	push(@allfeatures, map { $_->{'feature'} }
		($info->{'features'} ? @{$info->{'features'}}
				     : @standard_virtualmin_features));
	}
@allfeatures = &unique(@allfeatures);

# Parse command line
while(@ARGV > 0) {
	local $a = shift(@ARGV);
	if ($a eq "--domain") {
		$domain = shift(@ARGV);
		}
	elsif ($a eq "--host") {
		$host = shift(@ARGV);
		}
	elsif ($a eq "--desc") {
		$desc = shift(@ARGV);
		}
	elsif ($a eq "--pass") {
		$pass = shift(@ARGV);
		}
	elsif ($a eq "--default-features") {
		$dfeatures = 1;
		}
	elsif ($a eq "--feature") {
		push(@features, shift(@ARGV));
		}
	elsif ($a eq "--allocate-ip") {
		$allocate = 1;
		}
	elsif ($a eq "--ip") {
		$ip = shift(@ARGV);
		}
	elsif ($a =~ /^\-\-(\S+)$/ && &indexof($1, @allfeatures) >= 0) {
		push(@features, $1);
		}
	else {
		&usage();
		}
	}

# Check for citical parameters
$host || &usage("Missing --host parameter");
$domain || &usage("Missing --domain parameter");
$pass || &usage("Missing --pass parameter");
$dfeatures || @features || &usage("Either the --default-features or several --feature parameters must be given");

# Get destinaton system
$server = &get_managed_server_by("host", $host);
$server || &usage("No system with hostname $host was found");
$server->{'status'} eq 'virt' || &usage("System $host is not running Virtualmin");

# Work out features
$info = &get_server_collected($server);
@sfeatures = $info->{'features'} ? @{$info->{'features'}}
				 : @standard_virtualmin_features;
if ($dfeatures) {
	# Use default features for server
	@features = map { $_->{'feature'} }
			grep { $_->{'enabled'} && $_->{'default'} }
			 @sfeatures;
	}
else {
	# Make sure all given features are available
	foreach $f (@features) {
		($sf) = grep { $_->{'feature'} eq $f } @sfeatures;
		$sf && $sf->{'enabled'} ||
			&usage("Feature $f is not available on $host");
		}
	}

# Validate IP address
if ($ip) {
	&check_ipaddress($ip) || &usage("Invalid IP address parameter to --ip");
	}

# Build command-line args
@args = ( );
push(@args, [ "domain", $domain ]);
push(@args, [ "desc", $desc ]) if ($desc);
push(@args, [ "pass", $pass ]);
push(@args, [ "limits-from-template" ]);
if ($allocate) {
	push(@args, [ "allocate-ip" ]);
	}
elsif ($ip) {
	push(@args, [ "ip", $ip ]);
	}
foreach $f (@features) {
	push(@args, [ $f ]);
	}

# If the target server type doesn't allow IPs to be brought up within itself,
# (ie. VServers or Zones) do the allocation here or check if the requested IP
# is ative.
$ifunc = "type_".$server->{'manager'}."_list_interfaces";
if ($allocate && defined(&$ifunc)) {
	# Allocate a new IP on the virtual system
	print "Creating network interface ..\n";
	$iface = &create_allocate_ip($server);
	ref($iface) || &usage("Failed to allocate IP : $iface");
	@args = grep { $_->[0] ne "allocate-ip" } @args;
	push(@args, [ "ip", $iface->{'address'} ]);
	push(@args, [ "ip-already" ]);
	print ".. created with address $iface->{'address'}\n\n";
	}
elsif ($ip && defined(&$ifunc)) {
	# Need to use an existing IP .. make sure it exists
	$ifaces = &$ifunc($server);
	ref($ifaces) || &usage($ifaces);
	($got) = grep { $_->{'address'} eq $ip } @$ifaces;
	$got || &usage("IP address $ip is not active on $server->{'host'}");
	push(@args, [ "ip-already" ]);
	}

# Call create-domain.pl
print "Creating Virtualmin domain $domain on $server->{'host'} ..\n";
($err, $out) = &call_virtualmin_api($server, "create-domain", \@args);
print $out;
if ($err) {
	print ".. failed : $err\n";
	}
else {
	&check_server_status($server);
	&save_managed_server($server);
	print ".. creation complete!\n";
	}

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Creates a new top-level Virtualmin domain on a managed system.\n";
print "\n";
print "usage: create-domain.pl --host hostname\n";
print "                        --domain name\n";
print "                        [--desc \"domain description\"]\n";
print "                        --pass password\n";
print "                        --default-features | [--feature name]*\n";
print "                        [--ip address | --allocate-ip]\n";
exit(1);
}

