#!/usr/local/bin/perl

=head1 vnc-system.pl

Opens a port connected to the VNC console of a system.

This command can be used to connect a port on the Cloudmin master to the VNC
console of a virtual system, so that a stand-along VNC client can be used to
connect to it. On success it outputs the port to use on the master, and the
VNC password required to connect to the VM.

=head1 Example usage

  cloudmin vnc-system --host xencentos.home
  OK: 5910 changeme

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
$0 = "$pwd/reboot-system.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";
@OLDARGV = @ARGV;
&usage_if_cloudmin_replica();

# Parse command line
while(@ARGV > 0) {
	my $a = shift(@ARGV);
	if ($a eq "--host") {
		$hostname = shift(@ARGV);
		}
	elsif ($a eq "--multiline") {
		$multiline = 1;
		}
	elsif ($a eq "--help") {
		&usage();
		}
	else {
		&usage("Unknown parameter $a");
		}
	}

# Get the system
$hostname || &usage("Missing --host parameter");
($server) = &find_managed_servers(0, [ $hostname ], [ ], [ ], [ ], [ ]);
$server || &usage("No system named $hostname found");
&can_action_usage($server, "console");

# Does it support VNC?
$vfunc = "type_".$server->{'manager'}."_open_vnc_port";
defined(&$vfunc) || &usage("System does not support VNC console access");

# Open the port and return to the user
($masterport, $pass) = &$vfunc($server);
if (!$masterport) {
	print "ERROR: $pass\n";
	exit(1);
	}
else {
	print "OK: $masterport $pass\n";
	}

&cloudmin_api_log(\@OLDARGV);

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Opens a port connected to the VNC console of a system.\n";
print "\n";
print "cloudmin vnc-system --host name\n";
exit(1);
}

