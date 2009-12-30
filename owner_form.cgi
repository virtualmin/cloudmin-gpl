#!/usr/local/bin/perl
# Show a form for an owner to change his password and email

require './server-manager-lib.pl';
&error_setup($text{'oform_err'});
$access{'owner'} || &error($text{'oform_ecannot'});
$owner = &get_system_owner($base_remote_user);
$owner || &error($text{'oform_eowner'});

&ui_print_header(undef, $text{'oform_title'}, "");

print &ui_form_start("owner_save.cgi", "post");
print &ui_table_start($text{'oform_header'}, undef, 2);

# Password
print &ui_table_row($text{'oform_pass'},
	&ui_opt_textbox("opass", undef, 20,
			$text{'oform_leave'}, $text{'oform_set'}));

# Contact email
print &ui_table_row($text{'oform_email'},
	&ui_textbox("email", $owner->{'acl'}->{'email'}, 40));

print &ui_table_end();
print &ui_form_end([ [ undef, $text{'save'} ] ]);

&ui_print_footer("", $text{'index_return'});
