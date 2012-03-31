#!/usr/local/bin/perl

=head1 check-disk.pl

Verify the filesystem on some virtual disk.

This command validates and repairs the filesystem on a virtual disk, using
the C<fsck> command. The system the disk is on is set with the C<--host> flag,
and the disk to check be specified by real filename using C<--real> or virtual
device with C<--virt>.

This can be useful if a system is failing to boot fully, and getting stuck 
in the "Ping failed" state. Often the cause is a un-clean shutdown that has
left a virtual disk with an invalid filesystem. This API command can correct
those kinds of errors (after the system is shut down).

=head1 Example usage

  cloudmin check-disk --host xencentos.home --virt /dev/sda3
  Checking virtual disk for /dev/hda1 ..
  fsck 1.40.8 (13-Mar-2008)
  e2fsck 1.40.8 (13-Mar-2008)
  /dev/loop9: clean, 11/517144 files, 64966/1040384 blocks
  .. no errors found

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
$0 = "$pwd/check-disk.pl";
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
	elsif ($a eq "--multiline") {
		$multiline = 1;
		}
	else {
		&usage("Unknown parameter $a");
		}
	}

# Validate parameters
$real || $virt || $lv || $mount || &usage("The disk to check must be identified by the --real, --virt, --mount or --lv parameters");

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
ref($disks) || &usage("Failed to list disks : $disks");

# Find the disk to check
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

# Check if we can fsck
$cfunc = "type_".$server->{'manager'}."_can_fsck";
&$cfunc($server, $disk) ||
	&usage("This disk cannot have its filesystem checked");

# Do it
&$first_print("Checking virtual disk for $disk->{'virt'} ..");
$cfunc = "type_".$server->{'manager'}."_fsck_disk";
($ok, $out) = &$cfunc($server, $disk);
&$block_print($out);
&release_lock_server($server);
if ($ok == 0) {
	&$second_print(".. un-fixable filesystem errors found!");
	}
elsif ($ok == 1) {
	&$second_print(".. no errors found");
	}
elsif ($ok == 2) {
	&$second_print(".. filesystem errors found and corrected");
	}
&cloudmin_api_log(\@OLDARGV);

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Verify the filesystem on some virtual disk.\n";
print "\n";
print "cloudmin check-disk --host hostname\n";
print "                    --real device|file | --virt device | --lv name\n";
exit(1);
}

