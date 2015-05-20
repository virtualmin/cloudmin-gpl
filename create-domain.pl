#!/usr/local/bin/perl

=head1 create-domain.pl

Creates a new virtualmin domain on one system

This command creates a Virtualmin top-level domain on a specified managed
system. You must specify the C<--host> parameter, followed by the name of a
host to create on (which of course must have Virtualmin installed). Alternately,
you can use the C<--host-selector> flag followed by either C<mem>, C<cpu>,
C<space> or C<domains> to have Cloudmin selector a host based on free
resources.

Other required parameters are C<--domain> and C<--pass>, followed by the domain
name and password respectively. You also need to choose features, either with
the C<--default-features> option, or multiple uses of C<--feature> followed by
a feature code like C<web> or C<dir>.

The command may take a few seconds to run, and will output the messages from
the Virtualmin create-domain.pl command run on the remote system. Even though
it is effectively invoked remotely, you cannot use all of the same command-line
flags that it supports. 

=head1 Example usage

  cloudmin create-domain --host xencentos.home --domain wibble.com --desc "Example domain" --pass foo --feature dir --feature unix --feature web --feature webmin
  Creating Virtualmin domain wibble.com on xencentos.home ..
  Beginning server creation ..
  Creating home directory ..
  .. done
  Creating administration group wibble ..
  .. done
  Creating administration user wibble ..
  .. done
  Adding new virtual website ..
  .. done
  Adding Apache user apache to server's group ..
  .. done
  Creating Webmin user ..
  .. done
  Applying web server configuration ..
  .. done
  Re-loading Webmin ..
  .. done
  Saving server details ..
  .. done
  All done!
  .. creation complete!

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
$0 = "$pwd/create-domain.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";
@OLDARGV = @ARGV;
&usage_if_cloudmin_replica();

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
	my $a = shift(@ARGV);
	if ($a eq "--domain") {
		$domain = shift(@ARGV);
		}
	elsif ($a eq "--host") {
		$host = shift(@ARGV);
		}
	elsif ($a eq "--host-selector") {
		$hostmode = shift(@ARGV);
		@valid_hostmodes = ( "doms", "space", "cpu", "mem" );
		&indexof($hostmode, @valid_hostmodes) >= 0 ||
			&usage("--host-selector must be followed by one of : ".
			       join(" ", @valid_hostmodes));
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
	elsif ($a eq "--vsync") {
		$vsyncnow = 1;
		}
	elsif ($a eq "--multiline") {
		$multiline = 1;
		}
	elsif ($a =~ /^\-\-(\S+)$/ && &indexof($1, @allfeatures) >= 0) {
		push(@features, $1);
		}
	else {
		&usage("Unknown parameter $a");
		}
	}

# Check for citical parameters
$host || $hostmode || &usage("Missing --host or --host-selector parameter");
$domain || &usage("Missing --domain parameter");
$pass || &usage("Missing --pass parameter");
$dfeatures || @features || &usage("Either the --default-features or several --feature parameters must be given");

# Get destinaton system
if ($host) {
	# Explicitly given
	$server = &find_one_managed_server($host);
	$server || &usage("No system with hostname $host was found");
	}
else {
	# Find candidate system
	@vservers = grep { $_->{'status'} eq 'virt' &&
			   !$_->{'novirt'} &&
			   $_->{'virtualmin_checked'} }
			 &list_available_managed_servers();
	$server = &find_suitable_server(\@vservers, $hostmode);
	$server || &usage("No system found for host selection mode $hostmode");
	}
$server->{'status'} eq 'virt' ||
	&usage("System $server->{'host'} is not running Virtualmin");
&can_action_usage($server, "domains");
&obtain_lock_server($server);

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
			&usage("Feature $f is not available on ".
			       $server->{'host'});
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
	print ".. failed : $err\n\n";
	exit(1);
	}
else {
	&check_server_status($server);
	&save_managed_server($server);
	print ".. creation complete!\n\n";
	}
&release_lock_server($server);

# If sync was requested, run any vsync profiles that match the source system
if ($vsyncnow) {
	&set_all_text_print();
	&run_all_vsyncs_for_server($server, $domain);
	}

&cloudmin_api_log(\@OLDARGV);

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Creates a new top-level Virtualmin domain on a managed system.\n";
print "\n";
print "cloudmin create-domain --host hostname | --host-selector mode\n";
print "                       --domain name\n";
print "                      [--desc \"domain description\"]\n";
print "                       --pass password\n";
print "                       --default-features | [--feature name]*\n";
print "                      [--ip address | --allocate-ip]\n";
print "                      [--vsync]\n";
exit(1);
}

