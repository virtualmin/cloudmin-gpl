#!/usr/local/bin/perl
# Show a form for creating or editing a single alert

require './server-manager-lib.pl';
&can_action_error(undef, "global");
&ReadParse();

if ($in{'new'}) {
	# Creating a new one
	&ui_print_header(undef, $text{'alert_ctitle'}, "");
	$alert = { 'all' => 1 };
	}
else {
	# Editing an existing one
	$alert = &get_alert($in{'id'});
	}

print &ui_form_start("save_alert.cgi", "post");

# Section for systems
# XXX

# Section for rules
# XXX

# Section for notification
# XXX

if ($in{'new'}) {
	print &ui_form_end([ [ undef, $text{'create'} ] ]);
	}
else {
	print &ui_form_end([ [ undef, $text{'save'} ],
			     [ 'delete', $text{'delete'} ] ]);
	}

&ui_print_footer("list_alerts.cgi", $text{'alerts_return'});

