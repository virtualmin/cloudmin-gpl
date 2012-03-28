#!/usr/local/bin/perl

=head1 umount-system.pl

Un-mounts the filesystem on the host for some system

This command reverses the filesystem mount done by C<mount-system>. It takes
only one parameter, C<--host> followed by the hostname of the system whose
filesystem should be un-mounted. Un-mounting is required before a virtual system
can be booted.

=head1 Example usage

  cloudmin umount-system --host xencentos.home
  Un-mounting filesystem for xencentos.home ..
  .. unmounted from /mnt/xen-xencentos.home on host sentosa.home

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
$0 = "$pwd/umount-system.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";
@OLDARGV = @ARGV;

# Parse command line
while(@ARGV > 0) {
	my $a = shift(@ARGV);
	if ($a eq "--host") {
		$host = shift(@ARGV);
		}
	elsif ($a eq "--multiline") {
		$multiline = 1;
		}
	else {
		&usage();
		}
	}

# Get the server and check parameters
$host || &usage("Missing --host parameter");
$server = &get_managed_server_by("host", $host);
$server || &usage("No system with hostname $host exists");
&can_action_usage($server, "mount");

# Make sure mounting is possible
$server->{'status'} eq 'down' || &usage("Only down systems can be mounted");
$ufunc = "type_".$server->{'manager'}."_umount_filesystem";
defined(&$ufunc) || &usage("This virtual system type does not have a ".
			   "mountable filesystem");
$mp = $server->{$server->{'manager'}.'_mount'};
$mp || &usage("This system's filesystem is not currently mounted");

# Un-mount now
&obtain_lock_server($server);
print "Un-mounting filesystem for $server->{'host'} ..\n";
$err = &$ufunc($server);
if ($err) {
	print ".. failed : $err\n";
	}
else {
	$vhost = &get_parent_server($server);
	print ".. unmounted from $mp on host $vhost->{'host'}\n";
	}
&save_managed_server($server);
&release_lock_server($server);
exit(2) if ($err);

&cloudmin_api_log(\@OLDARGV);

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Un-mounts the filesystem on the host for some system.\n";
print "\n";
print "cloudmin umount-system --host name\n";
exit(1);
}

