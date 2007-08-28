#!/usr/local/bin/perl
# Downloads a file from a single system

package server_manager;
$main::no_acl_check++;
$ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
$ENV{'WEBMIN_VAR'} ||= "/var/webmin";
if ($0 =~ /^(.*\/)[^\/]+$/) {
	chdir($1);
	}
chop($pwd = `pwd`);
$0 = "$pwd/install-webmin.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";

# Parse command line
while(@ARGV > 0) {
	local $a = shift(@ARGV);
	if ($a eq "--host") {
		$host = shift(@ARGV);
		}
	elsif ($a eq "--source") {
		$source = shift(@ARGV);
		}
	elsif ($a eq "--stdout") {
		$stdout = 1;
		}
	elsif ($a eq "--dest") {
		$dest = shift(@ARGV);
		}
	else {
		&usage();
		}
	}

# Get the server and check parameters
$host || &usage("Missing --host parameter");
$server = &get_managed_server_by("host", $host);
$server || &usage("No system with hostname $host exists");
$source || &usage("Missing --source parameter");
$dest || $stdout || &usage("Missing --dest or --stdout parameter");

# Get the file
if ($stdout) {
	$dest = &transname();
	}
$err = &get_file_from_server($server, $source, $dest);
if ($err) {
	print "ERROR: $err\n";
	exit(1);
	}
elsif ($stdout) {
	# Write to stdout
	open(FILE, $dest);
	while(read(FILE, $buf, 1024) > 0) {
		print $buf;
		}
	close(FILE);
	unlink($dest);
	}
else {
	# Saved OK
	print "Saved $source as $dest\n";
	}

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Downloads a file from a managed system.\n";
print "\n";
print "usage: download-file.pl --host name\n";
print "                        --source sourcepath\n";
print "                        [--dest destpath] | [--stdout]\n";
exit(1);
}

