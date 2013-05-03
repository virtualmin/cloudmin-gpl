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

For disks that support changing the underlying file (like CDs), you can
use the C<--new-real> flag followed by a new path on the host system.

To change the media type of a disk, use the C<--new-media> flag followed by
a type such as I<disk> or I<cdrom>.

To change the caching mode of a disk, use the C<--new-cache> flag followed by
a mode like C<on> or C<off>.

Disks mounted from an iSCSI can be disconnected on the host system using
the C<--iscsi-disconnect> flag. To re-establish a connection, use the 
C<--iscsi-connect> flag.

=head1 Example usage

  cloudmin modify-disk --host xencentos.home --virt /dev/sda3 --new-size 2048
  Modifying virtual disk for /dev/sda3 ..
  .. done

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
$0 = "$pwd/modify-disk.pl";
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
	elsif ($a eq "--new-size") {
		$newsize = shift(@ARGV);
		}
	elsif ($a eq "--new-virt") {
		$newvirt = shift(@ARGV);
		}
	elsif ($a eq "--new-real") {
		$newreal = shift(@ARGV);
		}
	elsif ($a eq "--force") {
		$force = 1;
		}
	elsif ($a eq "--new-media") {
		$media = shift(@ARGV);
		}
	elsif ($a eq "--new-cache") {
		$cache = shift(@ARGV);
		}
	elsif ($a eq "--backup-include") {
		$include = 1;
		}
	elsif ($a eq "--backup-exclude") {
		$include = 0;
		}
	elsif ($a eq "--multiline") {
		$multiline = 1;
		}
	elsif ($a eq "--iscsi-disconnect") {
		$iscsi_connect = 0;
		}
	elsif ($a eq "--iscsi-connect") {
		$iscsi_connect = 1;
		}
	else {
		&usage("Unknown parameter $a");
		}
	}

# Validate parameters
$real || $virt || $lv || $mount ||
	&usage("The disk to modify must be identified by the ".
	       "--real, --virt, --mount or --lv parameters");
$newsize || $newvirt || $media || $cache || $newreal || defined($include) ||
	defined($iscsi_connect) || &usage("Nothing to do");
!$newsize || $newsize =~ /^\d*$/ ||
	&usage("Invalid --new-size parameter - must be followed by a ".
	       "number of MB");
!$newvirt || $virt =~ /^\/\S+$/ ||
	&usage("Missing or invalid --new-virt parameter - ".
	       "should be like /dev/sda2");

# Get the server
$host || &usage("Missing --host parameter");
$server = &get_managed_server_by("host", $host);
$server || &usage("System with hostname $host does not exist");
&can_action_usage($server, "disks");
&obtain_lock_server($server);

# Validate media
if ($media) {
	$mfunc = "type_".$server->{'manager'}."_list_disk_medias";
	defined(&$mfunc) || &usage("Disk media cannot be specified for this ".
				   "virtual system type");
	$medias = &$mfunc($server, $disk);
	ref($medias) || &usage("Failed to list media types : $medias");
	($gotmedia) = grep { $_->{'id'} eq $media } @$medias;
	$gotmedia || &usage("Invalid media type - supported types are : ".
			    join(" ", map { $_->{'id'} } @$medias));
	}

# Validate cache type
if ($cache) {
	$cfunc = "type_".$server->{'manager'}."_list_disk_caches";
	defined(&$cfunc) || &usage("Disk caching cannot be specified for this ".
				   "virtual system type");
	$caches = &$cfunc($server);
	($gotcache) = grep { $_->{'id'} eq $cache ||
			     $_->{'alt'} eq $cache } @$caches;
	$gotcache || &usage("Invalid cache type - supported types are : ".
			    join(" ", map { $_->{'id'} } @$caches));
	$cache = $gotcache->{'id'};
	}

# Get the current disks
$dfunc = "type_".$server->{'manager'}."_list_disks";
defined(&$dfunc) || &usage("System type $server->{'manager'} does not support ".
			   "disk management");
$cfunc = "type_".$server->{'manager'}."_can_disks";
defined(&$cfunc) && &$cfunc($server) ||
	&usage("Disks cannot be managed on this system");
$disks = &$dfunc($server, 1);
if (!ref($disks) && $iscsi_connect) {
	# Get the list of disks again, without mount details
	$disks = &$dfunc($server, 0);
	}
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
elsif ($mount) {
	($disk) = grep { $_->{'mount'} eq $mount } @$disks;
	$disk || &usage("No disk for the mount point $mount was found");
	}
else {
	($disk) = grep { $_->{'virt'} eq $virt } @$disks;
	$disk || &usage("No disk mapped to the virtual device $virt was found");
	}

# Change the object
$olddisk = { %$disk };
if ($newsize) {
	$disk->{'fixedsize'} &&
		&usage("The size of this disk cannot be changed");
	$incr = $newsize*1024*1024 - $disk->{'size'};
	$disk->{'size'} = $newsize*1024*1024;
	}
if ($newvirt) {
	$disk->{'virt'} = $newvirt;
	}
if ($media) {
	$disk->{'media'} = $media;
	}
if ($cache) {
	$disk->{'cache'} = $cache;
	}
if ($newreal) {
	$disk->{'change'} ||
		&usage("The disk image cannot be changed for this disk");
	$newreal =~ /^\/\S+$/ ||
		&usage("--new-real must be followed by an absolute path");
	&can_action($server, "devices") ||
		&usage("You are not allowed to select your own devices for disks");
	$disk->{'real'} = $newreal;
	}
if (defined($iscsi_connect)) {
	$disk->{'iscsi_ip'} || &usage("Only iSCSI disks can be connected ".
				      "or disconnected");
	$disk->{'iscsi_connect'} = $iscsi_connect;
	}

# Validate the new size
$limits = &get_owner_limits();
if ($limits && $limits->{'max_disk'} && $incr > 0 &&
    $limits->{'disk'} + $incr > $limits->{'max_disk'}) {
	&usage(&text('disk_elimit',
	       &nice_size($limits->{'max_disk'}),
	       &nice_size($limits->{'disk'})));
	}
$hostfree = &host_free_disk($vhost, $server->{'manager'}, $server, $disk);
if ($hostfree && $incr > $hostfree) {
	&usage("The host system $vhost->{'host'} has only ".
	       &nice_size($hostfree)." disk space free");
	}

# Check for snapshots
if ($disk->{'lv'} &&
    $disk->{'size'} != $olddisk->{'size'} &&
    defined(&check_snapshot_support) &&
    !&check_snapshot_support($server)) {
	my $snaps = &list_snapshots($server);
	if (ref($snaps) && @$snaps > 0) {
		&usage("Disks cannot be resized on a system with ".
		       "active snapshots");
		}
	}

# Check if resize is safe
if ($disk->{'size'} != $olddisk->{'size'} && !$force) {
	$wfunc = "type_".$server->{'manager'}."_can_safely_resize_disk";
	if (defined(&$wfunc)) {
		$err = &$wfunc($server, $disk);
		if ($err) {
			print "This disk cannot be resized : $err\n";
			print "\n";
			print "Use the --force flag to override this warning ",
			      "and resize the disk.\n";
			print "However, data on the disk may be lost!\n";
			exit(2);
			}
		}
	}

# Do it
&$first_print("Modifying virtual disk for $olddisk->{'virt'} ..");
$cfunc = "type_".$server->{'manager'}."_modify_disk";
$err = &$cfunc($server, $disk, $olddisk);
if (defined($include)) {
	&save_disk_include($server, $disk, $include);
	}
&save_managed_server($server);
&release_lock_server($server);
if ($err) {
	&$second_print(".. failed : $err");
	exit(1);
	}
else {
	# Tell the user about reboot
	$rfunc = "type_".$server->{'manager'}."_need_disk_reboot";
	if (defined(&$rfunc) && &$rfunc($server, $disk, $olddisk)) {
		&$second_print(".. done. However, the disk will not be fully updated until the system is rebooted");
		}
	else {
		&$second_print(".. done");
		}
	&cloudmin_api_log(\@OLDARGV);
	}

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Changes the size or virtual device for a disk on some virtual system.\n";
print "\n";
print "cloudmin modify-disk --host hostname\n";
print "                     --real device|file | --virt device | --lv name\n";
print "                    [--new-size MB]\n";
print "                    [--new-virt device]\n";
print "                    [--new-media type]\n";
print "                    [--new-cache mode]\n";
print "                    [--new-real file]\n";
print "                    [--force]\n";
print "                    [--backup-exclude | --backup-include]\n";
print "                    [--iscsi-connect | --iscsi-disconnect]\n";
exit(1);
}

