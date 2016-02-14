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

C<--notes> I<text>
Sets the notes for some system. Use \n to indicate a newline in the text.

C<--newhost> I<hostname>
Changes the hostname used by Cloudmin. This must resolve to the same IP address as the old name, unless the C<--force-host> flag is given.

C<--os> I<code>
Changes the operating system code, to something like debian or centos.

C<--ssh-pass> I<password>
Changes the password Cloudmin will use to login, *not* the system's actual root password.

C<--boot> or C<--no-boot>
Either enables the system at host boot time, or disables it.

C<--boot-mode> I<mode>
Changes the way the system boots, which typically determines which kernel it uses.

C<--boot-device> I<id>
Changes the device the system boots from. For KVM, device codes are I<c> (hard dsk) or I<d> (CDROM).

C<--location> I<name> or C<--no-location>
Sets the location group for a host system, or removes it from a group.

C<--force-ip> I<address> or C<--no-force-ip>
Forces Cloudmin to use a specific IP address to contact this system, or just uses the default.

C<--virt> I<address> or C<--novirt>
Determines if Cloudmin will create Virtualmin domains on this system or not.

C<--disk-directory> I<path> or C<--no-disk-directory>
Sets the default image directory for new virtual disks.

C<--webmin-url> I<url> or C<--no-webmin-url>
Changes the URL used in the "Link to Webmin" menu entry in the Cloudmin UI.

C<--webmin-ssl> or C<--no-webmin-ssl>
Turns on or off use of SSL to connect to Webmin. By default this is determined
automatically when a VM is created or added to Cloudmin.

C<--webmin-verify-ssl> or C<--no-webmin-verify-ssl>
Turns on or off verification of the Webmin SSL certificate. This will reject
self-signed certs, those for a different hostname, and certs not signed by
a recognized CA.

=head1 Example usage

  cloudmin modify-system --host xencentos.home --desc "CentOS 5 on Xen"
  xencentos.home modified successfully

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
$0 = "$pwd/modify-system.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";
@OLDARGV = @ARGV;
&usage_if_cloudmin_replica();

# Parse command line
while(@ARGV > 0) {
	my $a = shift(@ARGV);
	if ($a eq "--host") {
		$host = shift(@ARGV);
		}
	elsif ($a eq "--force-host") {
		$forcehost = 1;
		}
	elsif ($a eq "--desc") {
		$desc = shift(@ARGV);
		}
	elsif ($a eq "--notes") {
		$notes = shift(@ARGV);
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
	elsif ($a eq "--ssh-sudo") {
		$ssh_sudo = 1;
		}
	elsif ($a eq "--no-ssh-sudo") {
		$ssh_sudo = 0;
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
	elsif ($a eq "--ssh-cipher") {
		$ssh_ciphers = shift(@ARGV);
		}
	elsif ($a eq "--default-ssh-cipher") {
		$ssh_ciphers = "";
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
	elsif ($a eq "--webmin-ssl") {
		$ssl = 1;
		}
	elsif ($a eq "--no-webmin-ssl") {
		$ssl = 0;
		}
	elsif ($a eq "--webmin-verify-ssl") {
		$checkssl = 1;
		}
	elsif ($a eq "--no-webmin-verify-ssl") {
		$checkssl = 0;
		}
	elsif ($a eq "--boot") {
		$boot = 1;
		}
	elsif ($a eq "--no-boot") {
		$boot = 0;
		}
	elsif ($a eq "--boot-mode") {
		$bootmode = shift(@ARGV);
		}
	elsif ($a eq "--boot-device") {
		$bootdevice = shift(@ARGV);
		}
	elsif ($a eq "--location") {
		$lname = shift(@ARGV);
		($loc) = grep { $_->{'id'} eq $lname ||
				lc($_->{'desc'}) eq lc($lname) }
			      &list_locations();
		$loc || &usage("No location with name or ID $lname found");
		}
	elsif ($a eq "--no-location") {
		$loc = '';
		}
	elsif ($a eq "--force-ip") {
		$force_ip = shift(@ARGV);
		&check_ipaddress($force_ip) ||
			&usage("--force-ip must be followed by an address");
		}
	elsif ($a eq "--no-force-ip") {
		$force_ip = "";
		}
	elsif ($a eq "--disk-directory") {
		$directory = shift(@ARGV);
		$directory =~ /^\/\S+$/ ||
		    &usage("--disk-directory must be followed by a full path");
		}
	elsif ($a eq "--no-disk-directory") {
		$directory = "";
		}
	elsif ($a eq "--webmin-url") {
		$wurl = shift(@ARGV);
		$wurl =~ /^(http|https):\/\/\S+$/ ||
			&usage("--webmin-url must be followed by a full URL");
		}
	elsif ($a eq "--no-webmin-url") {
		$wurl = "";
		}
	elsif ($a eq "--multiline") {
		$multiline = 1;
		}
	else {
		&usage("Unknown parameter $a");
		}
	}

# Get the server
$host || &usage("Missing --host parameter");
$server = &find_one_managed_server($host);
$server || &usage("System with hostname $host does not exist");
$oldserver = { %$server };
&can_action_usage($server, "edit");
&obtain_lock_server($server);

# Validate all options
if (defined($desc)) {
	$server->{'id'} == 0 && &usage("The description for this system ".
				       "cannot be changed");
	}
if (defined($type)) {
	($st) = grep { $_->[0] eq $type } @servers::server_types;
	$st || &usage("Invalid value for --os. Known operating system ".
		      "codes are : ".join(" ", map { $_->[0] }
						@servers::server_types));
	}
if (defined($newhost)) {
	$server->{'id'} == 0 && &usage("The hostname for this system ".
				       "cannot be changed");
	my $rfunc = "type_".$server->{'manager'}."_requires_resolution";
	if (!defined(&$rfunc) || &$rfunc($server)) {
		$oldip = &to_ipaddress($server->{'host'});
		$newip = &to_ipaddress($newhost);
		if ($oldip && $oldip ne $newip && !$forcehost) {
			&usage("The new hostname must resolve to the same IP ".
			       "address as the old hostname, or --force-host ".
			       "must be used");
			}
		}
	}
if (defined($loc)) {
	&is_parent_server($server) ||
		&usage("The --location and --no-location flags can only be ".
		       "used for host systems");
	}

# Validate SSH login parameters
$sfunc = "type_".$server->{'type'}."_no_ssh";
$hasssh = !defined(&$sfunc) || !&$sfunc();
defined($ssh_key) && defined($ssh_pass) &&
	&usage("Only one of --ssh-pass or --ssh-key can be given");
if (defined($ssh_key)) {
	&can_action_usage(undef, "sshkeys");
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

# Validate boot mode
if ($bootmode) {
	&can_action_usage($server, "boot");
	$mfunc = "type_".$server->{'manager'}."_list_boot_modes";
	defined(&$mfunc) || &usage("This virtual system type does not support ".
				   "changing the boot mode");
	$modes = &$mfunc($server);
	$modes || &usage("This virtual system type does not support ".
                         "changing the boot mode");
	ref($modes) || &usage("Failed to check boot modes : $modes");
	($canmode) = grep { $_->{'id'} eq $bootmode } @$modes;
	$canmode || &usage("Invalid boot mode - possible options are : ".
			   join(" ", map { $_->{'id'} } @$modes));
	}

# Validate boot device(s)
if ($bootdevice) {
	&can_action_usage($server, "boot");
	$mfunc = "type_".$server->{'manager'}."_list_boot_devices";
	defined(&$mfunc) || &usage("This virtual system type does not support ".
				   "changing the boot device");
	$devices = &$mfunc($server);
	$devices || &usage("This virtual system type does not support ".
                           "changing the boot device");
	ref($devices) || &usage("Failed to check boot devices : $devices");
	$gfunc = "type_".$server->{'manager'}."_get_boot_device";
	($ok, $olddevice) = &$gfunc($server);
	@bootdevices = split(/[ ,]+/, $bootdevice);
	foreach $d (@bootdevices) {
		($candevice) = grep { $_->{'id'} eq $d } @$devices;
		$candevice ||
		    &usage("Invalid boot device $d - possible options are : ".
			   join(" ", map { $_->{'id'} } @$devices));
		}
	@bootdevices || &usage("Missing boot device");
	if (!ref($olddevice)) {
		@bootdevices == 1 || &usage("Only one boot device may be set");
		}
	}

# Validate and save disk directory
if (defined($directory) && $server->{'new_directory'} ne $directory) {
	$server->{'new_directory'} = $directory;
	$err = &validate_directory($server, undef, 'new_directory');
	$err && &usage("--disk-directory is invalid : $err");
	}

# Make all the changes
if (defined($desc)) {
	$server->{'desc'} = $desc;
	}
if (defined($notes)) {
	$notes =~ s/\\n/\t/g;
	$server->{'notes'} = $notes;
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
if (defined($ssh_sudo)) {
	$server->{'ssh_sudo'} = $ssh_sudo;
	$recheck = 1;
	}
if (defined($ssh_port)) {
	$server->{'ssh_port'} = $ssh_port;
	$recheck = 1;
	}
if (defined($ssh_ciphers)) {
	$ssh_ciphers eq "" ||
	    &indexof($ssh_ciphers, map { $_->[0] } &list_ssh_ciphers()) >= 0 ||
		&usage("SSH cipher $ssh_ciphers is not supported");
	$server->{'ssh_ciphers'} = $ssh_ciphers;
	$recheck = 1;
	}
if (defined($force_ip)) {
	$server->{'ip_force'} = $force_ip;
	$recheck = 1;
	&complete_managed_server($server);	# To refresh 'ip' field
	}
if (defined($wurl)) {
	$server->{'webmin_url'} = $wurl;
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
if (defined($checkssl)) {
	$server->{'checkssl'} = $checkssl;
	$recheck = 1;
	}
if (defined($ssl)) {
	$server->{'ssl'} = $ssl;
	$recheck = 1;
	}
if (defined($loc)) {
	$server->{'location'} = $loc ? $loc->{'id'} : undef;
	}

# Change boot status
if (defined($boot)) {
	$bfunc = "type_".$server->{'manager'}."_set_atboot";
	defined(&$bfunc) || &usage("This server type cannot be enabled or ".
				   "disabled at host boot");
	$err = &$bfunc($server, $boot);
	if ($err) {
		&usage("Failed to ".($boot ? "enable" : "disable").
		       " at boot : $err");
		}
	}

# Change boot mode
if ($bootmode) {
	$mfunc = "type_".$server->{'manager'}."_set_boot_mode";
	$err = &$mfunc($server, $bootmode);
	$err && &usage("Failed to change boot mode to $bootmode : $err");
	}

# Change boot device
if ($bootdevice) {
	$mfunc = "type_".$server->{'manager'}."_set_boot_device";
	$err = &$mfunc($server, ref($olddevice) ? \@bootdevices
						: $bootdevices[0]);
	$err && &usage("Failed to change boot device to $bootdevice : $err");
	}

# Call post-save function
$psfunc = "type_".$server->{'manager'}."_post_save";
if (defined(&$psfunc)) {
	$err = &$psfunc($server, $oldserver);
	&error($err) if ($err);
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
&release_lock_server($server);
&cloudmin_api_log(\@OLDARGV);

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Modifies the details of one managed system.\n";
print "\n";
print "cloudmin modify-system --host name\n";
print "                      [--force-host]\n";
print "                      [--desc \"new description\"]\n";
print "                      [--notes \"new notes text\"]\n";
print "                      [--newhost name]\n";
print "                      [--os code]\n";
print "                      [--virt | --novirt]\n";
print "                      [--ssh-pass passsword | --ssh-key keyid]\n";
print "                      [--ssh-user username]\n";
print "                      [--ssh-sudo | --no-ssh-sudo]\n";
print "                      [--ssh-port number | --default-ssh-port]\n";
print "                      [--webmin-user user]\n";
print "                      [--webmin-pass password]\n";
print "                      [--webmin-same]\n";
print "                      [--webmin-ssl | --no-webmin-ssl]\n";
print "                      [--boot | --no-boot]\n";
print "                      [--boot-mode mode]\n";
print "                      [--boot-device device]\n";
if (defined(&list_locations)) {
	print "                      [--location id | --no-location]\n";
	}
print "                      [--force-ip address | --no-force-ip]\n";
print "                      [--disk-directory path |\n";
print "                       --no-disk-directory]\n";
print "                      [--webmin-url url | --no-webmin-url]\n";
print "                      [--webmin-verify-ssl | --no-webmin-verify-ssl]\n";
exit(1);
}

