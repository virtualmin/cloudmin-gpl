#!/usr/local/bin/perl
# Removes Virtualmin domains from managed systems

package server_manager;
$main::no_acl_check++;
$ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
$ENV{'WEBMIN_VAR'} ||= "/var/webmin";
if ($0 =~ /^(.*\/)[^\/]+$/) {
	chdir($1);
	}
chop($pwd = `pwd`);
$0 = "$pwd/delete-domain.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";

# Parse command line
while(@ARGV > 0) {
	local $a = shift(@ARGV);
	if ($a eq "--domain") {
		push(@dnames, shift(@ARGV));
		}
	elsif ($a eq "--host") {
		$host = shift(@ARGV);
		}
	else {
		&usage();
		}
	}

# Check for citical parameters
@dnames || &usage("No domains to delete specified");

# Get the domains
if ($host) {
	$server = &get_managed_server_by("host", $host);
	$server || &usage("System $host does not exist");
	@sources = ( $server );
	}
else {
	@sources = &list_managed_servers();
	}
@serverdoms = ( );
foreach $s (@sources) {
	if ($s->{'status'} eq 'virt') {
		@doms = &get_server_domains($s);
		foreach $dn (@dnames) {
			($d) = grep { $_->{'dom'} eq $dn } @doms;
			if ($d) {
				if ($found{$d->{'dom'}}++) {
					&usage("Domain $dn was found on more than one system. Use --host to specify the source you want");
					}
				push(@serverdoms, [ $s, $d ]);
				}
			}
		}
	}
foreach $dn (@dnames) {
	$found{$dn} || &usage("Domain $dn was not found on any system running Virtualmin");
	}

# Delete each one
foreach $sd (@serverdoms) {
	($server, $d) = @$sd;

	# Remove the domain
	print "Deleting Virtualmin domain $d->{'dom'} from ",
	      "$server->{'host'} ..\n";
	@args = ( [ "domain", $d->{'dom'} ] );
	($err, $out) = &call_virtualmin_api($server, "delete-domain", \@args);
	print $out;
	if ($err) {
		print ".. failed : $err\n\n";
		}
	else {
		print ".. deleted successfully\n\n";
		}

	# Remove the virtual IP
	$iface = &get_domain_interface($server, $d);
	if ($iface && !$err) {
		print "Removing network interface $iface->{'address'} ",
		      "from $server->{'host'} ..\n";
		$dfunc = "type_".$server->{'manager'}."_delete_interface";
		$err = &$dfunc($server, $iface);
		if ($err) {
			print ".. failed : $err\n\n";
			}
		else {
			print ".. deleted successfully\n\n";
			}
		}
	}

# Recheck server statuses
print "Refreshing status of changed systems ..\n";
foreach my $sd (@serverdoms) {
	$server = $sd->[0];
	if (!$donerecheck{$server->{'host'}}++) {
		&check_server_status($server);
		&save_managed_server($server);
		}
	}
print ".. done\n\n";

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Deletes one or more Virtualmin domains from managed systems.\n";
print "\n";
print "usage: delete-domains.pl --domain name [--domain name]*\n";
print "                         [--host source.hostname]\n";
exit(1);
}

