#!/usr/local/bin/perl

=head1 mount-system.pl

Mounts the filesystem on the host for some system.

This command makes the filesystems for some virtual machine available as
a directory on its host system, by mounting its main virtual disk. This will
allow you to login to the host and access the virtual system's files using
regular Unix commands. 

The system whose filesystem should be mounted is set with the C<--host> flag.
It must be currently down, and the filesystem must be un-mounted before it
can be started up again. By default the virtual disk is mounted in a directory
under C</mnt>, but you can change this with the C<--dir> flag.

On a system that uses whole-disk images with multiple partitions, Cloudmin will
by default mount the partition containing the C</etc> directory. However,
you can select a different partition with the C<--want-dir> flag followed by
a path that must exist on the partition, like C</grub>.

=head1 Example usage

  cloudmin mount-system --host xencentos.home
  Mounting filesystem for xencentos.home ..
  .. mounted at /mnt/xen-xencentos.home on host sentosa.home

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
$0 = "$pwd/mount-system.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";
@OLDARGV = @ARGV;

# Parse command line
while(@ARGV > 0) {
	my $a = shift(@ARGV);
	if ($a eq "--host") {
		$host = shift(@ARGV);
		}
	elsif ($a eq "--dir") {
		$mountdir = shift(@ARGV);
		}
	elsif ($a eq "--want-dir") {
		$wantdir = shift(@ARGV);
		}
	elsif ($a eq "--multiline") {
		$multiline = 1;
		}
	else {
		&usage("Unknown parameter $a");
		}
	}

# Get the server and check parameters
$host || &usage("Missing --host parameter");
$server = &find_one_managed_server($host);
$server || &usage("No system with hostname $host exists");
&can_action_usage($server, "mount");

# Make sure mounting is possible
$server->{'status'} eq 'down' || &usage("Only down systems can be mounted");
$nfunc = "type_".$server->{'manager'}."_need_mount";
$mfunc = "type_".$server->{'manager'}."_mount_filesystem";
defined(&$nfunc) || &usage("This virtual system type does not have a ".
			   "mountable filesystem");
&$nfunc($server) ||
	&usage("This virtual system does not need its filesystem mounted");

# Mount now
&obtain_lock_server($server);
print "Mounting filesystem for $server->{'host'} ..\n";
$err = &$mfunc($server, $wantdir, $mountdir);
if ($err) {
	print ".. failed : $err\n";
	}
else {
	$vhost = &get_parent_server($server);
	print ".. mounted at ",$server->{$server->{'manager'}.'_mount'},
	      " on host ",$vhost->{'host'},"\n";
	}
&save_managed_server($server);
&release_lock_server($server);
exit(2) if ($err);

&cloudmin_api_log(\@OLDARGV);

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Mounts the filesystem on the host for some system.\n";
print "\n";
print "cloudmin mount-system --host name\n";
print "                     [--dir mount-point]\n";
print "                     [--want-dir directory]\n";
exit(1);
}

