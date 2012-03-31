#!/usr/local/bin/perl

=head1 increase-scalegroup.pl

Add a system to an auto-scaling group.

This command increases the number of systems in an existing auto-scaling
group by one, regardless of their current load or other conditons that would
cause scaling to happen automatically. The group can be specified by the
C<--group> flag followed by a unique ID, or C<--host> followed by the hostname
pattern.

=head1 Example usage

  vm2 increase-scalegroup --host 'scaler${num}'
  Creating a new system in auto-scaling group scaler${NUM} ..
  Allocating new IP addresses ..
  .. allocated 193.9.101.78
  Copying virtual disks ..
    Copying disk /dev/raidvg/kvmcentos_home_img ..
    .. copied to /dev/kvm_vg/scaler0_home_img
  .. done
  Adding DNS entry scaler0.home. for IP address 193.9.101.78 ..
  .. done
  Mounting new instance's filesystem ..
  .. mounted on /mnt/kvm-scaler0.home
  Updating configuration files with hostname and IP address ..
  .. done
  Updating network configuration files ..
  .. done
  Un-mounting instance's filesystem ..
  .. done
  Adding DHCP entries ..
    Adding DHCP entry for 193.9.101.78 with Ethernet address 02:54:00:DA:83:7E ..
    .. done
  .. all done
  Refreshing status of original system ..
  .. done. New status is : Down
  Refreshing status of new system ..
  .. done. New status is : Down
  Starting up new system after cloning ..
  .. done
  Refreshing status of new system ..
  .. done. New status is : SSH
  .. created system scaler0.home

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
$0 = "$pwd/increase-scalegroup.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";
@OLDARGV = @ARGV;

# Parse command line
while(@ARGV > 0) {
	my $a = shift(@ARGV);
	if ($a eq "--group") {
		$groupid = shift(@ARGV);
		}
	elsif ($a eq "--host") {
		$grouphost = shift(@ARGV);
		}
	elsif ($a eq "--multiline") {
		$multiline = 1;
		}
	else {
		&usage("Unknown parameter $a");
		}
	}
&set_all_text_print();

# Find the group
if ($groupid) {
	$scalegroup = &get_scalegroup($groupid);
	$scalegroup || &usage("No auto-scaling group with ID $groupid found");
	}
elsif ($grouphost) {
	($scalegroup) = grep { lc($_->{'host'}) eq lc($grouphost) }
			     &list_scalegroups();
	$scalegroup ||
		&usage("No auto-scaling group for hostname $grouphost found");
	}
else {
	&usage("Missing --group or --host parameter");
	}

# Scale up
&obtain_lock_scalegroup($scalegroup);
&$first_print("Creating a new system in auto-scaling group ".
	      "$scalegroup->{'host'} ..");
my ($err, $newserver) = &create_scalegroup_system($scalegroup);
if ($err) {
	&$second_print(".. creation failed : $err");
	}
else {
	&obtain_lock_server($newserver);
	$newserver->{'scalegroup_reason'} = 'api';
	&save_managed_server($newserver);
	&release_lock_server($newserver);
	&$second_print(".. created system $newserver->{'host'}");
	}
&release_lock_scalegroup($scalegroup);
exit(1) if ($err);
&cloudmin_api_log(\@OLDARGV);

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Add a system to an auto-scaling group.\n";
print "\n";
print "cloudmin increase-scalegroup --group id | --host hostname\n";
exit(1);
}

