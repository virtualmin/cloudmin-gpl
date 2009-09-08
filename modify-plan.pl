#!/usr/local/bin/perl

=head1 modify-plan.pl

Updates an existing Cloudmin account plan

This command changes the limits on an existing plan, and thus any system
owners on that plan. The plan is selected with the C<--name> flag, which 
must be followed by a plan name or ID.

The virtual systems limit can be changed with the C<--max-systems> flag,
which must be followed by an integer. Or you can remove the limit with the
C<--unlimited-systems> flag. Similarly, the C<--max-ram>, C<--max-disk>
and C<--max-cpu> flags can be used to limit total allocated RAM, disk space
and CPU load. Both must be followed by a number in bytes.

The C<--max-bw> flag can be used to set the maximum bandwidth the owner's
systems can consume over the bandwidth accounting period. The C<--unlimited-bw>
flag can be used to remove this limit.

To add a new virtual system type to the list of those that system owners
on this plan can created, use the C<--add-type> flag followed by a type
name, like C<xen>. To take away a type, use the C<--remove-type> flag.

To grant owners on this plan access to a system image, use the C<--image>
flag followed by an image ID. Similarly, to deny access to an image use
the C<--remove-image> flag. To given owners access to all images, use the
C<--all-images> flag.

The C<--can-*> and C<--cannot-*> families of flags can be used to grant or
remove permissions on the systems account owners manage. For a full list, see
the documentation for the C<create-plan> command.

To change the name of a plan, use the C<--newname> flag followed by
a name that is not currently in use by any other plan.

=head1 Example usage

  cloudmin modify-plan --name "Command line plan" --max-servers 5 --add-type xen
  Updated Cloudmin account plan Command line plan

=cut

package server_manager;
$main::no_acl_check++;
$ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
$ENV{'WEBMIN_VAR'} ||= "/var/webmin";
if ($0 =~ /^(.*\/)[^\/]+$/) {
	chdir($1);
	}
chop($pwd = `pwd`);
$0 = "$pwd/modify-plan.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";
@OLDARGV = @ARGV;

# Parse command line
@allactions = &list_owner_actions();
if (defined(&list_server_images)) {
	@imageids = map { $_->{'id'} } &list_server_images();
	}
while(@ARGV > 0) {
	my $a = shift(@ARGV);
	if ($a eq "--name") {
		$name = shift(@ARGV);
		}
	elsif ($a eq "--newname") {
		$newname = shift(@ARGV);
		}
	elsif ($a =~ /^--can-(\S+)$/ && &indexof($1, @allactions) >= 0) {
		push(@addactions, $1);
		}
	elsif ($a =~ /^--cannot-(\S+)$/ && &indexof($1, @allactions) >= 0) {
		push(@remactions, $1);
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
	elsif ($a eq "--add-type") {
		$t = shift(@ARGV);
		&indexof($t, @virtual_server_management_types) >= 0 ||
			&usage("$t is not a valid system type");
		push(@addtypes, $t);
		}
	elsif ($a eq "--remove-type") {
		$t = shift(@ARGV);
		push(@remtypes, $t);
		}
	elsif ($a eq "--add-image") {
		$i = shift(@ARGV);
		$i eq 'none' || &indexof($i, @imageids) >= 0 ||
			&usage("$i is not a valid image ID");
		push(@addimages, $i);
		}
	elsif ($a eq "--remove-image") {
		$i = shift(@ARGV);
		push(@remimages, $i);
		}
	elsif ($a eq "--all-images") {
		$allimages = 1;
		}
	elsif ($a eq "--host-mode") {
		$hostmode = shift(@ARGV);
		&indexof($hostmode, @plan_hostmodes) >= 0 ||
			&usage("$hostmode is not a valid host mode");
		}
	elsif ($a eq "--no-host-mode") {
		$hostmode = '';
		}
	else {
		&usage("Unknown flag $a");
		}
	}

# Validate parameters
@plans = &list_plans();
$name || &usage("Missing --name parameter");
($plan) = grep { $_->{'desc'} eq $name ||
	         $_->{'id'} eq $name } @plans;
$plan || &usage("No plan named $name exists");

# Update the plan object
if ($newname) {
	($clash) = grep { lc($_->{'desc'}) eq lc($newname) } &list_plans();
	$clash && &usage("A plan with the same name already exists");
	$plan->{'desc'} = $newname;
	}
@actions = split(/\s+/, $plan->{'actions'});
push(@actions, @addactions);
foreach $a (@remactions) {
	@actions = grep { $_ ne $a } @actions;
	}
$plan->{'actions'} = join(" ", &unique(@actions));
foreach $m (keys %maxes) {
	$plan->{'max_'.$m} = $maxes{$m};
	}

# Apply VPS type changes
@types = split(/\s+/, $plan->{'types'});
push(@types, @addtypes);
foreach $a (@remtypes) {
	@types = grep { $_ ne $a } @types;
	}
$plan->{'types'} = join(" ", &unique(@types));

# Apply image changes
if ($allimages) {
	delete($plan->{'images'});
	}
else {
	@images = split(/\s+/, $plan->{'images'});
	push(@images, @addimages);
	foreach $a (@remimages) {
		@images = grep { $_ ne $a } @images;
		}
	@images || &usage("At least one image must be allowed");
	$plan->{'images'} = join(" ", &unique(@images));
	}

# Apply host system changes
if (defined($hostmode)) {
	$plan->{'hostmode'} = $hostmode;
	}

&save_plan($plan);
&apply_plan($plan);
print "Updated Cloudmin account plan $plan->{'desc'}\n";
&cloudmin_api_log(\@OLDARGV);

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Updates an existing Cloudmin account plan.\n";
print "\n";
print "cloudmin modify-plan --name plan-name\n";
foreach $l (@plan_limit_types) {
	$units = &indexof($l, @nice_plan_limit_types) >= 0 ? "bytes" : "number";
	print "                    [--max-${l} $units | --unlimited-${l}]\n";
	}
print "                    [--add-type ".
      join("|", @virtual_server_management_types)."]*\n";
print "                    [--remove-type ".
      join("|", @virtual_server_management_types)."]*\n";
print "                    [--add-image id]*\n";
print "                    [--remove-image id]*\n";
print "                    [--all-images]\n";
foreach $a (@allactions) {
	print "                    [--can-$a | --cannot-$a]\n";
	}
print "                    [--host-mode ",
	join("|", @plan_hostmodes)," | --no-host-mode]\n";
exit(1);
}

