#!/usr/local/bin/perl
# Show a form for adding an existing server of some type. At a minimum, we need
# to know the hostname, root password and Webmin login (if it has one)

require './server-manager-lib.pl';
&ReadParse();
&ui_print_header(undef, $text{'add_title'}, "", "add");

print &ui_form_start("add.cgi", "post");
print &ui_table_start($text{'add_header'}, undef, 2);

# Type of system
$tfunc = "type_".$in{'type'}."_desc";
print &ui_table_row($text{'add_type'}, &$tfunc());

# Hostname
print &ui_table_row($text{'add_host'},
	&ui_textbox("host", undef, 40));

# Root password / SSH key
print &ui_table_row($text{'add_auth'},
	&ui_radio("auth_mode", 0,
	      [ [ 0, &text('add_auth0',
			   &ui_textbox("upass", undef, 20))."<br>" ],
		[ 1, &text('add_auth1', &ssh_key_menu("key")) ] ]));

# Webmin login
print &ui_table_row($text{'add_webmin'},
	&ui_radio("webmin_mode", 0,
	      [ [ 0, $text{'add_webmin0'}."<br>" ],
		[ 1, $text{'add_webmin1'}."<br>" ],
		[ 2, &text('add_webmin2',
			   &ui_textbox("wuser", "root", 20),
			   &ui_textbox("wpass", undef, 20)) ] ]));

# Type-specific options
$ffunc = "type_".$in{'type'}."_add_form";
if (defined(&$ffunc)) {
	print &$ffunc();
	}

print &ui_table_end();
print &ui_form_end([ [ undef, $text{'add_ok'} ] ]);

&ui_print_footer("", $text{'index_return'});

