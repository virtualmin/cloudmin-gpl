#!/usr/local/bin/perl
# Moves a domain from one system to another

package server_manager;
$main::no_acl_check++;
$ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
$ENV{'WEBMIN_VAR'} ||= "/var/webmin";
if ($0 =~ /^(.*\/)[^\/]+$/) {
	chdir($1);
	}
chop($pwd = `pwd`);
$0 = "$pwd/move-domain.pl";
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
	elsif ($a eq "--dest") {
		$desthost = shift(@ARGV);
		}
	elsif ($a eq "--delete") {
		$deletesource = 1;
		}
	elsif ($a eq "--disable") {
		$deletesource = 2;
		}
	elsif ($a eq "--force") {
		$force = 1;
		}
	elsif ($a eq "--direct") {
		$direct = 1;
		}
	elsif ($a eq "--include-sub-servers") {
		$incsubs = 1;
		}
	else {
		&usage();
		}
	}
@dnames || &usage("No domains to move specified");
$desthost || &usage("Missing --dest parameter");
$dest = &get_managed_server_by("host", $desthost);
$dest || &usage("System $desthost does not exist");
$dest->{'status'} eq 'virt' || &usage("System $desthost is not running Virtualmin");

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

if ($incsubs) {
	# Automatically add sub-servers
	@serverdoms = &unique_serverdoms([ @serverdoms,
					   &find_sub_servers(\@serverdoms) ]);
	}

# Validate move
$err = &check_domain_move(\@serverdoms, $dest, $deletesource, $direct);
&usage("Selected domains cannot be moved : $err") if ($err);

# Check for missing features
if (!$force) {
	@missing = &check_move_features(\@serverdoms, $dest);
	if (@missing) {
		print "The following domains cannot be moved, as they use ".
		      "features not available on\n".
		      "the destination. Use --force to override.\n\n";
		$fmt = "%-40.40s %-35.35s\n";
		printf $fmt, "Domain", "Missing feature";
		printf $fmt, ("-" x 40), ("-" x 35);
		foreach $m (@missing) {
			printf $fmt, $m->[1]->{'dom'}, $m->[2]->{'desc'};
			}
		exit(1);
		}
	}

# Do it!
&set_all_text_print();
&move_domains_to_server(\@serverdoms, $dest, $deletesource, $direct);

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Moves one or more Virtualmin domains to another system.\n";
print "\n";
print "usage: move-domains.pl --domain name [--domain name]*\n";
print "                       --dest hostname\n";
print "                      [--host source.hostname]\n";
print "                      [--disable | --delete]\n";
print "                      [--force]\n";
print "                      [--direct]\n";
print "                      [--include-sub-servers]\n";
exit(1);
}

