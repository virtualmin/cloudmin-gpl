#!/usr/local/bin/perl
# Configures the automatic download of new Virtualmin licenses

require './server-manager-lib.pl';
&error_setup($text{'lsched_err'});
&ReadParse();

if ($in{'now'}) {
	# Just check now
	# XXX
	}
else {
	# Validate and save inputs
	# XXX update cron job too
	$config{'licences_sched'} = $in{'sched'};
	if ($in{'email_def'}) {
		delete($config{'licences_email'});
		}
	else {
		$in{'email'} =~ /^\S+\@\S+$/ || &error($text{'lsched_eemail'});
		$config{'licences_email'} = $in{'email'};
		}
	&save_module_config();

	&redirect("list_licences.cgi?mode=list");
	}

