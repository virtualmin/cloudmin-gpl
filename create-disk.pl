#!/usr/local/bin/perl

=head1 create-disk.pl

Adds a virtual disk to some system

This command adds a new virtual disk to a system managed by Cloudmin, typically
a Xen instance. Normally, a virtual disk is a file on the host system that
is mapped to a device on the instance, like C</dev/sda3>. However, it can also
be a real disk device on the host system (such as a partiton, or a logical
volume).

The system to add the disk to is specified with the C<--host> parameter. 
The disk file on the host can either be set with C<--real> followed by a
filename like C</xen/newdisk.img>, or you can have Cloudmin choose a filename
automatically with the C<--auto-real> flag.

If your host system supports LVM and has it configured in Cloudmin, you
can instead use the C<--lv> flag followed by the name of a new logical volume
to create.

The device file on the virtual system can either be set with C<--virt>
followed by a device name, or you can use C<--auto-virt> to have Cloudmin choose
an un-used device.

When adding a new file as a disk, the C<--size> parameter must be given and
followed by a disk size in megabytes. If you want it formatted with a
filesystem, use the C<--format> flag followed by a type like C<ext3>. To have
it mounted on the virtual system, use C<--mount> flag followed by a mount
point like C</mnt/disk2>.

For some virtualization types, you can specify if the disk is a hard disk or
CD-ROM with the C<--media> flag. This allows you to attach an existing ISO
image as a CD, which will appear as a actual CD-ROM drive within the virtual
system. On KVM the supported media types are I<disk> and I<cdrom>.

Some virtualization types allow you to specify the caching type for the
disk image with the C<--cache> flag, followed by a mode like C<on> or
C<off> or C<writeback>. This can be used to trade of disk performance for 
host memory usage.

By default disk creation will fail if the specified file or logical volume
already exists on the host system. You can instead force deletion of any
existing file with the C<--overwrite> flag.

If possible, Cloudmin will add the new disk to a running system and mount it
on the specific directory. However, in some cases this may not be possible
without rebooting the system - to have this done automatically, use the
C<--reboot> flag.

=head1 Example usage

  cloudmin create-disk --host xencentos.home --auto-virt --auto-real --size 500
  Creating virtual disk for /dev/sda3 ..
  .. done. However, the disk will not be visible until the system is rebooted

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
$0 = "$pwd/create-disk.pl";
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
	elsif ($a eq "--auto-real") {
		$real = "auto";
		}
	elsif ($a eq "--virt") {
		$virt = shift(@ARGV);
		}
	elsif ($a eq "--auto-virt") {
		$virt = "auto";
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
	elsif ($a eq "--media") {
		$media = shift(@ARGV);
		}
	elsif ($a eq "--cache") {
		$cache = shift(@ARGV);
		}
	elsif ($a eq "--storage") {
		$storage = shift(@ARGV);
		}
	elsif ($a eq "--overwrite") {
		$overwrite = 1;
		}
	elsif ($a eq "--reboot") {
		$reboot = 1;
		}
	elsif ($a eq "--multiline") {
		$multiline = 1;
		}
	else {
		&usage("Unknown parameter $a");
		}
	}

# Validate parameters
$real =~ /^\/\S+$/ || $real eq "auto" || $lv ||
	&usage("Missing or invalid --real or --lv parameter - should be like /xen/foo.img");
$virt =~ /^\/\S+$/ || $virt eq "auto" ||
	&usage("Missing or invalid --virt parameter - should be like /dev/sda2");
$size =~ /^\d*$/ || &usage("Invalid --size parameter - must be followed by a number of MB");
if ($mount) {
	$mount =~ /^\/\S+$/ || $mount eq 'swap' || &usage("Invalid --mount parameter - should be like /mnt/disk2");
	}
if ($lv) {
	$real && &usage("The --lv and --real or --auto-real parameters cannot be used at the same time");
	$lv =~ /^[A-Za-z0-9\.\-\_]+$/ ||
		&usage("Invalid logical volume name from --lv parameter");
	}

# Get the server
$host || &usage("Missing --host parameter");
$server = &find_one_managed_server($host);
$server || &usage("System with hostname $host does not exist");
$vhost = &get_parent_server($server);
&can_action_usage($server, "disks");
&obtain_lock_server($server);

# Get the current disks
$dfunc = "type_".$server->{'manager'}."_list_disks";
defined(&$dfunc) || &usage("System type $server->{'manager'} does not support ".
			   "disk management");
$cfunc = "type_".$server->{'manager'}."_can_disks";
defined(&$cfunc) && &$cfunc($server) ||
	&usage("Disks cannot be managed on this system");
$disks = &$dfunc($server, $mount ? 1 : 0);
ref($disks) || &usage("Failed to list disks : $disks");

# More parameter validation 
if ($format) {
	$ffunc = "type_".$server->{'manager'}."_list_disk_filesystems";
        @fs = &$ffunc($server);
	&indexof($format, @fs) >= 0 ||
		&usage("Specified filesystem is not valid. Types supported are : ".join(" ", @fs));
	}

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

# Validate storage
if ($storage) {
	&can_action_usage($server, "storage");
	$sfunc = "type_".$server->{'manager'}."_list_storages";
	defined(&$sfunc) || &usage("Disk storage location cannot be specified ".
				   "for this virtual system type");
	$storages = &$sfunc($vhost, $server);
	ref($storages) || &usage("Failed to list disk storage ".
				 "locations : $storages");
	($gotstorage) = grep { $_->{'id'} eq $storage ||
			       lc($_->{'desc'}) eq lc($storage) } @$storages;
	$gotstorage || &usage("Invalid storage location - choices are : ".
			    join(" ", map { $_->{'id'} } @$storages));
	}

# Create a new disk object
$nfunc = "type_".$server->{'manager'}."_new_disk";
$disk = &$nfunc($server, $disks, $device, $gotstorage);
$real eq 'auto' || &can_action($server, "devices") ||
	&usage("You are not allowed to select your own devices for disks - ".
	       "the --auto-real flag must be used");
$disk->{'fixedreal'} && $real ne 'auto' &&
	&usage("The device or file cannot be set for disks on this system");
$disk->{'fixedreal'} && $lv &&
	&usage("The LVM volume group cannot be set for disks on this system");
$disk->{'real'} = $real if ($real ne 'auto');
$disk->{'virt'} = $virt if ($virt ne 'auto');
if ($lv) {
	$disk->{'lv'} = $lv;
	$disk->{'real'} = '/dev/'.$disk->{'vg'}.'/'.$disk->{'lv'};
	$device = 1;
	}
if ($media) {
	$disk->{'media'} = $media;
	}
if ($cache) {
	$disk->{'cache'} = $cache;
	}
$disk->{'overwrite'} = $overwrite;

# Check for clashes
($rclash) = grep { $_->{'real'} eq $disk->{'real'} } @$disks;
$rclash && &usage("The real file $disk->{'real'} is already mapped to $rclash->{'virt'}");
($vclash) = grep { $_->{'virt'} eq $disk->{'virt'} } @$disks;
$vclash && &usage("The virtual device $disk->{'virt'} is already mapped from $vclash->{'real'}");
if ($mount && $mount ne 'swap') {
	($mclash) = grep { $_->{'mount'} eq $mount } @$disks;
	$mclash && &usage("The filesystem $mount is already mounted from $mclash->{'virt'}");
	}

# Validate filesystem
if ($fs) {
	$fsfunc = "type_".$server->{'manager'}."_list_disk_filesystems";
	@fslist = &$fsfunc($server);
	&indexof($fs, @fslist) >= 0 ||
		&usage("The filesystem type $fs is not supported - valid ".
		       "types are : ".join(" ", @fslist));
	}

# Create the disk object
$disk->{'size'} = $size*1024*1024;
$disk->{'fs'} = $fs;
$disk->{'mount'} = $mount;

# Validate size increase
$limits = &get_owner_limits();
if ($limits && $limits->{'max_disk'} &&
    $limits->{'disk'} + $disk->{'size'} > $limits->{'max_disk'}) {
	&usage(&text('disk_elimit',
	       &nice_size($limits->{'max_disk'}),
	       &nice_size($limits->{'disk'})));
	}
$hostfree = &host_free_disk($vhost, $server->{'manager'}, $server, $disk);
if ($hostfree && $disk->{'size'} > $hostfree) {
	&usage("The host system $vhost->{'host'} has only ".
	       &nice_size($hostfree)." disk space free");
	}

# Do it
&$first_print("Creating virtual disk for $disk->{'virt'} ..");
$cfunc = "type_".$server->{'manager'}."_create_disk";
$err = &$cfunc($server, $disk, scalar(@$disks) ? 0 : 1);
&save_managed_server($server);
if ($err) {
	&$second_print(".. failed : $err");
	&release_lock_server($server);
	exit(1);
	}
else {
	# Tell the user about reboot
	$rfunc = "type_".$server->{'manager'}."_need_disk_reboot";
	if (defined(&$rfunc) && &$rfunc($server, $disk, undef)) {
		if ($reboot) {
			&$second_print(".. done");
			&$first_print("Rebooting system to add new disk ..");
			$err = &reboot_server($server);
			&check_server_status($server, 0, 1);
			&save_managed_server($server);
			if ($err) {
				print ".. failed : $err\n";
				}
			else {
				print " .. done\n";
				}
			}
		else {
			&$second_print(".. done. However, the disk will not be visible until the system is rebooted");
			}
		}
	else {
		&$second_print(".. done");
		}
	}
&release_lock_server($server);
&cloudmin_api_log(\@OLDARGV);

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Adds a disk device to some virtual system.\n";
print "\n";
print "cloudmin create-disk --host hostname\n";
print "                     --real device|file | --auto-real | --lv name\n";
print "                     --virt device | --auto-virt\n";
print "                    [--size MB]\n";
print "                    [--device]\n";
print "                    [--format filesystem]\n";
print "                    [--mount directory|\"swap\"]\n";
print "                    [--media type]\n";
print "                    [--cache mode]\n";
print "                    [--storage id|\"name\"]\n";
print "                    [--overwrite]\n";
print "                    [--reboot]\n";
exit(1);
}

