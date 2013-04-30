#!/usr/local/bin/perl

=head1 list-snapshots.pl

Lists snapshots of a virtual system.

By default, this command outputs a table of snapshots from the system
identified with the C<--host> parameter. However, you can get more detail
with the optional C<--multiline> flag, which includes a list of all logical
volumes in the snapshot and their individual sizes and usage levels.

=head1 Example usage

  cloudmin list-snapshots --host kvmsnap.home
  ID                             Disks      Total size Max usage
  ------------------------------ ---------- ---------- ----------
  snapone                        1          2 MB       1.67%

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
$0 = "$pwd/list-snapshots.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";
if (&foreign_check("mount")) {
	&foreign_require("mount", "mount-lib.pl");
	}

# Parse command line
while(@ARGV > 0) {
	my $a = shift(@ARGV);
	if ($a eq "--host") {
		$host = shift(@ARGV);
		}
	elsif ($a eq "--multiline") {
		$multi = 1;
		}
	else {
		&usage("Unknown parameter $a");
		}
	}

# Get the server
$host || &usage("Missing --host parameter");
$server = &get_managed_server_by("host", $host);
$server || &usage("System with hostname $host does not exist");
&can_action_usage($server, "snapshot");

# Check snapshot support, and get the snapshots
defined(&check_snapshot_support) ||
	&usage("Snapshotting is not supported by this Cloudmin install");
$err = &check_snapshot_support($server);
$err && &usage("Snapshots are not supported for this system : $err");
$snaps = &list_snapshots($server);
ref($snaps) || &usage("Failed to list snapshots : $snaps");

if ($multi) {
	# Show one per block
	foreach $s (@$snaps) {
		print $s->{'id'},"\n";
		print "   Size: ",join(" ", @{$s->{'sizes'}}),"\n";
		print "   Nice size: ",join(" ", map { &nice_size($_) }
						      @{$s->{'sizes'}}),"\n";
		print "   VG: ",join(" ", @{$s->{'vgs'}}),"\n";
		print "   LV: ",join(" ", @{$s->{'lvs'}}),"\n";
		print "   Usage: ",join(" ", map { ($_ eq "" ? 100 : %_)."%" }
						  @{$s->{'usages'}}),"\n";
		print "   Status: ",join(" ", map { $_ ? "Available" : "Full" }
						  @{$s->{'actives'}}),"\n";
		}
	}
else {
	# Show one per line
	$fmt = "%-30.30s %-10.10s %-10.10s %-10.10s %-10.10s\n";
	printf $fmt, "ID", "Disks", "Total size", "Max usage", "Status";
	printf $fmt, ("-" x 30), ("-" x 10), ("-" x 10), ("-" x 10), ("-" x 10);
	foreach $s (@$snaps) {
		my ($totalsize, $maxpc, $anyinactive) = (0, 0, 0);
		for(my $i=0; $i<@{$s->{'sizes'}}; $i++) {
			$totalsize += $s->{'sizes'}->[$i];
			$maxpc = $s->{'usages'}->[$i]
				if ($s->{'usages'}->[$i] > $maxpc);
			$anyinactive = 1 if (!$s->{'actives'}->[$i]);
			}
		printf $fmt, $s->{'id'}, scalar(@{$s->{'sizes'}}),
			     &nice_size($totalsize),
			     $anyinactive ? "100%" : $maxpc."%",
			     $anyinactive ? "Full" : "Available";
		}
	}

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Lists snapshots of a virtual system.\n";
print "\n";
print "cloudmin list-snapshots --host hostname\n";
print "                       [--multiline]\n";
exit(1);
}

