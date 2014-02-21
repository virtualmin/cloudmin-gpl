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
Cloudmin's authentication information for the system will also be updated to
match.

Alternately, you can configure the system to accept root logins via an SSH
key setup in Cloudmin with the C<--ssh-key> flag, followed by a key ID.
Registered keys can be fetched from the C<list-ssh-keys> API command. This will
update the C</root/.ssh/authorized_keys> file on the virtual system.

If you have created a virtual system for a customer, changing the root
password when you are ready to hand it over is a good idea. Be aware that 
for Xen systems, if the password is changed on the system directly (perhaps
using the passwd command), Cloudmin will be no longer able to login via SSH to
change it, or even to check the system's status.

For Xen and KVM systems, the password used for access to the graphical console
can be changed with the C<--graphical-pass> flag followed by a new password.
By default this is the same as the SSH password, or a random string if no 
password was set at creation time.

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
$0 = "$pwd/passwd-system.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";
@OLDARGV = @ARGV;
&usage_if_cloudmin_replica();

# Parse command line
@keys = &list_ssh_keys();
while(@ARGV > 0) {
	my $a = shift(@ARGV);
	if ($a eq "--host") {
		$host = shift(@ARGV);
		}
	elsif ($a eq "--ssh-pass") {
		$ssh_pass = shift(@ARGV);
		}
	elsif ($a eq "--ssh-key") {
		&can_action_usage(undef, "sshkeys");
		$ssh_key = shift(@ARGV);
		($key) = grep { $_->{'id'} eq $ssh_key } @keys;
		$key || &usage("No SSH key with ID $ssh_key found");
		$key->{'public'} &&
		  &usage("The SSH key with ID $ssh_key is a public key only");
		}
	elsif ($a eq "--webmin-pass") {
		$webmin_pass = shift(@ARGV);
		}
	elsif ($a eq "--webmin-same") {
		$webmin_same = 1;
		}
	elsif ($a eq "--graphical-pass") {
		$vnc_pass = shift(@ARGV);
		$vnc_pass =~ /^\S+$/ ||
			&usage("--graphical-pass must be followed by a ".
			       "password without spaces");
		}
	elsif ($a eq "--multiline") {
		$multiline = 1;
		}
	else {
		&usage("Unknown parameter $a");
		}
	}

# Check for required inputs
$host || &usage("Missing --host parameter");
defined($ssh_pass) || defined($key) || defined($webmin_pass) || $webmin_same ||
    defined($vnc_pass) || &usage("No password changes specified");
$ssh_pass && $key && &usage("Only one of --ssh-pass or --ssh-key can be used");
$server = &find_one_managed_server($host);
$server || &usage("System with hostname $host does not exist");
&can_action_usage($server, "pass"); 

# Check if same is possible
if ($webmin_same && !$server->{'ssh_pass'} && !$ssh_pass) {
	&usage("The current Unix password is not known, so --webmin-same cannot be used");
	}

# Check if graphical pass can be set
if ($vnc_pass) {
	$cfunc = "type_".$server->{'manager'}."_can_graphical_password";
	$vcan = defined(&$cfunc) && &$cfunc($server);
	$vcan || &usage("The graphical console password cannot be set ".
			"for this system");
	}

&obtain_lock_server($server);
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
elsif (defined($key)) {
	# Set SSH key
	print "Setting SSH key ..\n";
	$server->{'key'} = $key->{'id'};
	$err = &create_authorized_key($server, 1);
	if ($err) {
		print ".. failed : $err\n\n";
                $failed++;
                }
	else {
		print ".. configured to allow login with key\n\n";
		$server->{'ssh_pass_same'} = 0;
		delete($server->{'ssh_pass'});
		&save_managed_server($server);
		}
	}

if (defined($webmin_pass)) {
	# Set Webmin password
	print "Setting Webmin password ..\n";
	($sshstatus, $ssherr, $wroot, $wport, $wssl) =
		&check_server_ssh_login($server);
	$err = &set_server_webmin_password($server, $wroot,
				   $server->{'user'} || 'root', $webmin_pass);
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

if ($vnc_pass) {
	# Set VNC password
	print "Setting graphical console password ..\n";
	$sfunc = "type_".$server->{'manager'}."_set_graphical_password";
	$err = &$sfunc($server, $vnc_pass);
	if ($err) {
		print ".. failed : $err\n\n";
		$failed++;
		}
	else {
		print ".. done\n\n";
		$need_reboot++ if ($vcan == 2);
		}
	}

# Refresh status
print "Re-checking system status..\n";
&check_server_status($server, 0, 1);
&save_managed_server($server);
print ".. done, new status is ",&describe_status($server),"\n\n";

if ($need_reboot) {
	print "To apply the graphical console password change, the system must be shut down\n";
	print "and started up again.\n\n";
	}

&release_lock_server($server);
if (!$failed) {
	&cloudmin_api_log(\@OLDARGV);
	}
exit($failed);

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Changes the SSH or Webmin passwords for a managed system.\n";
print "\n";
print "cloudmin passwd-system --host name\n";
print "                      [--ssh-pass password | --ssh-key id]\n";
print "                      [--webmin-pass password | --webmin-same]\n";
print "                      [--graphical-pass password]\n";
exit(1);
}

