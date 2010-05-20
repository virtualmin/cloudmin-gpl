#!/usr/local/bin/perl
# Show a form for cloning an existing system

require './server-manager-lib.pl';
&ReadParse();
$server = &get_managed_server($in{'id'});
$server || &error($text{'edit_egone'});
&can_create_server_error($server->{'manager'});

&ui_print_header(&server_in($server), $text{'clone_title'}, "", "clone");

print $text{'clone_desc'},"<p>\n";

print &ui_form_start("clone.cgi", "post");
print &ui_hidden("id", $in{'id'});
print &ui_table_start($text{'clone_header'}, undef, 2);

# System type
$tfunc = "type_".$server->{'manager'}."_desc";
print &ui_table_row($text{'mkimage_type'},
		    &$tfunc());

# New hostname prefix
print &ui_table_row($text{'clone_host'},
	&ui_textbox("host", undef, 20));

# New description
print &ui_table_row($text{'clone_desc'},
	&ui_textbox("desc", $server->{'desc'} ? "Clone of ".$server->{'desc'}
					      : "", 40));

print &ui_table_end();
print &ui_form_end([ [ undef, $text{'clone_ok'} ] ]);

&ui_print_footer("edit_serv.cgi?id=$in{'id'}", $text{'edit_return'});
