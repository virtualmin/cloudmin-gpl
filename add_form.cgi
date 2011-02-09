#!/usr/local/bin/perl
# Show a form for adding an existing server of some type. At a minimum, we need
# to know the hostname, root password and Webmin login (if it has one)

require './server-manager-lib.pl';
&ReadParse();
&can_add_server_error($in{'type'});
&ui_print_header(undef, $text{'add_title'}, "", "add".$in{'type'});

print &ui_form_start("add.cgi", "post");
print &ui_hidden("type", $in{'type'});
print &ui_table_start($text{'add_header'}, undef, 2);

# Type of system
$tfunc = "type_".$in{'type'}."_desc";
print &ui_table_row($text{'add_type'}, &$tfunc());

# Hostname
print &ui_table_row($text{'add_host'},
	&ui_textbox("host", undef, 40));

# Description
print &ui_table_row($text{'add_desc'},
	&ui_textbox("desc", undef, 60));

# In groups
print &ui_table_row($text{'edit_groups'},
	&show_groups_form($server, \@servers));

# SSH login details
print &ui_table_hr();
&show_ssh_login_form(undef, $in{'type'});

# Webmin login details
print &ui_table_hr();
&show_webmin_login_form(undef, $in{'type'});

# Can add domains?
print &ui_table_row($text{'add_canvirt'},
	&ui_yesno_radio("canvirt", 1));

# Type-specific options
$ffunc = "type_".$in{'type'}."_add_form";
if (defined(&$ffunc)) {
	print &ui_table_hr();
	print &$ffunc();
	}

print &ui_table_end();
print &ui_form_end([ [ undef, $text{'add_ok'} ] ]);

&ui_print_footer("", $text{'index_return'});

