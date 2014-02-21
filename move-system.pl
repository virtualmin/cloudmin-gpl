#!/usr/local/bin/perl
# Moves a virtual system to another host, by imaging it and copying across
# the image file

=head1 move-system.pl

Moves a virtual system from one host to another

This command allows you to transfer a Xen instance or other supported virtual
system from one hosting server to another. It can be useful if the original
host is getting overloaded, and you have brought a new host system online to
take some of the load.

During the move process, the system specified with the C<--host> flag will
generally be temporarily shut down and un-available. All data files will be
copied to the new host (set with the C<--dest> flag), modified as needed,
and then the virtual system restarted.

By default, the move will be done without shutting down the virtual system
if possible. However, you can force a shutdown and restart with the
C<--shutdown> flag. In some cases (such as when the source and destination
host systems use different directories), the virtual system may be shut down
anyway.

If the C<--allocate-ip> flag is given and the destination host system uses
a different IP range to the source host (perhaps because it is on a different
network), Cloudmin will select a new IP address as part of the move process.

If a system has been already moved manually, the C<--manual> flag can be used
to tell Cloudmin to simply update its configurations to reflect the new host.

=head1 Example usage

  cloudmin move-system --host xengtest.home --dest geylang.home
  Moving Xen system xengtest.home from sentosa.home to geylang.home ..
  Shutting down on original host system ..
  .. done
  Copying disk images to new host system ..
      Copying disk /xen/xengtest.img ..
      .. copied image of 1001 MB
      Copying disk /dev/cdrom ..
      .. not a disk image, so cannot be copied
      Copying disk /xen/xengtest.3.img ..
      .. copied image of 200 MB
  .. copied 2 disk images totalling 1.17 GB
  Fixing and copying Xen config file /xen/xengtest.cfg ..
  .. copied to /xen/xengtest.cfg
  Deleting disk and config files from original host ..
  .. done
  Starting up on new host system ..
  .. done
  Re-fetching system status ..
  .. done.
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
$0 = "$pwd/move-system.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";
&set_all_text_print();
@OLDARGV = @ARGV;
&usage_if_cloudmin_replica();

# Parse command line
$shutdown = 0;
$directory = undef;
while(@ARGV > 0) {
	my $a = shift(@ARGV);
	if ($a eq "--host") {
		$host = shift(@ARGV);
		}
	elsif ($a eq "--dest") {
		$desthost = shift(@ARGV);
		}
	elsif ($a eq "--shutdown") {
		$shutdown = 1;
		}
	elsif ($a eq "--allocate-ip") {
		$allocate = 1;
		}
	elsif ($a eq "--manual") {
		$manual = 1;
		}
	elsif ($a eq "--disk-directory") {
		$directory = shift(@ARGV);
		$directory =~ /^\/\S+$/ ||
		    &usage("--disk-directory must be followed by a full path");
		}
	elsif ($a eq "--no-disk-directory") {
		$directory = "";
		}
	elsif ($a eq "--multiline") {
		$multiline = 1;
		}
	else {
		&usage("Unknown parameter $a");
		}
	}

# Check for mandatory args
$host || &usage("Missing --host parameter");
$desthost || &usage("Missing --dest parameter");

# Get the systems
$server = &find_one_managed_server($host);
$server || &usage("No system named $host exists");
$dest = &get_managed_server_by("host", $desthost);
$dest || &usage("No destination system named $desthost exists");
$vhost = &get_parent_server($server);
$server->{'id'} eq $dest->{'id'} && &usage("A system cannot be transferred to itself");
$vhost->{'id'} eq $dest->{'id'} && &usage("$dest->{'host'} is already hosting this system");
&can_action_usage($server, "move");

# Check if supported
$dfunc = "type_".$server->{'manager'}."_desc";
$desc = &$dfunc();
$cfunc = "type_".$server->{'manager'}."_can_move";
defined(&$cfunc) || &usage("Systems of type $desc cannot be moved");
$can = &$cfunc($server, $dest);
$can || &usage("The selected system cannot be moved to the new host");
$can == 3 && !$manual && &usage("Only a manual move is possible");

&run_system_script($server, 'before', 'move') || exit(2);

&obtain_lock_server($dest);
&obtain_lock_server($server);
if ($manual) {
	# Just update configs to reflect manual move
	print "Updating configuration for $desc system $server->{'host'} to reflect move from $vhost->{'host'} to $dest->{'host'} ..\n\n";
	$err = &manual_move_system($server, $dest, $directory);
	}
else {
	# Do the transfer
	print "Moving $desc system $server->{'host'} from $vhost->{'host'} to $dest->{'host'} ..\n\n";
	$err = &move_system($server, $dest, $shutdown, $allocate, $directory);
	}
&run_system_script($server, 'after', 'move');
&release_lock_server($server);
&release_lock_server($dest);
if ($err) {
	print $err,"\n";
	exit(1);
	}
print ".. all done\n";
&cloudmin_api_log(\@OLDARGV);

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Moves a virtual system from one host to another.\n";
print "\n";
print "cloudmin move-system --host name\n";
print "                     --dest new-host-system-name\n";
print "                    [--shutdown]\n";
print "                    [--allocate-ip]\n";
print "                    [--manual]\n";
print "                    [--disk-directory path | --no-disk-directory]\n";
exit(1);
}

