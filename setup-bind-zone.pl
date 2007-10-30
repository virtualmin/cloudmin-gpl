#!/usr/local/bin/perl
# Creates a new BIND zone, and sets up BIND if needed. Designed to be called
# from the VM2 installer

package server_manager;
$main::no_acl_check++;
$ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
$ENV{'WEBMIN_VAR'} ||= "/var/webmin";
if ($0 =~ /^(.*\/)[^\/]+$/) {
	chdir($1);
	}
chop($pwd = `pwd`);
$0 = "$pwd/setup-bind-zone.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";
&foreign_require("bind8", "bind8-lib.pl");

# Parse command line
while(@ARGV > 0) {
	local $a = shift(@ARGV);
	if ($a eq "--zone") {
		$zone = shift(@ARGV);
		}
	elsif ($a eq "--email") {
		$email = shift(@ARGV);
		}
	elsif ($a eq "--master") {
		$master = shift(@ARGV);
		}
	elsif ($a eq "--view") {
		$view = shift(@ARGV);
		}
	elsif ($a eq "--auto-view") {
		$auto_view = 1;
		}
	else {
		&usage();
		}
	}

# Validate inputs
$zone || &usage("Missing --zone parameter");
$email ||= &bind8::config{'tmpl_email'} || "root\@".&get_system_hostname();
$master ||= $bind8::config{'default_prins'} || &get_system_hostname();

# Get the view
$conf = &bind8::get_config();
@views = &find("view", $conf);
if ($view) {
	# Specific named view
	($vinfo) = grep { $_->{'value'} eq $view } @views;
	$vinfo || &usage("No view named $view was found");
	$vconf = $vinfo->{'members'};
	}
elsif ($auto_view) {
	# First view, if any
	if (@views) {
		$vinfo = $views[0];
		$vconf = $vinfo->{'members'};
		}
	else {
		$vconf = $conf;
		}
	}
else {
	# Top level
	$vconf = $conf;
	}

# Check for a clash
foreach $z (&find("zone", $vconf)) {
	$z->{'value'} eq $zone && &usage("A zone named $zone already exists");
	}

# Make sure BIND is setup
# XXX

# Add the zone to named.conf
# XXX

# Create initial records
# XXX

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Creates a new BIND DNS zone.\n";
print "\n";
print "usage: setup-bind-zone.pl --zone domain.name\n";
print "                         [--email address\@host]\n";
print "                         [--master hostname]\n";
print "                         [--view name | --auto-view]\n";
exit(1);
}

