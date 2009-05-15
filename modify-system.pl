#!/usr/local/bin/perl

=head1 modify-system.pl

Changes the description, hostname, OS or login details of a single system

This command can change the details of an existing system, such as its
hostname, description, OS or the passwords used by Cloudmin to login via SSH and
Webmin. The system to change is specified using the --host parameter, which
of course must be followed by a hostname. All other parameters are optional,
and the most commonly used ones are :

C<--desc> I<new description>
Sets a new human-readable description for this system.

C<--newhost> I<hostname>
Changes the hostname used by Cloudmin. This must resolve to the same IP address as the old name, unless the C<--force-host> flag is given.

C<--os> I<code>
Changes the operating system code, to something like debian or centos.

C<--ssh-pass> I<password>
Changes the password Cloudmin will use to login, *not* the system's actual root password.

C<--boot> or C<--no-boot>
Either enables the system at host boot time, or disables it.

=head1 Example usage

  cloudmin modify-system --host xencentos.home --desc "CentOS 5 on Xen"
  xencentos.home modified successfully

=cut 

package server_manager;
$main::no_acl_check++;
$ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
$ENV{'WEBMIN_VAR'} ||= "/var/webmin";
if ($0 =~ /^(.*\/)[^\/]+$/) {
	chdir($1);
	}
chop($pwd = `pwd`);
$0 = "$pwd/modify-system.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";

# Parse command line
while(@ARGV > 0) {
	local $a = shift(@ARGV);
	if ($a eq "--host") {
		$host = shift(@ARGV);
		}
	elsif ($a eq "--force-host") {
		$forcehost = 1;
		}
	elsif ($a eq "--desc") {
		$desc = shift(@ARGV);
		}
	elsif ($a eq "--os") {
		$type = shift(@ARGV);
		}
	elsif ($a eq "--newhost") {
		$newhost = shift(@ARGV);
		}
	elsif ($a eq "--ssh-user") {
		$ssh_user = shift(@ARGV);
		}
	elsif ($a eq "--ssh-pass") {
		$ssh_pass = shift(@ARGV);
		}
	elsif ($a eq "--ssh-key") {
		$ssh_key = shift(@ARGV);
		}
	elsif ($a eq "--ssh-port") {
		$ssh_port = shift(@ARGV);
		$ssh_port =~ /^\d+$/ || $ssh_port > 0 && $ssh_port < 65536 ||
			&usage("Invalid SSH port number");
		}
	elsif ($a eq "--default-ssh-port") {
		$ssh_port = "";
		}
	elsif ($a eq "--webmin-same") {
		$webmin_same = 1;
		}
	elsif ($a eq "--webmin-user") {
		$webmin_user = shift(@ARGV);
		}
	elsif ($a eq "--webmin-pass") {
		$webmin_pass = shift(@ARGV);
		}
	elsif ($a eq "--boot") {
		$boot = 1;
		}
	elsif ($a eq "--no-boot") {
		$boot = 0;
		}
	elsif ($a eq "--packages") {
		$packages = 1;
		}
	elsif ($a eq "--no-packages") {
		$packages = 0;
		}
	else {
		&usage();
		}
	}

# Get the server
$host || &usage("Missing --host parameter");
$server = &get_managed_server_by("host", $host);
$server || &usage("System with hostname $host does not exist");

# Validate all options
if (defined($desc)) {
	$server->{'id'} == 0 && &usage("The description for this system ".
				       "cannot be changed");
	}
if (defined($type)) {
	($st) = grep { $_->[0] eq $type } @servers::server_types;
	$st || &usage("Invalid value for --os. Know operating system ".
		      "codes are : ".join(" ", map { $_->[0] }
						@servers::server_types));
	}
if (defined($newhost)) {
	$server->{'id'} == 0 && &usage("The hostname for this system ".
				       "cannot be changed");
	$oldip = &to_ipaddress($server->{'host'});
	$newip = &to_ipaddress($newhost);
	if ($oldip && $oldip ne $newip && !$forcehost) {
		&usage("The new hostname must resolve to the same IP address ".
		       "as the old hostname, or --force-host must be used");
		}
	}

# Validate SSH login parameters
$sfunc = "type_".$server->{'type'}."_no_ssh";
$hasssh = !defined(&$sfunc) || !&$sfunc();
defined($ssh_key) && defined($ssh_pass) &&
	&usage("Only one of --ssh-pass or --ssh-key can be given");
if (defined($ssh_key)) {
	$hasssh || &usage("This system type does not support SSH");
	($key) = grep { $_->{'id'} eq $ssh_key } @keys;
	$key || &usage("No SSH key with ID $ssh_key found");
	$newsame = $webmin_same ? 1 :
		   $webmin_pass ? 0 : $server->{'ssh_pass_same'};
	$newsame && &usage("An SSH key cannot be used when the system is ".
			   "using the same password for Webmin and SSH");
	}
elsif (defined($ssh_pass)) {
	$hasssh || &usage("This system type does not support SSH");
	}

# Make all the changes
if (defined($desc)) {
	$server->{'desc'} = $desc;
	}
if (defined($type)) {
	$server->{'type'} = $type;
	}
if (defined($type)) {
	$server->{'type'} = $type;
	}
if (defined($newhost)) {
	$server->{'host'} = $newhost;
	}
if (defined($ssh_pass)) {
	$server->{'ssh_pass'} = $ssh_pass;
	delete($server->{'key'});
	if ($server->{'ssh_pass_same'}) {
		$server->{'pass'} = $ssh_pass;
		}
	$recheck = 1;
	}
elsif (defined($ssh_key)) {
	delete($server->{'ssh_pass'});
	$server->{'key'} = $key->{'id'};
	$recheck = 1;
	}
if (defined($ssh_user)) {
	$server->{'ssh_user'} = $ssh_user;
	$recheck = 1;
	}
if (defined($ssh_port)) {
	$server->{'ssh_port'} = $ssh_port;
	$recheck = 1;
	}
if ($webmin_same) {
	$server->{'ssh_pass_same'} = 1;
	$server->{'user'} = 'root';
	$server->{'pass'} = $server->{'ssh_pass'};
	$recheck = 1;
	}
else {
	if (defined($webmin_user)) {
		$server->{'user'} = $webmin_user;
		$server->{'ssh_pass_same'} = 0;
		$recheck = 1;
		}
	if (defined($webmin_pass)) {
		$server->{'pass'} = $webmin_pass;
		$server->{'ssh_pass_same'} = 0;
		$recheck = 1;
		}
	}

# Change boot status
if (defined($boot)) {
	$bfunc = "type_".$server->{'manager'}."_set_atboot";
	defined(&$bfunc) || &usage("This server type cannot be enabled or ".
				   "disabled at host boot");
	&$bfunc($server, $boot);
	}

# Enable or disable package management
if (defined($packages)) {
	$err = &save_server_cluster_software($server, $packages);
	if ($err && $packages) {
		&usage("Package management cannot be enabled : $err");
		}
	elsif ($err && !$packages) {
		&usage("Package management cannot be disabled : $err");
		}
	}

# Update status if needed
if ($recheck) {
	&check_server_status($server);
	}
&save_managed_server($server);
print "$server->{'host'} modified successfully\n";
if ($recheck) {
	$desc = $text{'status_'.$server->{'status'}};
	print "New status is: $server->{'status'} ($desc)\n";
	}

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Modifies the details of one managed system.\n";
print "\n";
print "cloudmin modify-system --host name\n";
print "                      [--force-host]\n";
print "                      [--desc \"new description\"]\n";
print "                      [--newhost name]\n";
print "                      [--os code]\n";
print "                      [--virt | --novirt]\n";
print "                      [--ssh-pass passsword | --ssh-key keyid]\n";
print "                      [--ssh-user username]\n";
print "                      [--ssh-port number | --default-ssh-port]\n";
print "                      [--webmin-user user]\n";
print "                      [--webmin-pass password]\n";
print "                      [--webmin-same]\n";
print "                      [--boot | --no-boot]\n";
exit(1);
}

