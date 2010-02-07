#!/usr/local/bin/perl
# Update bandwidth monitoring settings

require './server-manager-lib.pl';
&can_action_error(undef, "global");
&ReadParse();
&error_setup($text{'bw_err'});
&error_if_cloudmin_replica();

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
if (&supports_plans()) {
	$in{'omsg'} =~ s/\r//g;
	$in{'omsg'} =~ /\S/ || &error($text{'bw_eomsg'});
	}
$config{'bw_owner'} = $in{'owner'};
$config{'bw_emailmaster'} = $in{'email_admin'};
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
&lock_file($module_config_file);
&save_module_config();
&unlock_file($module_config_file);
&save_bandwidth_message($in{'msg'});
if (&supports_plans()) {
	&save_owner_bandwidth_message($in{'omsg'});
	}
&setup_bandwidth_cron();
&webmin_log("bw");

&redirect("");

