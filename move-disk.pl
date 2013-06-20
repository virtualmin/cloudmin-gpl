#!/usr/local/bin/perl

=head1 move-disk.pl

Move a virtual disk to a new storage location.

This command moves a single virtual disk from the system chose with the 
C<--host> parameter to a new storage location. The disk to move can be chosen
either with the C<--virt> parameter (followed by a device on the system), 
C<--real> followed by the path on the host, or C<--lv> followed by a logical
volume name.

The destination is set using with C<--new-storage> parameter, followed by
a storage ID as shown by the C<list-disk-storages> command. This is typically
either C<files> or C<lvm_> followed by a volume group name.

Alterately, you can force a move to a specific disk image directory with the
C<--new-directory> flag followed by a path.

=head1 Example usage

  cloudmin move-disk --host xencentos.home --virt /dev/hda --new-storage files
  Moving virtual disk for /dev/hda to files ..
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
$0 = "$pwd/move-disk.pl";
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
	elsif ($a eq "--lv") {
		$lv = shift(@ARGV);
		}
	elsif ($a eq "--virt") {
		$virt = shift(@ARGV);
		}
	elsif ($a eq "--new-storage") {
		$storageid = shift(@ARGV);
		}
	elsif ($a eq "--new-directory") {
		$directory = shift(@ARGV);
		}
	else {
		&usage("Unknown parameter $a");
		}
	}

# Validate parameters
$real || $virt || $lv ||
	&usage("The disk to move must be identified by the ".
	       "--real, --virt or --lv parameters");
$storageid || $directory ||
	&usage("Missing --new-storage or --new-directory parameters");

# Get the server
$host || &usage("Missing --host parameter");
$server = &get_managed_server_by("host", $host);
$server || &usage("System with hostname $host does not exist");
&can_action_usage($server, "disks");
&can_action_usage($server, "storages");
&obtain_lock_server($server);
$server->{'status'} eq 'down' || &usage("Only systems that are down can have ".
					"their disk moved");

if ($storageid) {
	# Get the storage
	$sfunc = "type_".$server->{'manager'}."_list_storages";
	$vhost = &get_parent_server($server);
	$storages = &$sfunc($vhost, $server);
	ref($storages) || &usage("Failed to list storages : $storages");
	($storage) = grep { $_->{'id'} eq $storageid } @$storages;
	if (!$storage && ($storageid eq 'lvm' || $storageid eq 'iscsi')) {
		# Pick first LVM / iSCSI storage
		($storage) = grep { $_->{'id'} =~ /^\Q$storageid\E_/ } @$storages;
		}
	$storage || &usage("No storage with ID $storageid found. Valid IDs ".
			   "are : ".join(" ", map { $_->{'id'} } @$storages));
	}
else {
	# Fake one up
	@directories = &list_directories();
	($dir) = grep { $_->{'dir'} eq $directory } @directories;
	$dir || &usage("Directory $directory is not on the disk ".
		       "image directories list");
	$storage = { 'id' => 'files',
		     'directory' => $directory };
	}

# Get the current disks
$dfunc = "type_".$server->{'manager'}."_list_disks";
defined(&$dfunc) || &usage("System type $server->{'manager'} does not support ".
			   "disk management");
$cfunc = "type_".$server->{'manager'}."_can_disks";
defined(&$cfunc) && &$cfunc($server) ||
	&usage("Disks cannot be managed on this system");
$disks = &$dfunc($server, 0);
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
&can_move_disk_storage($server, $disk) ||
	&error("Disk moves are not supported on this system");
if ($storageid) {
	$disk->{'storage_id'} eq $storage->{'id'} &&
		&usage("This disk is already using storage $storageid");
	}

# Do it
if ($storageid) {
	&$first_print("Moving virtual disk for $disk->{'virt'} to $storage->{'id'} ..");
	}
else {
	&$first_print("Moving virtual disk for $disk->{'virt'} to $directory ..");
	}
$err = &move_disk_storage($server, $disk, $storage);
&save_managed_server($server);
&release_lock_server($server);
if ($err) {
	&$second_print(".. failed : $err");
	exit(1);
	}
else {
	&$second_print(".. done");
	&cloudmin_api_log(\@OLDARGV);
	}

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Move a virtual disk to a new storage location.\n";
print "\n";
print "cloudmin move-disk --host hostname\n";
print "                   --real device|file | --virt device | --lv name\n";
print "                  [--new-storage id]\n"; 
exit(1);
}

