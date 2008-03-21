#!/usr/local/bin/perl
# Lists virtual disks on some system

package server_manager;
$main::no_acl_check++;
$ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
$ENV{'WEBMIN_VAR'} ||= "/var/webmin";
if ($0 =~ /^(.*\/)[^\/]+$/) {
	chdir($1);
	}
chop($pwd = `pwd`);
$0 = "$pwd/list-disks.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";
if (&foreign_check("mount")) {
	&foreign_require("mount", "mount-lib.pl");
	}

# Parse command line
while(@ARGV > 0) {
	local $a = shift(@ARGV);
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

# Get the disks
$dfunc = "type_".$server->{'manager'}."_list_disks";
defined(&$dfunc) || &usage("System type $server->{'manager'} does not support ".
			   "disk management");
$cfunc = "type_".$server->{'manager'}."_can_disks";
defined(&$cfunc) && &$cfunc($server) ||
	&usage("Disks cannot be managed on this system");
$disks = &$dfunc($server, $multi);
ref($disks) || &usage("Failed to list disks : $disks");

if ($multi) {
	# Show one per block
	foreach $d (@$disks) {
		print "$d->{'real'}\n";
		if (defined(&mount::device_name)) {
			$rdesc = &mount::device_name($d->{'real'});
			if ($rdesc && $rdesc ne $d->{'real'}) {
				print "    Description: $rdesc\n";
				}
			}
		print "    Device on system: $d->{'virt'}\n";
		if (defined(&mount::device_name)) {
			$vdesc = &mount::device_name($d->{'virt'});
			if ($vdesc && $vdesc ne $d->{'virt'}) {
				print "    Description on system: $vdesc\n";
				}
			}
		print "    Type: ",($d->{'device'} ? "Device" : "File"),"\n";
		if ($d->{'size'}) {
			print "    Size: $d->{'size'}\n";
			print "    Nice size: ",&nice_size($d->{'size'}),"\n";
			}
		if ($d->{'mount'}) {
			print "    Mount point: $d->{'mount'}\n";
			print "    Filesystem: $d->{'fs'}\n";
			}
		}
	}
else {
	# Show one per line
	$fmt = "%-30.30s %-20.20s %-10.10s %-10.10s\n";
	printf $fmt, "Real file", "Device on system", "Type", "Size";
	printf $fmt, ("-" x 30), ("-" x 20), ("-" x 10), ("-" x 10);
	foreach $d (@$disks) {
		printf $fmt, $d->{'real'}, $d->{'virt'},
			     $d->{'device'} ? "Device" : "File",
			     $d->{'size'} ? &nice_size($d->{'size'}) : "";
		}
	}

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Lists all disks on some virtual system.\n";
print "\n";
print "usage: list-disks.pl --host hostname\n";
print "                    [--multiline]\n";
exit(1);
}

