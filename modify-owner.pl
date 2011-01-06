#!/usr/local/bin/perl

=head1 modify-owner.pl

Updates a Cloudmin system owner

This command changes the details or permissions of a Cloudmin system owner account.
The account to modify is specified by the C<--name> parameter, and a new login,
real name, email address or password can be set with the C<--newname>, 
C<--real>, C<--email> or C<--pass> flags respectively.

To temporarily lock the account, use the C<--lock> flag. To reverse the lock,
use C<--unlock>.

To add a system to the list of those managed by this account, use the
C<--add-host> flag followed by a hostname known to Cloudmin. Or to take away a
system, use C<--remove-host> followed by a hostname.

The C<--can-*> and C<--cannot-*> families of flags can be used to grant or
remove permissions on the hosts this account owns. For a full list, see
the documentation for the C<create-owner> command.

=head1 Example usage

  cloudmin modify-owner --name freeman --add-host xenblah.home --can-run 
  Updated Cloudmin system owner freeman

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
$0 = "$pwd/modify-owner.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";
&foreign_require("acl", "acl-lib.pl");
@OLDARGV = @ARGV;
&usage_if_cloudmin_replica();
&can_action_usage(undef, "global");

# Find possible fields from plugins
@oplugins = grep { &plugin_defined($_, "list_owner_fields") } @plugins;
foreach $p (@oplugins) {
	foreach $f (&plugin_call($p, "list_owner_fields", { }, 1)) {
		$pfields{$f->{'id'}} = $f;
		}
	}

# Parse command line
@allactions = &list_owner_actions();
while(@ARGV > 0) {
	my $a = shift(@ARGV);
	if ($a eq "--name") {
		$name = shift(@ARGV);
		}
	elsif ($a eq "--newname") {
		$newname = shift(@ARGV);
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
	elsif ($a eq "--unlock") {
		$lock = 0;
		}
	elsif ($a eq "--add-host") {
		push(@addhosts, shift(@ARGV));
		}
	elsif ($a eq "--remove-host") {
		push(@remhosts, shift(@ARGV));
		}
	elsif ($a =~ /^--can-(\S+)$/ && &indexof($1, @allactions) >= 0) {
		push(@addactions, $1);
		}
	elsif ($a =~ /^--cannot-(\S+)$/ && &indexof($1, @allactions) >= 0) {
		push(@remactions, $1);
		}
	elsif ($a eq "--plan") {
		&supports_plans() || &usage("The --plan flag is not supported");
		$planid = shift(@ARGV);
		($plan) = grep { $_->{'id'} eq $planid ||
				 lc($_->{'desc'}) eq lc($planid) }
			       &list_plans();
		$plan || &usage("No plan with ID or name $planid exists");
		}
	elsif ($a eq "--plan-actions") {
		&supports_plans() || &usage("The --plan-actions flag is not supported");
		$actions_def = 1;
		}
	elsif ($a eq "--no-plan-actions") {
		&supports_plans() || &usage("The --no-plan-actions flag is not supported");
		$actions_def = 0;
		}
	elsif ($a =~ /^--max-(\S+)$/) {
		$w = $1 eq 'systems' ? 'servers' : $1;
		&indexof($w, @plan_limit_types) >= 0 ||
			&usage("Unknown limit type $w");
		$m = shift(@ARGV);
		$maxes{$w} = $m;
		$m =~ /^\d+$/ ||
			&usage("--max-$w must be followed by an integer");
		}
	elsif ($a =~ /^--unlimited-(\S+)$/) {
		$w = $1 eq 'systems' ? 'servers' : $1;
		&indexof($w, @plan_limit_types) >= 0 ||
			&usage("Unknown limit type $w");
		$maxes{$w} = 0;
		}
	elsif ($a =~ /^--plan-(\S+)$/) {
		$w = $1 eq 'systems' ? 'servers' : $1;
		&indexof($w, @plan_limit_types) >= 0 ||
			&usage("Unknown limit type $w");
		$maxes{$w} = -1;
		}
	elsif ($a =~ /^\-\-(\S+)$/ && $pfields{$1}) {
		push(@pset, { 'id' => $1, 'value' => shift(@ARGV) });
		}
	else {
		&usage("Unknown option $a");
		}
	}

# Validate parameters
$name || &usage("Missing --name parameter");
($owner) = grep { $_->{'name'} eq $name } &list_system_owners();
$owner || &usage("No system owner named $name exists");
if (defined($newname)) {
	$newname =~ /^[a-z0-9\.\-\_\@]+$/i ||
		&usage("Invalid new system owner login");
	($clash) = grep { $_->{'name'} eq $newname } &acl::list_users();
	$clash && &usage("A user named $newname already exists");
	}
$oldowner = { %$owner };

# Update the user
if (defined($newname)) {
	$owner->{'name'} = $newname;
	}
if (defined($real)) {
	$owner->{'real'} = $real;
	}
if (defined($email)) {
	$owner->{'acl'}->{'email'} = $email;
	}
if (defined($pass)) {
	$pass =~ /:/ && &usage("The password set with --pass cannot contain :");
	$oldlock = $owner->{'pass'} =~ /^\!/ ? "!" : "";
	$owner->{'pass'} = $oldlock.&acl::encrypt_password($pass);
	$owner->{'acl'}->{'plainpass'} = $pass;
	}
if (defined($lock)) {
	$owner->{'pass'} =~ s/^\!//;
	$owner->{'pass'} = "!".$owner->{'pass'} if ($lock);
	}

# Update owned systems
%allservers = map { $_->{'host'}, $_ } &list_managed_servers();
@ids = split(/\s+/, $owner->{'acl'}->{'servers'});
foreach $n (@addhosts) {
	$s = $allservers{$n};
	$s || &usage("No system named $n exists");
	push(@ids, $s->{'id'});
	}
foreach $n (@remhosts) {
	$s = $allservers{$n};
	$s || &usage("No system named $n exists");
	@ids = grep { $_ ne $s->{'id'} } @ids;
	}
$owner->{'acl'}->{'servers'} = join(" ", &unique(@ids));

# Update allowed actions, if not coming from the plan
if (defined($actions_def)) {
	$owner->{'acl'}->{'actions_def'} = $actions_def;
	}
if (!$owner->{'acl'}->{'actions_def'}) {
	@actions = split(/\s+/, $owner->{'acl'}->{'actions'});
	push(@actions, @addactions);
	foreach $a (@remactions) {
		@actions = grep { $_ ne $a } @actions;
		}
	$owner->{'acl'}->{'actions'} = join(" ", &unique(@actions));
	}

# Update limits that override plan
foreach $m (keys %maxes) {
	if ($maxes{$m} < 0) {
		delete($owner->{'acl'}->{'custom_'.$m});
		}
	else {
		$owner->{'acl'}->{'max_'.$m} = $maxes{$m};
		$owner->{'acl'}->{'custom_'.$m} = 1;
		}
	}

# Apply plugin fields
foreach $p (@oplugins) {
	$err = &plugin_call($p, "save_owner_fields", $owner, 0, \@pset);
	&usage($err) if ($err);
	}

# Update plan
if ($plan) {
	$owner->{'acl'}->{'plan'} = $plan->{'id'};
	&apply_plan_to_owner($plan, $owner);
	}

# Save the owner
&save_system_owner($owner, $oldowner);
print "Updated Cloudmin system owner $name\n";
&cloudmin_api_log(\@OLDARGV);

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Updates an existing Cloudmin system owner.\n";
print "\n";
print "cloudmin modify-owner --name username\n";
print "                     [--newname username]\n";
print "                     [--email address\@domain]\n";
print "                     [--pass password]\n";
if (&supports_plans()) {
	print "                     [--plan name]\n";
	print "                     [--plan-actions | --no-plan-actions]\n";
	foreach $l (@plan_limit_types) {
		$units = &indexof($l, @nice_plan_limit_types) >= 0 ? "bytes" : "number";
		print "                     [--max-${l} $units | --unlimited-${l} | --plan-${l}]\n";
		}
	}
print "                     [--lock | --unlock]\n";
print "                     [--real \"Real name\"]\n";
print "                     [--add-host hostname]*\n";
print "                     [--remove-host hostname]*\n";
foreach $a (@allactions) {
	print "                     [--can-$a | --cannot-$a]\n";
	}
foreach $p (@oplugins) {
	foreach $f (&plugin_call($p, "list_plan_fields", { }, 1)) {
		print "                     [--$f->{'id'} $f->{'vdesc'}]\n";
		}
	}
exit(1);
}

