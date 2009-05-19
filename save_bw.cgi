#!/usr/local/bin/perl
# Update bandwidth monitoring settings

require './server-manager-lib.pl';
&can_action_error(undef, "global");
&ReadParse();
&error_setup($text{'bw_err'});

# Validate and store inputs
if ($in{'period'}) {
	$config{'bw_period'} = $in{'period'};
	delete($config{'bw_days'});
	}
else {
	$in{'days'} =~ /^[1-9][0-9]*$/ || &error($text{'bw_edays'});
	$config{'bw_days'} = $in{'days'};
	delete($config{'bw_period'});
	}
$config{'bw_disable'} = $in{'disable'};
$in{'msg'} =~ s/\r//g;
$in{'msg'} =~ /\S/ || &error($text{'bw_emsg'});
if ($in{'email_admin'}) {
	$in{'email'} =~ /^\S+\@\S+$/ || &error($text{'bw_eemail'});
	$config{'bw_email'} = $in{'email'};
	}
else {
	delete($config{'bw_email'});
	}
$config{'bw_owner'} = $in{'owner'};
$in{'notify'} =~ /^[1-9]\d*$/ || &error($text{'bw_enotify'});
$config{'bw_notify'} = $in{'notify'};
if ($in{'default_def'}) {
	delete($config{'bw_def'});
	}
else {
	$in{'default'} =~ /^[1-9][0-9]*$/ || &error($text{'bw_edefault'});
	$config{'bw_def'} = $in{'default'}*$in{'default_units'};
	}
$in{'dir_in'} || $in{'dir_out'} || &error($text{'bw_edir'});
$config{'bw_dir_in'} = $in{'dir_in'};
$config{'bw_dir_out'} = $in{'dir_out'};

# Update config and cron job
&obtain_lock_anything();
$config{'bw_enabled'} = $in{'enabled'};
&save_module_config();
&save_bandwidth_message($in{'msg'});
$job = &find_bw_cron_job();
if (!$job && $in{'enabled'}) {
	# Create the job
	$job = { 'command' => $bandwidth_cron_cmd,
		 'user' => 'root',
		 'mins' => '2,7,12,17,22,27,32,37,42,47,52,57',
		 'hours' => '*',
		 'days' => '*',
		 'weekdays' => '*',
		 'months' => '*',
		 'active' => 1, };
	&cron::create_cron_job($job);
	&cron::create_wrapper($bandwidth_cron_cmd, $module_name,"bandwidth.pl");
	}
elsif ($job && !$in{'enabled'}) {
	# Delete the job
	&cron::delete_cron_job($job);
	}

&redirect("");

