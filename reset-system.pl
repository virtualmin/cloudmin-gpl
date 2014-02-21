#!/usr/local/bin/perl
# Resets a virtual system to its original image file

=head1 reset-system.pl

Resets a virtual system to its original image

This command returns a virtual system to the state it was in when originally
created, by re-applying the original image. Alternately, you can select
a different image to apply using the C<--image> flag.

Be aware that ALL data on the system's filesystems will be lost when the reset
is performed, so use it with care!

=head1 Example usage

  cloudmin reset-system --host xengtest.home
  Resetting Xen system xengtest.home from image xen-lenny-base ..
  Copying 147.25 MB image file to host system tanglin.home ..
  .. already in host cache
  Re-creating filesystem from original image ..
  .. creation started.
  Waiting for creation to complete ..
  .. creation has completed successfully.
  Mounting new instance's filesystem ..
  .. mounted on /mnt/xen-xengtest
  Copying modules for kernel 2.6.18-128.2.1.el5.028stab064.4xen to Xen filesystem ..
  .. done
  Setting root password ..
  .. done
  Adding extra authorized SSH keys ..
  .. done
  Updating configuration files with hostname and IP address ..
  .. done
  Updating network configuration files ..
  .. done
  Allowing SSH logins by root ..
  .. already allowed
  Un-mounting instance's filesystem ..
  .. done
  Configuring Xen instance for VNC console access ..
  .. added on display 1
  Starting up new Xen instance ..
  .. done
  Re-fetching system status ..
  .. done. New status is : SSH
  .. all done

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
$0 = "$pwd/reset-system.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";
&set_all_text_print();
@OLDARGV = @ARGV;
&usage_if_cloudmin_replica();

# Parse command line
while(@ARGV > 0) {
	my $a = shift(@ARGV);
	if ($a eq "--host") {
		$host = shift(@ARGV);
		}
	elsif ($a eq "--image") {
		$imageid = shift(@ARGV);
		}
	elsif ($a eq "--multiline") {
		$multiline = 1;
		}
	else {
		&usage("Unknown parameter $a");
		}
	}

# Check for mandatory args, and get the system
$host || &usage("Missing --host parameter");
$server = &find_one_managed_server($host);
$server || &usage("No system named $host exists");
&can_action_usage($server, "reset"); 

# Check if supported
$dfunc = "type_".$server->{'manager'}."_desc";
$desc = &$dfunc();
$cfunc = "type_".$server->{'manager'}."_can_reset";
defined(&$cfunc) || &usage("Systems of type $desc cannot be reset");
&$cfunc($server) || &usage("The selected system cannot be reset");

# Get the image
if ($imageid) {
	# Custom image
	$img = &get_server_image($imageid);
	$img->{'manager'} eq $server->{'manager'} ||
		&usage("The image with ID $imageid is for a different virtual ".
		       "system type");
	&can_image($img) || &usage("You are not allowed to use this image");
	$server->{'image'} = $imageid;
	$server->{'type'} = $img->{'type'};
	}
else {
	# Same as before
	$img = &get_server_image($server->{'image'});
	$img || &usage("Original image with ID $server->{'image'} no longer exists!");
	}

# Do the reset
print "Resetting $desc system $server->{'host'} from image $img->{'id'} ..\n\n";
&obtain_lock_server($server);
$err = &reset_system($server);
&release_lock_server($server);
if ($err) {
	print $err,"\n";
	exit(1);
	}
print ".. all done\n";
&cloudmin_api_log(\@OLDARGV);

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Resets a virtual system to its original image.\n";
print "\n";
print "cloudmin reset-system --host name\n";
print "                     [--image id]\n";
exit(1);
}

