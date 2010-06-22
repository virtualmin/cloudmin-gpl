#!/usr/local/bin/perl
# Show a form for changing a server's passwords

require './server-manager-lib.pl';
&ReadParse();
$server = &get_managed_server($in{'id'});
&can_action_error($server, "pass");

&ui_print_header(&server_in($server), $text{'pass_title'}, "", "pass");

print $text{'pass_desc'},"<p>\n";

print &ui_form_start("save_pass.cgi", "post");
print &ui_hidden("id", $in{'id'});
print &ui_table_start($text{'pass_header'}, undef, 2);

@keys = &list_ssh_keys();
if (&can_action(undef, "sshkeys") && @keys) {
	# SSH password or key
	print &ui_table_row($text{'pass_ssh2'},
		&ui_radio_table("ssh_pass_def", 1,
			[ [ 1, $text{'pass_leave'} ],
			  [ 0, $text{'pass_set'},
			    &ui_textbox("ssh_pass", undef, 20) ],
			  [ 2, $text{'pass_sshkey'},
			    &ssh_key_menu("ssh_key", undef, undef) ] ]));
	}
else {
	# SSH password
	print &ui_table_row($text{'pass_ssh'},
		&ui_opt_textbox("ssh_pass", undef, 20, $text{'pass_leave'},
				$text{'pass_set'}));
	}

# Webmin password
if ($server->{'status'} eq 'virt' ||
    $server->{'status'} eq 'novirt' ||
    $server->{'status'} eq 'nowebminlogin') {
	print &ui_table_row(&text('pass_webmin', $server->{'user'}),
		&ui_radio("webmin_pass_def",
			  $server->{'ssh_pass_same'} ? 2 : 1,
			  [ [ 1, $text{'pass_leave'} ],
			    $server->{'user'} eq 'root' ? 
				( [ 2, $text{'pass_same'} ] ) : ( ),
			    [ 0, $text{'pass_set'} ] ])." ".
		&ui_textbox("webmin_pass", undef, 20));
	}

print &ui_table_end();
print &ui_form_end([ [ undef, $text{'pass_ok'} ] ]);

&ui_print_footer("edit_serv.cgi?id=$in{'id'}", $text{'edit_return'});
