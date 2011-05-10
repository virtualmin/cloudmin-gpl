#!/usr/local/bin/perl

=head1 decrease-scalegroup.pl

Removes a system from an auto-scaling group.

This command reduces the number of systems in an existing auto-scaling
group by one, regardless of their current load or other conditons that would
cause scaling to happen automatically. The group can be specified by the
C<--group> flag followed by a unique ID, or C<--host> followed by the hostname
pattern.

=head1 Example usage

  vm2 decrease-scalegroup --host 'scaler${num}'
  Removing a system from auto-scaling group scaler${NUM} ..
  .. deleted system scaler0.home

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
$0 = "$pwd/decrease-scalegroup.pl";
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
	else {
		&usage();
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

# Scale down
&obtain_lock_scalegroup($scalegroup);
&$first_print("Removing a system from auto-scaling group ".
	      "$scalegroup->{'host'} ..");
my ($err, $server) = &delete_scalegroup_system($scalegroup);
if ($err) {
	&$second_print(".. deletion failed : $err");
	}
else {
	&$second_print(".. deleted system $server->{'host'}");
	}
&release_lock_scalegroup($scalegroup);
exit(1) if ($err);
&cloudmin_api_log(\@OLDARGV);

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Removes a system from an auto-scaling group.\n";
print "\n";
print "cloudmin decrease-scalegroup --group id | --host hostname\n";
exit(1);
}

