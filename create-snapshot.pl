#!/usr/local/bin/perl

=head1 create-snapshot.pl

Creates a snapshot of the disks for a virtual system.

This command creates a snapshot of the disk images for a virtual system,
which can be later reverted to using the revert-snapshot command. The system
must be specified with the C<--host> flag followed by a full hostname.

Each snapshot has a unique ID, set with the C<--id> flag - for example,
something like I<before-upgrade>. You must also supply the C<--percent> flag,
followed by a number between 1 and 100. This determines what percentage of the
host's disk space is used by the snapshot logical volumes. The size is a
tradeoff between disk usage and the number of changes that the snapshot can
store - setting the percent too low can result in a snapshot that eventually
becomes unusable.

=head1 Example usage

  cloudmin create-snapshot --host kvmsnap.home --percent 10 --id snaptest
  Creating snapshot for kvmsnap.home ..
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
$0 = "$pwd/create-snapshot.pl";
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
	elsif ($a eq "--percent") {
		$percent = shift(@ARGV);
		$percent =~ /^\d+$/ && $percent > 0 && $percent <= 100 ||
			&usage("--percent must be followed by a number in the ".
			       "range 1 to 100");
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
$server = &find_one_managed_server($host);
$server || &usage("System with hostname $host does not exist");
&can_action_usage($server, "snapshot");

# Make sure snapshotting works
defined(&check_snapshot_support) ||
	&usage("Snapshotting is not supported by this Cloudmin install");
$err = &check_snapshot_support($server);
$err && &usage("Snapshots are not supported for this system : $err");

# Check for ID clash
$snaps = &list_snapshots($server);
ref($snaps) || &usage("Failed to list snapshots : $snaps");
($clash) = grep { $_->{'id'} eq $snapid } @$snaps;
$clash && &usage("A snapshot with the ID $snapid already exists");

# Validate additional disk size
$limits = &get_owner_limits();
$snapsize = &new_snapshot_size($server, $percent);
if ($limits && $limits->{'max_disk'} &&
    $limits->{'disk'} + $snapsize > $limits->{'max_disk'}) {
	&usage(&text('snapshot_elimit',
	       &nice_size($limits->{'max_disk'}),
	       &nice_size($limits->{'disk'})));
	}

# Do it
&$first_print("Creating snapshot for $server->{'host'} ..");
&obtain_lock_server($server);
$err = &create_snapshot($server, $snapid, $percent);
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
print "Creates a snapshot of the disks for a virtual system.\n";
print "\n";
print "cloudmin create-snapshot --host hostname\n";
print "                         --id snapshot-id\n";
print "                         --percent N\n";
exit(1);
}

