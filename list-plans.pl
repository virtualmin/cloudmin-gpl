#!/usr/local/bin/perl

=head1 list-plans.pl

Lists some or all Cloudmin account plans

By default, this command outputs a table of all Cloudmin plans for applying
to system owners. To switch to a more complete and parsable format, use
the C<--multiline> flag, or to get a list of just plan names use
C<--name-only>. Alternately, you can use C<--id-only> to get a list of only
plan unique IDs.

=head1 Example usage

  cloudmin list-plans
  Plan name                      Max systems     Max RAM    Max disk   Max CPU
  ------------------------------ --------------- ---------- ---------- --------
  Default plan                   5               1024 MB    10 GB      50%
  
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
$0 = "$pwd/list-plans.pl";
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
	elsif ($a eq "--name") {
		$names{lc(shift(@ARGV))} = 1;
		}
	else {
		&usage();
		}
	}
&supports_plans() || &usage("This system does not support plans");

# Find the plans to show
@plans = &list_plans();
if (keys %names) {
	@plans = grep { $names{lc($_->{'desc'})} } @plans;
	}

# Print the the plans
if ($multi) {
	# Full details
	@owners = &list_system_owners();
	@oplugins = grep { &plugin_defined($_, "list_plan_fields") } @plugins;
	foreach $p (@plans) {
		print $p->{'desc'},"\n";
		print "    Plan ID: $p->{'id'}\n";
		foreach $l (@plan_limit_types) {
			$n = &indexof($l, @nice_plan_limit_types) >= 0;
			$m = $p->{'max_'.$l};
			print "    Max ${l}: ",
				!$m ? "Unlimited" :
				$n ? &nice_size($m) : $m,"\n";
			if ($n) {
				print "    Max ${l} in bytes: ",
					!$m ? "Unlimited" : $m,"\n";
				}
			}
		%actions = map { $_, 1 } split(/\s+/, $p->{'actions'});
		print "    Allowed actions: ",
		    join(" ", grep { $actions{$_} } &list_owner_actions()),"\n";
		%types = map { $_, 1 } split(/\s+/, $p->{'types'});
		print "    Allowed system types: ",
		    join(" ", grep { $types{$_} }
				   @virtual_server_management_types),"\n"; 

		print "    System owners on plan: ",
		    join(" ", map { $_->{'name'} }
				grep { $_->{'acl'}->{'plan'} eq $p->{'id'} }
				   @owners),"\n";

		print "    Allowed images: ",
			($p->{'images'} || "All"),"\n";

		$hostlist = join(" ", map { $s = &get_managed_server($_);
					    $s ? ( $s->{'host'} ) : ( ) }
					  split(/\s+/, $p->{'hosts'}));
		print "    Allowed hosts: ",
			($hostlist || "All"),"\n";

		# Limits from plugins
		foreach $pg (@oplugins) {
			foreach $f (&plugin_call($pg, "list_plan_fields",
						 $p, 0)) {
				print "    ".$f->{'desc'}.": ".
					     $f->{'value'}."\n";
				}
			}
		}
	}
elsif ($nameonly) {
	# Just plan names
	foreach $p (@plans) {
		print $p->{'desc'},"\n";
		}
	}
elsif ($idonly) {
	# Just plan IDs
	foreach $p (@plans) {
		print $p->{'id'},"\n";
		}
	}
else {
	# Just summary
	$fmt = "%-30.30s %-15.15s %-10.10s %-10.10s %-10.10s\n";
	printf $fmt, "Plan name", "Max systems", "Max RAM", "Max disk", "Max CPU";
	printf $fmt, ("-" x 30), ("-" x 15), ("-" x 10), ("-" x 10), ("-" x 10);
	foreach $p (@plans) {
		printf $fmt, $p->{'desc'},
			     $p->{'max_servers'} || "Unlimited",
			     $p->{'max_ram'} ? &nice_size($p->{'max_ram'})
					     : "Unlimited",
			     $p->{'max_disk'} ? &nice_size($p->{'max_disk'})
					      : "Unlimited",
			     $p->{'max_cpu'} ? $p->{'max_cpu'}."%"
					     : "Unlimited";
		}
	}

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Lists all plans for system owners\n";
print "\n";
print "cloudmin list-plans [--multiline | --name-only]\n";
exit(1);
}

