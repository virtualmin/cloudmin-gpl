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
$lock && $lock->{'pid'} || &error($text{'kill_elock'});
$lock->{'safe'} || &error($text{'kill_esafe'});

if ($in{'confirm'} && $lock->{'safe'} == 2) {
	# Just do it
	&kill_logged('TERM', $lock->{'pid'});
	sleep(2);
	&kill_logged('KILL', $lock->{'pid'});
	if ($lock->{'safe'} == 1) {
		&check_server_status($server, 0, 1);
		&save_managed_server($server);
		}
	&webmin_log("kill", "server", $server->{'host'});
	&redirect("edit_serv.cgi?id=$in{'id'}&refresh=1");
	}
else {
	# Ask first
	&ui_print_header(&server_in($server), $text{'kill_title'}, "");

	print &ui_confirmation_form(
		"kill.cgi",
		&text('kill_safe', $lock->{'pid'}, "<tt>$lock->{'short'}</tt>"),
		[ [ 'id', $in{'id'} ] ],
		[ [ 'confirm', $text{'kill_ok'} ] ],
		$lock->{'safe'} == 1 ? "<b>$text{'kill_warn'}</b>" : undef,
		);

	&ui_print_footer("", $text{'index_return'});
	}

