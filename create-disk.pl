#!/usr/local/bin/perl
# Adds a virtual disk to some system

package server_manager;
$main::no_acl_check++;
$ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
$ENV{'WEBMIN_VAR'} ||= "/var/webmin";
if ($0 =~ /^(.*\/)[^\/]+$/) {
	chdir($1);
	}
chop($pwd = `pwd`);
$0 = "$pwd/create-disk.pl";
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
	elsif ($a eq "--device") {
		$device = 1;
		}
	elsif ($a eq "--size") {
		$size = shift(@ARGV);
		}
	elsif ($a eq "--format") {
		$fs = shift(@ARGV);
		}
	elsif ($a eq "--mount") {
		$mount = shift(@ARGV);
		}
	else {
		&usage();
		}
	}

# Validate parameters
$real =~ /^\/\S+$/ || &usage("Missing or invalid --real parameter - should be like /xen/foo.img");
$virt =~ /^\/\S+$/ || &usage("Missing or invalid --virt parameter - should be like /dev/sda2");
$size =~ /^\d*$/ || &usage("Invalid --size parameter - must be followed by a number of MB");
if ($mount) {
	$mount =~ /^\/\S+$/ || &usage("Invalid --mount parameter - should be like /mnt/disk2");
	}

# Get the server
$host || &usage("Missing --host parameter");
$server = &get_managed_server_by("host", $host);
$server || &usage("System with hostname $host does not exist");

# Get the current disks
$dfunc = "type_".$server->{'manager'}."_list_disks";
defined(&$dfunc) || &usage("System type $server->{'manager'} does not support ".
			   "disk management");
$cfunc = "type_".$server->{'manager'}."_can_disks";
defined(&$cfunc) && &$cfunc($server) ||
	&usage("Disks cannot be managed on this system");
$disks = &$dfunc($server, 1);
ref($disks) || &usage("Failed to list disks : $disks");

# More parameter validation 
if ($format) {
	$ffunc = "type_".$server->{'manager'}."_list_disk_filesystems";
        @fs = &$ffunc($server);
	&indexof($format, @fs) >= 0 ||
		&usage("Specified filesystem is not valid. Types supported are : ".join(" ", @fs));
	}

# Check for clashes
($rclash) = grep { $_->{'real'} eq $real } @$disks;
$rclash && &usage("The real file $real is already mapped to $rclash->{'virt'}");
($vclash) = grep { $_->{'virt'} eq $virt } @$disks;
$vclash && &usage("The virtual device $virt is already mapped from $vclash->{'real'}");
if ($mount) {
	($mclash) = grep { $_->{'mount'} eq $mount } @$disks;
	$mclash && &usage("The filesystem $mount is already mounted from $mclash->{'virt'}");
	}

# Do it
$disk = { 'real' => $real,
	  'virt' => $virt,
	  'size' => $size*1024*1024,
	  'device' => $device,
	  'fs' => $fs,
	  'mount' => $mount };
&$first_print("Creating virtual disk for $disk->{'virt'} ..");
$cfunc = "type_".$server->{'manager'}."_create_disk";
$err = &$cfunc($server, $disk);
if ($err) {
	&$second_print(".. failed : $err");
	}
else {
	# Tell the user about reboot
	$rfunc = "type_".$server->{'manager'}."_need_disk_reboot";
	if (defined(&$rfunc) && &$rfunc($server, $disk)) {
		&$second_print(".. done. However, the disk will not be visible until the system is rebooted");
		}
	else {
		&$second_print(".. done");
		}
	}

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Adds a disk device to some virtual system.\n";
print "\n";
print "usage: create-disk.pl --host hostname\n";
print "                      --real device|file\n";
print "                      --virt device\n";
print "                     [--size MB]\n";
print "                     [--device]\n";
print "                     [--format filesystem]\n";
print "                     [--mount directory]\n";
exit(1);
}

