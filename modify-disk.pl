#!/usr/local/bin/perl

=head1 modify-disk.pl

Change the size or virtual device of some disk

This command is commonly used to increase or decrease the size of a virtual
disk file, perhaps because the filesystem on it is getting full. The system
the disk is on is set with the C<--host> flag, and the disk to change can
be specified by real filename using C<--real> or virtual device with C<--virt>.

To set a new size, use the C<--new-size> flag followed by a number in MB.
This is only possible if the system is not running, as resizing of an in-use
disk is not supported. If the new size is smaller than the amount of space
consumed by files on the filesystem, the resize will fail.

To change the device on the virtual system that the disk is mapped to, use
the C<--new-virt> flag followed by a device like I</dev/sda3>.

=head1 Example usage

  cloudmin modify-disk --host xencentos.home --virt /dev/sda3 --new-size 2048
  Modifying virtual disk for /dev/sda3 ..
  .. done

=cut

package server_manager;
$main::no_acl_check++;
$ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
$ENV{'WEBMIN_VAR'} ||= "/var/webmin";
if ($0 =~ /^(.*\/)[^\/]+$/) {
	chdir($1);
	}
chop($pwd = `pwd`);
$0 = "$pwd/modify-disk.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";

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
	elsif ($a eq "--lv") {
		$lv = shift(@ARGV);
		}
	elsif ($a eq "--virt") {
		$virt = shift(@ARGV);
		}
	elsif ($a eq "--new-size") {
		$newsize = shift(@ARGV);
		}
	elsif ($a eq "--new-virt") {
		$newvirt = shift(@ARGV);
		}
	else {
		&usage();
		}
	}

# Validate parameters
$real || $virt || $lv || &usage("The disk to modify must be identified by the --real, --virt or --lv parameters");
$newsize || $newvirt || &usage("Nothing to do");
!$newsize || $newsize =~ /^\d*$/ || &usage("Invalid --new-size parameter - must be followed by a number of MB");
!$newvirt || $virt =~ /^\/\S+$/ || &usage("Missing or invalid --new-virt parameter - should be like /dev/sda2");

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
ref($disks) || &usage("Failed to list disks : $disks");

# Find the disk to modify
if ($real) {
	($disk) = grep { $_->{'real'} eq $real } @$disks;
	$disk || &usage("No disk for the real file or device $real was found");
	}
elsif ($lv) {
	($disk) = grep { $_->{'lv'} eq $lv } @$disks;
	$disk || &usage("No disk for the LVM logical volume $lv was found");
	}
else {
	($disk) = grep { $_->{'virt'} eq $virt } @$disks;
	$disk || &usage("No disk mapped to the virtual device $virt was found");
	}

# Change the object
$olddisk = { %$disk };
if ($newsize) {
	$disk->{'size'} = $newsize*1024*1024;
	}
if ($newvirt) {
	$disk->{'virt'} = $newvirt;
	}

# Do it
&$first_print("Modifying virtual disk for $disk->{'virt'} ..");
$cfunc = "type_".$server->{'manager'}."_modify_disk";
$err = &$cfunc($server, $disk, $olddisk);
if ($err) {
	&$second_print(".. failed : $err");
	}
else {
	# Tell the user about reboot
	&$second_print(".. done");
	}
&release_lock_server($server);

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Changes the size or virtual device for a disk on some virtual system.\n";
print "\n";
print "cloudmin modify-disk --host hostname\n";
print "                     --real device|file | --virt device | --lv name\n";
print "                    [--new-size MB]\n";
print "                    [--new-virt device]\n";
exit(1);
}

