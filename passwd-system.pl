#!/usr/local/bin/perl

=head1 passwd-system.pl

Changes the SSH and/or Webmin password on some system

This command can be used to change the root password for SSH or Webmin on a
managed system. The Unix password can be set with the C<--ssh-pass> parameter,
while the Webmin password can be changed with C<--webmin-pass>. To configure
Webmin to check the Unix password when root logs, use the C<--webmin-same>
parameter.

When the command is run, it will update C</etc/shadow> and
C</etc/webmin/miniserv.users> on the selected machine to make the changes.
VM2's authentication information for the system will also be updated to match.

If you have created a virtual system for a customer, changing the root
password when you are ready to hand it over is a good idea. Be aware that 
for Xen systems, if the password is changed on the system directly (perhaps
using the passwd command), VM2 will be no longer able to login via SSH to
change it, or even to check the system's status.

=cut

package server_manager;
$main::no_acl_check++;
$ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
$ENV{'WEBMIN_VAR'} ||= "/var/webmin";
if ($0 =~ /^(.*\/)[^\/]+$/) {
	chdir($1);
	}
chop($pwd = `pwd`);
$0 = "$pwd/passwd-system.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";

# Parse command line
while(@ARGV > 0) {
	local $a = shift(@ARGV);
	if ($a eq "--host") {
		$host = shift(@ARGV);
		}
	elsif ($a eq "--ssh-pass") {
		$ssh_pass = shift(@ARGV);
		}
	elsif ($a eq "--webmin-pass") {
		$webmin_pass = shift(@ARGV);
		}
	elsif ($a eq "--webmin-same") {
		$webmin_same = 1;
		}
	else {
		&usage();
		}
	}

# Check for required inputs
$host || &usage("Missing --host parameter");
defined($ssh_pass) || defined($webmin_pass) || $webmin_same ||
	&usage("No password changes specified");
$server = &get_managed_server_by("host", $host);
$server || &usage("System with hostname $host does not exist");

# Check if same is possible
if ($webmin_same && !$server->{'ssh_pass'} && !$ssh_pass) {
	&usage("The current Unix password is not known, so --webmin-same cannot be used");
	}
$failed = 0;

if (defined($ssh_pass)) {
	# Set SSH password
	print "Setting SSH password ..\n";
	$err = &set_shadow_root_password($server, $ssh_pass);
	if ($err) {
		print ".. failed : $err\n\n";
		$failed++;
		}
	else {
		print ".. password changed\n\n";
		$server->{'ssh_pass'} = $ssh_pass;
		if ($server->{'ssh_pass_same'}) {
			$server->{'pass'} = $ssh_pass;
			}
		delete($server->{'key'});
		&save_managed_server($server);
		}
	}

if (defined($webmin_pass)) {
	# Set Webmin password
	print "Setting Webmin password ..\n";
	($sshstatus, $ssherr, $wroot, $wport, $wssl) =
		&check_server_ssh_login($server);
	$err = &set_server_webmin_password($server, $wroot,
					   'root', $webmin_pass);
	if ($err) {
		print ".. failed : $err\n\n";
		$failed++;
		}
	else {
		print ".. password changed\n\n";
		$server->{'pass'} = $webmin_pass;
		$server->{'ssh_pass_same'} = 0;
		}
	}
elsif ($webmin_same) {
	# Make Webmin same as Unix
	print "Configuring Webmin to use SSH password ..\n";
	$err = &set_server_webmin_password_crypt($server, 'root', 'x');
	if ($err) {
		print ".. failed : $err\n\n";
		$failed++;
		}
	else {
		print ".. done\n\n";
		$server->{'pass'} = $server->{'ssh_pass'};
		$server->{'ssh_pass_same'} = 1;
		}
	}

# Refresh status
print "Re-checking system status..\n";
&check_server_status($server, 0, 1);
&save_managed_server($server);
print ".. done\n\n";

exit($failed);

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Changes the SSH or Webmin passwords for a managed system.\n";
print "\n";
print "usage: passwd-systems.pl --host name\n";
print "                         [--ssh-pass password]\n";
print "                         [--webmin-pass password | --webmin-same]\n";
exit(1);
}

