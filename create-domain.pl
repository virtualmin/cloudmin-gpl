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
$0 = "$pwd/create-system.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";

# Parse command line
while(@ARGV > 0) {
	local $a = shift(@ARGV);
	if ($a eq "--domain") {
		$type = shift(@ARGV);
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
	elsif ($a eq "--allocate-ip") {
		$allocate = 1;
		}
	elsif ($a eq "--ip") {
		$ip = shift(@ARGV);
		}
	else {
		&usage();
		}
	}

# Check for citical parameters
# XXX

