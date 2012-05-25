#!/usr/local/bin/perl
# Kill the processing locking some system, after asking for confirmation

require './server-manager-lib.pl';
&ReadParse();
&error_setup($text{'kill_err'});
$server = &get_managed_server($in{'id'});
$server || &error($text{'edit_egone'});
&can_action($server, "edit") || &can_action_error($server, "view");

# Get the locker
$lock = &get_lock_on_server($server);
$lock || &error($text{'kill_elock'});
$lock->{'safe'} || &error($text{'kill_esafe'});

if ($in{'confirm'} && $lock->{'safe'} == 2) {
	# Just do it
	kill('TERM', $lock->{'pid'});
	sleep(2);
	kill('KILL', $lock->{'pid'});
	&webmin_log("kill", "server", $server->{'host'});
	&redirect("edit_serv.cgi?id=$in{'id'}");
	}
else {
	# Ask first
	# XXX
	}

