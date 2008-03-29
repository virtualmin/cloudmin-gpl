#!/usr/local/bin/perl
# Show a form for turning on bandwidth monitoring, and configuring disables

require './server-manager-lib.pl';
&ui_print_header(undef, $text{'bw_title'}, "", "bw");

print &ui_form_start("save_bw.cgi", "post");
print &ui_table_start($text{'bw_header'}, undef, 2);

# Is monitoring enabled?
$job = &find_bw_cron_job();
print &ui_table_row($text{'bw_enabled'},
	&ui_yesno_radio("enabled", $job ? 1 : 0));

# Monitoring period
print &ui_table_row($text{'bw_period'},
	&ui_radio("period", $config{'bw_period'},
		  [ [ "day", $text{'bw_day'} ],
		    [ "week", $text{'bw_week'} ],
		    [ "month", $text{'bw_month'} ],
		    [ "", &text('bw_days',
			    &ui_textbox("days", $config{'bw_days'}, 5)) ] ]));

# What to do with servers that run over?
print &ui_table_row($text{'bw_disable'},
	&ui_radio("disable", int($config{'bw_disable'}),
		  [ [ 0, $text{'bw_disable0'} ],
		    [ 1, $text{'bw_disable1'} ] ]));

# Email message to send when over
print &ui_table_row($text{'bw_msg'},
	&ui_textarea("msg", &get_bandwidth_message(), 5, 60));

# Send to who
print &ui_table_row($text{'bw_email'},
	&ui_checkbox("email_admin", 1, $text{'bw_email_admin'},
		     $config{'bw_email'})." ".
	&ui_textbox("email", $config{'bw_email'}, 40)."<br>\n".
	&ui_checkbox("owner", 1, $text{'bw_owner'},
		     $config{'bw_owner'}));

# Default limit for new servers
print &ui_table_row($text{'bw_def'},
	&ui_radio("default_def", $config{'bw_def'} ? 0 : 1,
		  [ [ 1, $text{'bw_unlimited'} ],
		    [ 0, $text{'bw_defset'} ] ])." ".
	&ui_bytesbox("default", $config{'bw_def'}, 8));

print &ui_table_end();
print &ui_form_end([ [ undef, $text{'save'} ] ]);

# Button for global graph
print "<hr>\n";
print &ui_buttons_start();
print &ui_buttons_row("bwgraph.cgi", $text{'bw_graph'}, $text{'bw_graphdesc'});
print &ui_buttons_end();

&ui_print_footer("", $text{'index_return'});
