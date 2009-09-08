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
if ($0 =~ /^(.*\/)[^\/]+$/) {
	chdir($1);
	}
chop($pwd = `pwd`);
$0 = "$pwd/move-system.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";
&set_all_text_print();
@OLDARGV = @ARGV;

# Parse command line
while(@ARGV > 0) {
	my $a = shift(@ARGV);
	if ($a eq "--host") {
		$host = shift(@ARGV);
		}
	elsif ($a eq "--dest") {
		$desthost = shift(@ARGV);
		}
	else {
		&usage();
		}
	}

# Check for mandatory args
$host || &usage("Missing --host parameter");
$desthost || &usage("Missing --dest parameter");

# Get the systems
$server = &get_managed_server_by("host", $host);
$dest = &get_managed_server_by("host", $desthost);
$vhost = &get_parent_server($server);
$server->{'id'} eq $dest->{'id'} && &usage("A system cannot be transferred to itself");
$vhost->{'id'} eq $dest->{'id'} && &usage("$dest->{'host'} is already hosting this system");

# Check if supported
$dfunc = "type_".$server->{'manager'}."_desc";
$desc = &$dfunc();
$cfunc = "type_".$server->{'manager'}."_can_move";
defined(&$cfunc) || &usage("Systems of type $desc cannot be moved");
&$cfunc($server, $dest) || &usage("The selected system cannot be moved to the new host");

# Do the transfer
print "Moving $desc system $server->{'host'} from $vhost->{'host'} to $dest->{'host'} ..\n\n";
&obtain_lock_server($dest);
&obtain_lock_server($server);
$err = &move_system($server, $dest);
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
exit(1);
}

