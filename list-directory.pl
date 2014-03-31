#!/usr/local/bin/perl

=head1 list-directory.pl

Lists the contents of a directory on a remote system.

This command simply outputs the names of files in a directory on the remote
system specified with the C<--host> flag. The directory to list is chosen
with the C<--dir> flag.

=head1 Example usage

  cloudmin list-directory --host xencentos.home --dir /etc
  hosts
  passwd
  group

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
$0 = "$pwd/list-directory.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";
@OLDARGV = @ARGV;

# Parse command line
while(@ARGV > 0) {
	my $a = shift(@ARGV);
	if ($a eq "--host") {
		$host = shift(@ARGV);
		}
	elsif ($a eq "--dir") {
		$dir = shift(@ARGV);
		}
	elsif ($a eq "--multiline") {
		$multiline = 1;
		}
	else {
		&usage("Unknown parameter $a");
		}
	}

# Get the server and check parameters
$host || &usage("Missing --host parameter");
$server = &find_one_managed_server($host);
$server || &usage("No system with hostname $host exists");
$dir || &usage("Missing --dir parameter");
&can_action_usage($server, "transfer");

# Mount if needed
$err = &mount_filesystem_if_needed($server);
if ($err) {
	print "ERROR: $err\n";
	exit(2);
	}

# List the directory contents
$files = &list_dir_on_server($server, $dir);
&umount_filesystem_if_needed($server);
if (!ref($files)) {
	print "ERROR: $files\n";
	exit(3);
	}

# Show contents
foreach $f (@$files) {
	next if ($f eq "." || $f eq "..");
	print $f,"\n";
	}

&cloudmin_api_log(\@OLDARGV);

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Lists the contents of a directory on a remote system.\n";
print "\n";
print "cloudmin list-directory --host name\n";
print "                        --dir path\n";
exit(1);
}

