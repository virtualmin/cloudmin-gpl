#!/usr/local/bin/perl

=head1 delete-snapshot.pl

Deletes a single snapshot of a virtual system.

This command deletes a snapshot of the disk images for a virtual system,
which must be specified with the C<--host> flag followed by a full hostname.

The ID of the snapshot must be set with the C<--id> flag. Deletion will have
no impact on the running system, but will make it impossible to roll back to
that snapshot in future.

=head1 Example usage

  cloudmin delete-snapshot --host kvmsnap.home --id snaptest
  Deleting snapshot snaptest for kvmsnap.home ..
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
$snaps = &list_snapshots($server);
ref($snaps) || &usage("Failed to list snapshots : $snaps");
($snapshot) = grep { $_->{'id'} eq $snapid } @$snaps;
$snapshot || &usage("No snapshot named $snapid found");

# Do it
&$first_print("Deleting snapshot $snapid for $server->{'host'} ..");
&obtain_lock_server($server);
$err = &delete_snapshot($server, $snapshot);
&save_managed_server($server);
&release_lock_server($server);
if ($err) {
	&$second_print(".. failed : $err");
	exit(1);
	}
else {
	print " .. done\n";
	}
&cloudmin_api_log(\@OLDARGV);

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Deletes a single snapshot of a virtual system.\n";
print "\n";
print "cloudmin delete-snapshot --host hostname\n";
print "                         --id snapshot-id\n";
exit(1);
}

