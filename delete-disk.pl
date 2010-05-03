#!/usr/local/bin/perl

=head1 delete-disk.pl

Remove a virtual disk from some system

This command dis-associates a real file or device with a virtual device on
some system, and deletes the underlying file. The system to modify is
identified with the C<--host> flag, and the disk to remove can be set with
either C<--real> followed by the real file (like C</xen/newdisk.img>),
C<--virt> followed by the device on the virtual system (like C</dev/sda3>),
or C<--lv> followed by the logical volume name.

If the system is running, the disk may not be really deleted until it is 
shutdown or restarted, and thus the disk space on the host system will not be
immediately freed up.

To simply detach a disk from a virtual system without deleting the underlying
image file or logical volume, use the C<--detach> flag. The file or LV can be
later attached to another system with the C<create-disk> API command.

=head1 Example usage

  cloudmin delete-disk --host xencentos.home --virt /dev/sda3
  Removing virtual disk for /dev/sda3 ..
  .. done. However, the disk will not be fully removed until the system is rebooted

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
$0 = "$pwd/delete-disk.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";
@OLDARGV = @ARGV;
&usage_if_cloudmin_replica();

# Parse command line
&set_all_text_print();
while(@ARGV > 0) {
	my $a = shift(@ARGV);
	if ($a eq "--host") {
		$host = shift(@ARGV);
		}
	elsif ($a eq "--real") {
		$real = shift(@ARGV);
		}
	elsif ($a eq "--mount") {
		$mount = shift(@ARGV);
		}
	elsif ($a eq "--lv") {
		$lv = shift(@ARGV);
		}
	elsif ($a eq "--virt") {
		$virt = shift(@ARGV);
		}
	elsif ($a eq "--detach") {
		$detach = 1;
		}
	else {
		&usage();
		}
	}

# Validate parameters
$real || $virt || $lv || $mount || &usage("The disk to remove must be identified by the --real, --virt, --mount or --lv parameters");

# Get the server
$host || &usage("Missing --host parameter");
$server = &get_managed_server_by("host", $host);
$server || &usage("System with hostname $host does not exist");
&can_action_usage($server, "disks");
&obtain_lock_server($server);

# Get the current disks
$dfunc = "type_".$server->{'manager'}."_list_disks";
defined(&$dfunc) || &usage("System type $server->{'manager'} does not support ".
			   "disk management");
$cfunc = "type_".$server->{'manager'}."_can_disks";
defined(&$cfunc) && &$cfunc($server) ||
	&usage("Disks cannot be managed on this system");
$disks = &$dfunc($server, 1);
if (!ref($disks)) {
	# Try again without asking for mounts, as they may not be available
	$disks = &$dfunc($server, 0);
	}
ref($disks) || &usage("Failed to list disks : $disks");

# Find the disk to kill
if ($real) {
	($disk) = grep { $_->{'real'} eq $real } @$disks;
	$disk || &usage("No disk for the real file or device $real was found");
	}
elsif ($lv) {
	($disk) = grep { $_->{'lv'} eq $lv } @$disks;
	$disk || &usage("No disk for the LVM logical volume $lv was found");
	}
elsif ($mount) {
	($disk) = grep { $_->{'mount'} eq $mount } @$disks;
	$disk || &usage("No disk for the mount point $mount was found");
	}
else {
	($disk) = grep { $_->{'virt'} eq $virt } @$disks;
	$disk || &usage("No disk mapped to the virtual device $virt was found");
	}
$disk->{'mount'} eq '/' && &usage("The disk mounted on / cannot be removed, as this will make the system un-bootable");

# Do it
if ($detach) {
	&$first_print("Detaching virtual disk for $disk->{'virt'} ..");
	}
else {
	&$first_print("Deleting virtual disk for $disk->{'virt'} ..");
	}
$cfunc = "type_".$server->{'manager'}."_delete_disk";
$err = &$cfunc($server, $disk, $detach);
if ($err) {
	&$second_print(".. failed : $err");
	}
else {
	# Tell the user about reboot
	$rfunc = "type_".$server->{'manager'}."_need_disk_reboot";
	if (defined(&$rfunc) && &$rfunc($server, $disk)) {
		&$second_print(".. done. However, the disk will not be fully removed until the system is rebooted");
		}
	else {
		&$second_print(".. done");
		}
	}
&save_managed_server($server);
&release_lock_server($server);
&cloudmin_api_log(\@OLDARGV);

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Removes a disk device from some virtual system.\n";
print "\n";
print "cloudmin delete-disk --host hostname\n";
print "                     --real device|file | --virt device | --lv name\n";
print "                    [--detach]\n";
exit(1);
}

