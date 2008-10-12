#!/usr/local/bin/perl
# Show a form for importing Xen instances from a host system

require './server-manager-lib.pl';
&ReadParse();
&can_add_server_error($in{'type'});
$server = &get_managed_server_by("id", $in{'id'});
$server || &error($text{'edit_egone'});
$type = $in{'type'};
&ui_print_header(undef, $text{'find_title_'.$type}, "", "find".$type);

print &ui_form_start("find.cgi", "post");
print &ui_hidden("type", $type);
print &ui_table_start($text{'find_header'}, undef, 2);

# Type of system
$tfunc = "type_".$type."_desc";
print &ui_table_row($text{'find_type'}, &$tfunc());

# Base directory for .cfg files
print &ui_table_row($text{'find_dir'},
	&ui_opt_textbox("dir", undef, 40, $text{'find_dirauto'}));

# SSH login details for found instances
print &ui_table_hr();
&show_ssh_login_form($server, $type);

# Webmin login details
print &ui_table_hr();
&show_webmin_login_form($server, $type);

print &ui_table_end();
print &ui_form_end([ [ undef, $text{'find_ok'} ] ]);

&ui_print_footer("", $text{'index_return'});

