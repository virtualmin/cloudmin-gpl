#!/usr/local/bin/perl

=head1 download-file.pl

Downloads a file from a single system

This script can be used to fetch a single file from a Cloudmin managed system and
either save it on the master, or print it to standard output. The system is
selected with the C<--host> parameter, and the source file with C<--source>. To 
have the file saved on the master, add the C<--dest> parameter followed by a
filename. To have its contents output by the script, use the C<--stdout>
parameter instead.

If the source or destination file is block-special device (like an LVM logical
volume), you must add the --device-file flag.

=head1 Example usage

  cloudmin download-file --host xencentos.home --source /etc/hosts --stdout
  127.0.0.1 localhost
  193.9.101.242 xencentos.home xencentos

=cut

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
@OLDARGV = @ARGV;

# Parse command line
while(@ARGV > 0) {
	my $a = shift(@ARGV);
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
	elsif ($a eq "--device-file") {
		$device = 1;
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
$err = &get_file_from_server($server, $source, $dest, $device);
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
&cloudmin_api_log(\@OLDARGV);

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Downloads a file from a managed system.\n";
print "\n";
print "cloudmin download-file --host name\n";
print "                       --source sourcepath\n";
print "                      [--dest destpath] | [--stdout]\n";
print "                      [--device-file]\n";
exit(1);
}

