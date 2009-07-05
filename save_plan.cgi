#!/usr/local/bin/perl
# Create, update or delete an account plan

require './server-manager-lib.pl';
&error_setup($text{'plan_err'});
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
	}
else {
	# Validate inputs
	$in{'desc'} =~ /\S/ || &error($text{'plan_edesc'});
	if ($in{'new'} || lc($in{'desc'}) ne lc($plan->{'desc'})) {
		($clash) = grep { lc($in{'desc'}) eq lc($_->{'desc'}) } @plans;
		$clash && &error($text{'plan_eclash'});
		}
	$plan->{'desc'} = $in{'desc'};

	# Max allowed servers
	if ($in{'max_servers_def'}) {
		$plan->{'max_servers'} = 0;
		}
	else {
		$in{'max_servers'} =~ /^[1-9][0-9]*$/ ||
			&error($text{'plan_emax_servers'});
		$plan->{'max_servers'} = $in{'max_servers'};
		}

	# Max allowed RAM
	if ($in{'max_ram_def'}) {
		$plan->{'max_ram'} = 0;
		}
	else {
		$in{'max_ram'} =~ /^[1-9][0-9]*$/ ||
			&error($text{'plan_emax_ram'});
		$plan->{'max_ram'} = $in{'max_ram'}*$in{'max_ram_units'};
		}

	# Max allowed disk
	if ($in{'max_disk_def'}) {
		$plan->{'max_disk'} = 0;
		}
	else {
		$in{'max_disk'} =~ /^[1-9][0-9]*$/ ||
			&error($text{'plan_emax_disk'});
		$plan->{'max_disk'} = $in{'max_disk'}*$in{'max_disk_units'};
		}

	# Max allowed CPU limit
	if ($in{'max_cpu_def'}) {
		$plan->{'max_cpu'} = 0;
		}
	else {
		$in{'max_cpu'} =~ /^[1-9][0-9]*$/ ||
			&error($text{'plan_emax_cpu'});
		$plan->{'max_cpu'} = $in{'max_cpu'};
		}

	# Actions
	$in{'actions'} eq '' && &error($text{'owner_eactions'});
	$plan->{'actions'} = join(" ", split(/\0/, $in{'actions'}));

	# VPS types
	$in{'types'} eq '' && &error($text{'plan_etypes'});
	$plan->{'types'} = join(" ", split(/\0/, $in{'types'}));

	# Allowed host systems
	if ($in{'hosts_def'}) {
		delete($plan->{'hosts'});
		}
	else {
		$in{'hosts'} eq '' && &error($text{'plan_ehosts'});
		$plan->{'hosts'} = join(' ', split(/\0/, $in{'hosts'}));
		}

	# Allocation mode
	$plan->{'hostmode'} = $in{'hostmode'};

	# Save and apply
	&save_plan($plan);
	&apply_plan($plan) if (!$in{'new'});
	}

&redirect("list_plans.cgi");

