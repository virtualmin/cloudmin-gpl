#!/usr/local/bin/perl

=head1 move-disk.pl

Move a virtual disk to a new storage location.

XXX

=head1 Example usage

  cloudmin move-disk --host xencentos.home --new-storage /mnt/disk2
  XXX

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
	elsif ($a eq "--mount") {
		$mount = shift(@ARGV);
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
	else {
		&usage("Unknown parameter $a");
		}
	}

# Validate parameters
$real || $virt || $lv || $mount ||
	&usage("The disk to move must be identified by the ".
	       "--real, --virt, --mount or --lv parameters");
$storageid || &usage("Missing --new-storage parameter");

# Get the server
$host || &usage("Missing --host parameter");
$server = &get_managed_server_by("host", $host);
$server || &usage("System with hostname $host does not exist");
&can_action_usage($server, "disks");
&obtain_lock_server($server);
$server->{'status'} eq 'down' || &usage("Only systems that are down can have ".
					"their disk moved");

# Get the storage
$sfunc = "type_".$server->{'manager'}."_list_storages";
$vhost = &get_parent_server($server);
$storages = &$sfunc($vhost, $server);
ref($storages) || &usage("Failed to list storages : $storages");
($storage) = grep { $_->{'id'} eq $storageid } @$storages;
$storage || &usage("No storage with ID $storageid found. Valid IDs are : ".
		   join(" ", map { $_->{'id'} } @$storages));
$disk->{'storage_id'} eq $storage->{'id'} &&
	&usage("This disk is already using storage $storageid");

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
elsif ($mount) {
	($disk) = grep { $_->{'mount'} eq $mount } @$disks;
	$disk || &usage("No disk for the mount point $mount was found");
	}
else {
	($disk) = grep { $_->{'virt'} eq $virt } @$disks;
	$disk || &usage("No disk mapped to the virtual device $virt was found");
	}
&can_move_disk_storage($server, $disk) ||
	&error("Disk moves are not supported on this system");

# Do it
&$first_print("Moving virtual disk for $disk->{'virt'} to $storage->{'id'} ..");
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

