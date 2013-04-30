#!/usr/local/bin/perl

=head1 merge-snapshot.pl

Reverts a virtual system to some snapshot.

This command reverts the disk images for a virtual system to the state when
a snapshot was taken. The system must be specified with the C<--host> flag
followed by a full hostname, and the ID of the snapshot must be set with the
C<--id> flag.

=head1 Example usage

  cloudmin merge-snapshot --host kvmsnap.home --id snaptest
  XXX
  Reverting to snapshot snaptest for kvmsnap.home ..
  .. done

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
$0 = "$pwd/delete-snapshot.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";
@OLDARGV = @ARGV;
&usage_if_cloudmin_replica();

# Parse command line
&set_all_text_print();
$percent = 10;
while(@ARGV > 0) {
	my $a = shift(@ARGV);
	if ($a eq "--host") {
		$host = shift(@ARGV);
		}
	elsif ($a eq "--id") {
		$snapid = shift(@ARGV);
		$snapid =~ /^[a-z0-9\.\-]+$i/ ||
			&usage("The snapshot ID can contain only letters, ".
			       "numbers, dots and dashes");
		}
	else {
		&usage("Unknown parameter $a");
		}
	}

# Get the server
$host || &usage("Missing --host parameter");
$snapid || &usage("Missing --id parameter");
$server = &get_managed_server_by("host", $host);
$server || &usage("System with hostname $host does not exist");
&can_action_usage($server, "snapshot");

# Make sure snapshotting works
defined(&check_snapshot_support) ||
	&usage("Snapshotting is not supported by this Cloudmin install");
$err = &check_snapshot_support($server);
$err && &usage("Snapshots are not supported for this system : $err");

# Get the snapshot
my ($snapshot) = grep { $_->{'id'} eq $snapid } &list_snapshots($server);
$snapshot || &usage("No snapshot named $snapid found");

# Shut down the system if running
&obtain_lock_server($server);
if ($server->{'status'} ne 'down') {
	&$first_print("Shutting down system ..");
	$err = &shutdown_server($server, 1);
	if ($err) {
		&$second_print(".. shutdown failed : $err");
		&release_lock_server($server);
		exit(2);
		}
	else {
		&$second_print(".. done");
		}
	&check_server_status($server, 0, 1);
	&save_managed_server($server);
	$shutdown = 1;
	}

# Do it
&$first_print("Reverting to snapshot $snapid for $server->{'host'} ..");
$err = &merge_snapshot($server, $snapshot);
if ($err) {
	&release_lock_server($server);
	&$second_print(".. failed : $err");
	exit(1);
	}
else {
	print " .. done\n";
	}

# Start back up again
if ($shutdown) {
	&$first_print("Starting up system ..");
	($sok, $serr) = &startup_server($server);
	if (!$sok) {
		&$second_print(".. startup failed : $serr");
		$startupfailed = 1;
		}
	else {
		&$second_print(".. done");
		}
	}

# Re-check status
&$first_print("Refreshing system status ..");
&check_server_status($server);
&save_managed_server($server);
&$second_print(".. done");

&release_lock_server($server);
&cloudmin_api_log(\@OLDARGV);
exit($startupfailed ? 4 : 0);

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Reverts a virtual system to some snapshot.\n";
print "\n";
print "cloudmin merge-snapshot --host hostname\n";
print "                        --id snapshot-id\n";
exit(1);
}

