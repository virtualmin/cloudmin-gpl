#!/usr/local/bin/perl

=head1 create-plan.pl

Creates a new Cloudmin account plan

A plan defines limits on the number of system and amounts of RAM and disk a
Cloudmin system owner can use, VPS types he can create, and actions he can
perform. This command allows you to create a new plan, whose name is specified
with the C<--name> flag.

The virtual systems limit is set with the C<--max-systems> flag, which must be
followed by an integer. If this is not given, no limit on the number of systems
will be enforced. Similarly, the C<--max-ram> and C<--max-disk> flags can be
used to limit total allocated RAM and disk space. Both must be followed by
a number in bytes.

The C<--max-bw> flag can be used to set the maximum bandwidth the owner's
systems can consume over the bandwidth accounting period. If this is exceeded,
email will be sent to the master administrator and the system owner.

If your Cloudmin install manages more than one type of virtual system 
(such as Xen instances and Solaris Zones), the C<--type> flag can be given,
followed by a system type. If missing, all VPS types will be allowed.

By default, owners on this plan will be able to create virtual systems
using any image. To restrict them to a subset of images, add the C<--image>
flag followed by an image ID, like C<xen-centos5.3-base>. This can be given
multiple times to allow more than one image.

To specify which actions owners on this plan are allowed to perform, use
the following flags :

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

If none are given, all actions will be allowed.

=head1 Example usage

  cloudmin create-plan --name "Command line plan" --max-servers 2 --max-ram 1000000000 --max-disk 5000000000 --type xen
  Created Cloudmin account plan Command line plan

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
$0 = "$pwd/create-plan.pl";
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
	elsif ($a =~ /^--can-(\S+)$/ && &indexof($1, @allactions) >= 0) {
		push(@actions, $1);
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
	elsif ($a eq "--type") {
		$t = shift(@ARGV);
		&indexof($t, @virtual_server_management_types) >= 0 ||
			&usage("$t is not a valid system type");
		push(@types, $t);
		}
	elsif ($a eq "--image") {
		$i = shift(@ARGV);
		$i eq 'none' || &indexof($i, @imageids) >= 0 ||
			&usage("$i is not a valid image ID");
		push(@images, $i);
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
$name || &usage("Missing --name parameter");
($clash) = grep { lc($_->{'desc'}) eq lc($name) } &list_plans();
$clash && &usage("A plan with the same name already exists");
@types = @virtual_server_management_types if (!@types);
@actions = &list_safe_owner_actions() if (!@actions);
@images = @imageids if (!@images);

# Create the plan object
$plan = { 'desc' => $name,
	  'actions' => join(' ', @actions),
	  'types' => join(' ', @types),
	  'images' => join(' ', @images),
	  'hostmode' => $hostmode,
	};
foreach $m (keys %maxes) {
	$plan->{'max_'.$m} = $maxes{$m};
	}

&save_plan($plan);
print "Created Cloudmin account plan $name\n";
&cloudmin_api_log(\@OLDARGV);

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Creates a new Cloudmin account plan.\n";
print "\n";
print "cloudmin create-plan --name plan-name\n";
foreach $l (@plan_limit_types) {
	$units = &indexof($l, @nice_plan_limit_types) >= 0 ? "bytes" : "number";
	print "                    [--max-${l} $units]\n";
	}
print "                    [--type ".
      join("|", @virtual_server_management_types)."]*\n";
print "                    [--image id]*\n";
foreach $a (@allactions) {
	print "                    [--can-$a]\n";
	}
print "                    [--host-mode ",
	join("|", @plan_hostmodes)," | --no-host-mode]\n";
exit(1);
}

