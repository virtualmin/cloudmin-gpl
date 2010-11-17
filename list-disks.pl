#!/usr/local/bin/perl

=head1 list-disks.pl

Lists virtual disks on some system

By default, this command outputs a table of virtual disks on the system 
identified with the C<--host> parameter. However, you can get more detail
with the optional C<--multiline> flag, which will include their mount points
and filesystem types (where available).

=head1 Example usage

  cloudmin list-disks --host xencentos.home
  Real file                      Device on system     Type       Size      
  ------------------------------ -------------------- ---------- ----------
  /xen/xencentos.img             /dev/sda1            File       2 GB      
  /xen/xencentos-disk2.img       /dev/sdb             File       1024 MB   
  /xen/xencentos-disk3.img       /dev/sdc             File       1024 MB   
  /xen/xencentos-disk4.img       /dev/sdd             File       1024 MB   
  /xen/xencentos-disk5.img       /dev/sde             File       1024 MB   
  /xen/xencentos-var.img         /dev/sda3            File       1024 MB   

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
$0 = "$pwd/list-disks.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";
if (&foreign_check("mount")) {
	&foreign_require("mount", "mount-lib.pl");
	}

# Parse command line
while(@ARGV > 0) {
	my $a = shift(@ARGV);
	if ($a eq "--host") {
		$host = shift(@ARGV);
		}
	elsif ($a eq "--multiline") {
		$multi = 1;
		}
	else {
		&usage();
		}
	}

# Get the server
$host || &usage("Missing --host parameter");
$server = &get_managed_server_by("host", $host);
$server || &usage("System with hostname $host does not exist");
&can_action_usage($server, "disks");

# Get the disks
$dfunc = "type_".$server->{'manager'}."_list_disks";
defined(&$dfunc) || &usage("System type $server->{'manager'} does not support ".
			   "disk management");
$cfunc = "type_".$server->{'manager'}."_can_disks";
defined(&$cfunc) && &$cfunc($server) ||
	&usage("Disks cannot be managed on this system");
$disks = &$dfunc($server, $multi ? 2 : 0);
if (!ref($disks) && $multi) {
	# Try again without filesystems
	$disks = &$dfunc($server, 0);
	}
ref($disks) || &usage("Failed to list disks : $disks");

if ($multi) {
	# Show one per block
	foreach $d (@$disks) {
		print $d->{'real'},"\n";
		if ($d->{'realdesc'}) {
			print "    Description: $d->{'realdesc'}\n";
			}
		elsif (defined(&mount::device_name)) {
			$rdesc = &mount::device_name($d->{'real'}, 1);
			if ($rdesc && $rdesc ne $d->{'real'}) {
				print "    Description: $rdesc\n";
				}
			}
		print "    Device on system: $d->{'virt'}\n";
		if (defined(&mount::device_name)) {
			$vdesc = &mount::device_name($d->{'virt'}, 1);
			if ($vdesc && $vdesc ne $d->{'virt'}) {
				print "    Description on system: $vdesc\n";
				}
			}
		print "    Format: ",($d->{'format'} || 'partition'),"\n";
		if ($d->{'virt_onsystem'} &&
		    $d->{'virt_onsystem'} ne $d->{'virt'}) {
			print "    Device file on system: ",
			      "$d->{'virt_onsystem'}\n";
			}
		print "    Type: ",($d->{'device'} ? "Device" : "File"),"\n";
		if ($d->{'lv'}) {
			print "    LVM volume group: $d->{'vg'}\n";
			print "    LVM logical volume: $d->{'lv'}\n";
			}
		if ($d->{'lv_snap_of'}) {
			print "    LVM logical volume snapshot of: ",
			      "$d->{'lv_snap_of'}\n";
			}
		elsif ($d->{'storage'}) {
			print "    Storage name: $d->{'storage'}\n";
			print "    Storage ID: $d->{'real'}\n";
			}
		if ($d->{'media'}) {
			print "    Media: $d->{'media'}\n";
			}
		if ($d->{'size'}) {
			print "    Size: $d->{'size'}\n";
			print "    Nice size: ",&nice_size($d->{'size'}),"\n";
			}
		if ($d->{'df_size'}) {
			print "    Filesystem size: $d->{'df_size'}\n";
			print "    Filesystem used: $d->{'df_used'}\n";
			print "    Filesystem free: $d->{'df_free'}\n";
			print "    Nice filesystem size: ",
				&nice_size($d->{'df_size'}),"\n";
			print "    Nice filesystem used: ",
				&nice_size($d->{'df_used'}),"\n";
			print "    Nice filesystem free: ",
				&nice_size($d->{'df_free'}),"\n";
			}
		if ($d->{'mount'}) {
			print "    Mount point: $d->{'mount'}\n";
			if ($d->{'virt_mount'}) {
				print "    Mount device: ",
				      $d->{'virt_mount'},"\n";
				}
			print "    Filesystem: $d->{'fs'}\n";
			}
		if ($d->{'mount'} || $d->{'mounted'}) {
			print "    Mounted: ",
			      ($d->{'mounted'} ? "Yes" : "No"),"\n";
			}
		if ($d->{'blockid'}) {
			print "    Xen block ID: $d->{'blockid'}\n";
			}
		}
	}
else {
	# Show one per line
	$fmt = "%-30.30s %-20.20s %-10.10s %-10.10s\n";
	printf $fmt, "Real file", "Device on system", "Type", "Size";
	printf $fmt, ("-" x 30), ("-" x 20), ("-" x 10), ("-" x 10);
	foreach $d (@$disks) {
		printf $fmt, $d->{'realdesc'} || $d->{'real'},
		             $d->{'virt'},
			     $d->{'device'} ? "Device" : "File",
			     $d->{'size'} ? &nice_size($d->{'size'}) : "";
		}
	}

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Lists all disks on some virtual system.\n";
print "\n";
print "cloudmin list-disks --host hostname\n";
print "                   [--multiline]\n";
exit(1);
}

