#!/usr/local/bin/perl
# Show a form for the master admin's email and SMTP settings

require './server-manager-lib.pl';
&can_action_error(undef, "global");
&foreign_require("mailboxes", "mailboxes-lib.pl");
&ui_print_header(undef, $text{'email_title'}, "");

print &ui_form_start("save_email.cgi", "post");
print &ui_table_start($text{'email_header'}, undef, 2);

# Master admin email
print &ui_table_row($text{'email_master'},
	&ui_textbox("master", $config{'bw_email'}, 40));

# SMTP server
$ms = $text{'email_system'.$mailboxes::config{'mail_system'}};
print &ui_table_row($text{'email_smtp'},
	&ui_opt_textbox("smtp", $mailboxes::config{'send_mode'}, 40,
			&text('email_ms', $ms)."<br>", $text{'email_via'}));

# SMTP user and password
print &ui_table_row($text{'email_suser'},
	&ui_radio("suser_def", $mailboxes::config{'smtp_user'} ? 0 : 1,
	  [ [ 1, $text{'email_susernone'}."<br>" ],
	    [ 0, &text('email_suserpass',
		   &ui_textbox("suser", $mailboxes::config{'smtp_user'}, 20),
		   &ui_textbox("spass", $mailboxes::config{'smtp_pass'}, 20)) ],
	  ]));

# Send email as
print &ui_table_row($text{'email_sfrom'},
	&ui_opt_textbox("sfrom", $config{'from_addr'}, 40,
		&text('email_sfromdef', &mailboxes::get_from_address())."<br>",
		$text{'email_sfromaddr'}));

print &ui_table_end();
print &ui_form_end([ [ undef, $text{'save'} ] ]);

&ui_print_footer("", $text{'index_return'});
