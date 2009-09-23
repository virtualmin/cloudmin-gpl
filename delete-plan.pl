#!/usr/local/bin/perl

=head1 delete-plan.pl

Deletes an existing Cloudmin account plan

This command removes a Cloudmin system owner account plan that currently
exists, but is not in use. It takes only one parameter, which is C<--name>
followed by the plan name or ID.

=head1 Example usage

  cloudmin delete-plan --name "Command line plan"
  Deleted Cloudmin account plan Command line plan

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
$0 = "$pwd/delete-plan.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";
@OLDARGV = @ARGV;

# Parse command line
while(@ARGV > 0) {
	my $a = shift(@ARGV);
	if ($a eq "--name") {
		$name = shift(@ARGV);
		}
	else {
		&usage("Unknown flag $a");
		}
	}

# Get the plan
@plans = &list_plans();
$name || &usage("Missing --name parameter");
($plan) = grep { $_->{'desc'} eq $name ||
	         $_->{'id'} eq $name } @plans;
$plan || &usage("No plan named $name exists");
@plans > 1 || &usage("The last plan cannot be deleted");

# Check for users
@users = grep { $_->{'acl'}->{'plan'} eq $plan->{'id'} }
	      &list_system_owners();
@users && &usage("The following system owners are still using this plan : ".
		 join(" ", map { $_->{'name'} } @users));

&delete_plan($plan);
print "Deleted Cloudmin account plan $plan->{'name'}\n";
&cloudmin_api_log(\@OLDARGV);

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Deletes a Cloudmin account plan.\n";
print "\n";
print "cloudmin delete-plan --name plan-name\n";
exit(1);
}

