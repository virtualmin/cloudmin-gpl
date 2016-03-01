#!/usr/local/bin/perl
# Create, update or delete an account plan

require './server-manager-lib.pl';
&error_setup($text{'plan_err'});
&error_if_cloudmin_replica();
&can_action_error(undef, "global");
&ReadParse();
@plans = &list_plans();

if (!$in{'new'}) {	
	# Get the plan
	$plan = &get_plan($in{'id'});
	$plan || &error($text{'plan_egone'});
	}
else {
	$plan = { };
	}

if ($in{'delete'}) {
	# Delete if possible
	&error_setup($text{'plan_err2'});
	@users = grep { $_->{'acl'}->{'plan'} eq $plan->{'id'} }
		      &list_system_owners();
	@users && &error(&text('plan_eusers', scalar(@users)));
	@plans > 1 || &error($text{'plan_elast'});
	&delete_plan($plan);
	&webmin_log("delete", "plan", $plan->{'id'},
		    { 'desc' => $plan->{'desc'} });
	}
elsif ($in{'clone'}) {
	# Redirect to edit form, in clone mode
	&redirect("edit_plan.cgi?new=1&clone=$plan->{'id'}");
	}
else {
	# Validate inputs
	$in{'desc'} =~ /\S/ || &error($text{'plan_edesc'});
	if ($in{'new'} || lc($in{'desc'}) ne lc($plan->{'desc'})) {
		($clash) = grep { lc($in{'desc'}) eq lc($_->{'desc'}) } @plans;
		$clash && &error($text{'plan_eclash'});
		}
	$plan->{'desc'} = $in{'desc'};

	# Save maximums
	foreach $l (@plan_limit_types) {
		if ($in{'max_'.$l.'_def'}) {
			$plan->{'max_'.$l} = 0;
			}
		else {
			$in{'max_'.$l} =~ /^[1-9][0-9]*$/ ||
				&error($text{'plan_emax_'.$l});
			$plan->{'max_'.$l} = $in{'max_'.$l};
			if (defined($in{'max_'.$l.'_units'})) {
				$plan->{'max_'.$l} *= $in{'max_'.$l.'_units'};
				}
			}
		}

	# Actions
	$in{'actions'} eq '' && &error($text{'owner_eactions'});
	$plan->{'actions'} = join(" ", split(/\0/, $in{'actions'}));

	# VPS types
	$in{'types'} eq '' && &error($text{'plan_etypes'});
	$plan->{'types'} = join(" ", split(/\0/, $in{'types'}));

	# IO class
	$plan->{'ioclass'} = $in{'ioclass'};

	# Allowed host systems
	if ($in{'hosts_def'}) {
		delete($plan->{'hosts'});
		}
	else {
		$in{'hosts'} eq '' && &error($text{'plan_ehosts'});
		$plan->{'hosts'} = join(' ', split(/\0/, $in{'hosts'}));
		}

	# Allowed system images
	if (defined($in{'images_def'})) {
		if ($in{'images_def'}) {
			delete($plan->{'images'});
			}
		else {
			$in{'images'} eq '' && &error($text{'plan_eimages'});
			$plan->{'images'} =
				join(' ', split(/\0/, $in{'images'}));
			}
		}

	# Allocation mode
	$plan->{'hostmode'} = $in{'hostmode'};

	# Plugin defined limits
	foreach $p (@plugins) {
		if (&plugin_defined($p, "parse_plan_inputs")) {
			&plugin_call($p, "parse_plan_inputs",
				     $plan, $in{'new'}, \%in);
			}
		}

	# Save and apply
	&save_plan($plan);
	&apply_plan($plan) if (!$in{'new'});
	&webmin_log($in{'new'} ? 'create' : 'modify', "plan", $plan->{'id'},
		    { 'desc' => $plan->{'desc'} });
	}

&redirect("list_plans.cgi");

