#!/usr/local/bin/perl

=head1 delete-disk.pl

Remove a virtual disk from some system

This command dis-associates a real file or device with a virtual device on
some system, and deletes the underlying file. The system to modify is
identified with the C<--host> flag, and the disk to remove can be set with
either C<--real> followed by the real file (like C</xen/newdisk.img>) or 
C<--virt> followed by the device on the virtual system (like C</dev/sda3>).

If the system is running, the disk will not be really deleted until it is 
shutdown or restarted, and thus the disk space on the host system will not be
immediately freed up.

=head1 Example usage

  cloudmin delete-disk --host xencentos.home --virt /dev/sda3
  Removing virtual disk for /dev/sda3 ..
  .. done. However, the disk will not be fully removed until the system is rebooted

=cut

package server_manager;
$main::no_acl_check++;
$ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
$ENV{'WEBMIN_VAR'} ||= "/var/webmin";
if ($0 =~ /^(.*\/)[^\/]+$/) {
	chdir($1);
	}
chop($pwd = `pwd`);
$0 = "$pwd/delete-disk.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";

# Parse command line
&set_all_text_print();
while(@ARGV > 0) {
	local $a = shift(@ARGV);
	if ($a eq "--host") {
		$host = shift(@ARGV);
		}
	elsif ($a eq "--real") {
		$real = shift(@ARGV);
		}
	elsif ($a eq "--virt") {
		$virt = shift(@ARGV);
		}
	else {
		&usage();
		}
	}

# Validate parameters
$real || $virt || &usage("The disk to remove must be identified by the --real or --virt parameters");

# Get the server
$host || &usage("Missing --host parameter");
$server = &get_managed_server_by("host", $host);
$server || &usage("System with hostname $host does not exist");
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
else {
	($disk) = grep { $_->{'virt'} eq $virt } @$disks;
	$disk || &usage("No disk mapped to the virtual device $virt was found");
	}
$disk->{'mount'} eq '/' && &usage("The disk mounted on / cannot be removed, as this will make the system un-bootable");

# Do it
&$first_print("Removing virtual disk for $disk->{'virt'} ..");
$cfunc = "type_".$server->{'manager'}."_delete_disk";
$err = &$cfunc($server, $disk);
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
&release_lock_server($server);

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Removes a disk device from some virtual system.\n";
print "\n";
print "cloudmin delete-disk --host hostname\n";
print "                     --real device|file | --virt device\n";
exit(1);
}

