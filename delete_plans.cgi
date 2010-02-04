#!/usr/local/bin/perl
# Delete several plans

require './server-manager-lib.pl';
&error_setup($text{'dplan_err'});
&error_if_cloudmin_replica();
&can_action_error(undef, "global");
&ReadParse();
@plans = &list_plans();
@owners = &list_system_owners();
@allusers = &list_system_owners();

# Validate list of plans
@d = split(/\0/, $in{'d'});
@d || &error($text{'dplan_enone'});
@d < @plans || &error($text{'dplan_eall'});
foreach $d (@d) {
	$plan = &get_plan($d);
	@users = grep { $_->{'acl'}->{'plan'} eq $plan->{'id'} } @allusers;
	@users && &error(&text('dplan_eusers', $plan->{'desc'},
					       scalar(@users)));
	push(@del, $plan);
	}

# Do the deletes
foreach $plan (@del) {
	&delete_plan($plan);
	}
&webmin_log("delete", "plans", scalar(@del));

&redirect("list_plans.cgi");

