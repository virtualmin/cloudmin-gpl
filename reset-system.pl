#!/usr/local/bin/perl
# Resets a virtual system to its original image file

=head1 reset-system.pl

Resets a virtual system to its original image

XXXX

=head1 Example usage

  cloudmin reset-system --host xengtest.home --dest geylang.home
  XXX

=cut

package server_manager;
$main::no_acl_check++;
$ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
$ENV{'WEBMIN_VAR'} ||= "/var/webmin";
if ($0 =~ /^(.*\/)[^\/]+$/) {
	chdir($1);
	}
chop($pwd = `pwd`);
$0 = "$pwd/reset-system.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";
&set_all_text_print();

# Parse command line
while(@ARGV > 0) {
	my $a = shift(@ARGV);
	if ($a eq "--host") {
		$host = shift(@ARGV);
		}
	else {
		&usage();
		}
	}

# Check for mandatory args, and get the system
$host || &usage("Missing --host parameter");
$server = &get_managed_server_by("host", $host);

# Check if supported
$dfunc = "type_".$server->{'manager'}."_desc";
$desc = &$dfunc();
$cfunc = "type_".$server->{'manager'}."_can_reset";
defined(&$cfunc) || &usage("Systems of type $desc cannot be reset");
&$cfunc($server) || &usage("The selected system cannot be reset");

# Do the reset
print "Resetting $desc system $server->{'host'} ..\n\n";
&obtain_lock_server($server);
$err = &reset_system($server);
&release_lock_server($server);
if ($err) {
	print $err,"\n";
	exit(1);
	}
print ".. all done\n";

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Resets a virtual system to its original image.\n";
print "\n";
print "cloudmin reset-system --host name\n";
exit(1);
}

