#!/usr/local/bin/perl

=head1 list-scalegroups.pl

Display all configured auto-scaling groups.

This command lists all configured auto-scaling groups and their current status
in a simple table. To switch to a more complete and parsable format, use
the C<--multiline> flag, or to get a list of just hostname templates use
C<--name-only>. Alternately, you can use C<--id-only> to get a list of only
group unique IDs.

=head1 Example usage

  cloudmin list-scalegroups
  Hostname template              Source system                     Status
  ------------------------------ --------------------------------- ----------
  scaler${NUM}                   kvmscale.home                     1 systems
  
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
$0 = "$pwd/list-scalegroups.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";
&can_action_usage(undef, "global");

# Parse command line
while(@ARGV > 0) {
	my $a = shift(@ARGV);
	if ($a eq "--multiline") {
		$multi = 1;
		}
	elsif ($a eq "--name-only") {
		$nameonly = 1;
		}
	elsif ($a eq "--id-only") {
		$idonly = 1;
		}
	else {
		&usage();
		}
	}
@scalegroups = &list_scalegroups();

if ($multi) {
	# Full details
	foreach $s (@scalegroups) {
		print $s->{'id'},"\n";
		print "    Hostname template: $s->{'host'}\n";
		print "    Description: $s->{'desc'}\n";
		print "    Minimum systems: $s->{'min'}\n";
		print "    Maximum systems: $s->{'max'}\n";
		print "    Enabled: ",($s->{'enabled'} ? "Yes" : "No"),"\n";
		my $clone = &get_managed_server($s->{'clone'});
		print "    Source system: $clone->{'host'}\n";

		# Host systems
		if ($s->{'dest_location'}) {
			($loc) = grep { $_->{'id'} eq $s->{'dest_location'} }
				      &list_locations();
			print "    Host location group: $loc->{'desc'}\n";
			}
		elsif ($s->{'dest_hosts'}) {
			foreach my $id (
				  split(/\s+/, $s->{'dest_hosts'})) {
				my $vhost = &get_managed_server($id);
				print "    Host system: $vhost->{'host'}\n"
					if ($vhost);
				}
			}

		# Scale-up conditions
		foreach my $c (@{$s->{'conds'}}) {
			print "    Condition: $c->{'name'} ".
			      ($c->{'over'} ? "over" : "under")." ".
			      $c->{'value'}.
			      ($c->{'for'} ? " for ".$c->{'for'} : "").
			      ($c->{'count'} ? " systems ".$c->{'count'} : "").
			      "\n";
			}

		# Notification settings
		print "    Email on increase: ",
			($s->{'notify_inc'} ? "Yes" : "No"),"\n";
		print "    Email on decrease: ",
			($s->{'notify_dec'} ? "Yes" : "No"),"\n";
		print "    Email on overload: ",
			($s->{'notify_over'} ? "Yes" : "No"),"\n";
		print "    Email master admin: ",
		      ($s->{'master'} ? "Yes" : "No"),"\n";
		print "    Also email: $s->{'email'}\n" if ($s->{'email'});
		print "    Email interval: $s->{'interval'}\n";

		# Current status for scaling
		my @ingroup = &get_scalegroup_systems($s);
		my $upst = &evaluate_scalegroup_conditions(
				$s, \@ingroup, "conds");
		my $downst = &evaluate_scalegroup_conditions(
				$s, \@ingroup, "downconds");
		my $status;
		if ($upst->{'firing'} && $upst->{'soon'}) {
			$status = "Scale up pending";
			}
		elsif ($upst->{'firing'}) {
			$status = "Scale up now";
			}
		elsif ($downst->{'firing'} && $downst->{'soon'}) {
			$status = "Scale down pending";
			}
		elsif ($downst->{'firing'}) {
			$status = "Scale down now";
			}
		else {
			$status = "No change needed";
			}
		print "    Scaling recommendation: $status\n";

		# Current systems
		foreach $sg (@ingroup) {
			print "    System in group: $sg->{'host'}\n";
			$desc = &describe_scalegroup_system_status(
				$s, $sg, $upst, $downst);
			$desc = &strip_html_tags($desc);
			print "    System recommendation: $desc\n";
			}
		}
	}
elsif ($nameonly) {
	# Just scalegroup hostnames
	foreach $s (@scalegroups) {
		print $s->{'host'},"\n";
		}
	}
elsif ($idonly) {
	# Just scalegroup IDs
	foreach $s (@scalegroups) {
		print $s->{'id'},"\n";
		}
	}
else {
	# Just summary
	$fmt = "%-30.30s %-33.33s %-10.10s\n";
	printf $fmt, "Hostname template", "Source system", "Status";
	printf $fmt, ("-" x 30), ("-" x 33), ("-" x 10);
	foreach $s (@scalegroups) {
		my $clone = &get_managed_server($s->{'clone'});
		my @ingroup = &get_scalegroup_systems($s);
		printf $fmt, $s->{'host'}, $clone->{'host'},
			     @ingroup ? scalar(@ingroup)." systems" : "Empty";
		}
	}

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Display all configured auto-scaling groups.\n";
print "\n";
print "cloudmin list-scalegroups [--multiline | --name-only]\n";
exit(1);
}

