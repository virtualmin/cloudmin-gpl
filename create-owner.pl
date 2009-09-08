#!/usr/local/bin/perl

=head1 create-owner.pl

Create a new Cloudmin system owner

A system owner in Cloudmin is an additional Webmin login who can manage some
aspects of selected systems. To create a new owner, run this command with
the C<--name> parameter followed by a login name, C<--email> followed by
a contact address, and C<--pass> followed by a password.

Since you will generally want the new owner account to be able to manage
at least one system, the C<--host> flag should be given followed by a hostname.
This can be given multiple times to allow management of several hosts, which
can be real or virtual systems.

If your Cloudmin system supports plans, you must supply the C<--plan>
parameter followed by a plan ID or name. The list of available plans can
be displayed using the C<list-plans> command.

To specify which actions the owner is allowed to perform on those hosts,
use the following flags :

C<--can-startup> - Startup systems
C<--can-shutdown> - Shut down systems
C<--can-reboot> - Reboot systems
C<--can-console> - View and interact with console
C<--can-graph> - View bandwidth usage graph
C<--can-view> - View system details
C<--can-run> - Run commands on systems
C<--can-domains> - Manage Virtualmin domains
C<--can-update> - Update packages
C<--can-script> - Update installed scripts
C<--can-pause> - Pause virtual systems
C<--can-reset> - Reset to original image

If no action flags are given, those defined in the plan will be allowed instead.

=head1 Example usage

  cloudmin create-owner --name bob --email bob@example.com --pass smeg --host xencentos.home --can-reboot --can-console --can-startup --can-shutdown
  Created Cloudmin system owner bob

=cut

package server_manager;
$main::no_acl_check++;
$ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
$ENV{'WEBMIN_VAR'} ||= "/var/webmin";
if ($0 =~ /^(.*\/)[^\/]+$/) {
	chdir($1);
	}
chop($pwd = `pwd`);
$0 = "$pwd/create-owner.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";
&foreign_require("acl", "acl-lib.pl");
@OLDARGV = @ARGV;

# Parse command line
@allactions = &list_owner_actions();
while(@ARGV > 0) {
	my $a = shift(@ARGV);
	if ($a eq "--name") {
		$name = shift(@ARGV);
		}
	elsif ($a eq "--real") {
		$real = shift(@ARGV);
		}
	elsif ($a eq "--email") {
		$email = shift(@ARGV);
		}
	elsif ($a eq "--pass") {
		$pass = shift(@ARGV);
		}
	elsif ($a eq "--lock") {
		$lock = 1;
		}
	elsif ($a eq "--host") {
		push(@hosts, shift(@ARGV));
		}
	elsif ($a =~ /^--can-(\S+)$/ && &indexof($1, @allactions) >= 0) {
		push(@actions, $1);
		}
	elsif ($a eq "--plan") {
		&supports_plans() || &usage("The --plan flag is not supported");
		$planid = shift(@ARGV);
		($plan) = grep { $_->{'id'} eq $planid ||
				 lc($_->{'desc'}) eq lc($planid) }
			       &list_plans();
		$plan || &usage("No plan with ID or name $planid exists");
		}
	else {
		&usage();
		}
	}

# Validate parameters
$name || &usage("Missing --name parameter");
$email || &usage("Missing --email parameter");
$pass || &usage("Missing --pass parameter");
$pass =~ /:/ && &usage("The password set with --pass cannot contain :");
%allservers = map { $_->{'host'}, $_ } &list_managed_servers();
foreach $n (@hosts) {
	$s = $allservers{$n};
	$s || &usage("No system named $n exists");
	push(@ids, $s->{'id'});
	}
$name =~ /^[a-z0-9\.\-\_]+$/i || &usage("Invalid system owner login");
($clash) = grep { $_->{'name'} eq $name } &acl::list_users();
$clash && &usage("A user named $name already exists");
if (&supports_plans() && !$plan) {
	&usage("Missing --plan parameter");
	}

# Create the user
$owner = { 'name' => $name,
	   'pass' => &acl::encrypt_password($pass),
	   'real' => $real,
	   'acl' => { 'email' => $email,
		      'servers' => join(" ", @ids),
		      'actions' => join(" ", @actions),
		    },
	 };
if ($lock) {
	$owner->{'pass'} = "!".$owner->{'pass'};
	}
if ($plan) {
	$owner->{'acl'}->{'plan'} = $plan->{'id'};
	$owner->{'acl'}->{'actions_def'} = @actions ? 0 : 1;
	}
if ($plan) {
	&apply_plan_to_owner($plan, $owner);
	}
&save_system_owner($owner);
print "Created Cloudmin system owner $name\n";
&cloudmin_api_log(\@OLDARGV);

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Creates a new Cloudmin system owner.\n";
print "\n";
print "cloudmin create-owner --name username\n";
print "                      --email address\@domain\n";
print "                      --pass password\n";
if (&supports_plans()) {
	print "                      --plan name\n";
	}
print "                     [--lock]\n";
print "                     [--real \"Real name\"]\n";
print "                     [--host hostname]*\n";
foreach $a (@allactions) {
	print "                     [--can-$a]\n";
	}
exit(1);
}

