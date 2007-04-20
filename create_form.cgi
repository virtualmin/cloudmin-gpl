#!/usr/local/bin/perl
# Show a form for creating a new server, on some virtualization system that
# supports it

require './server-manager-lib.pl';
&ReadParse();
&ui_print_header(undef, $text{'create_title'}, "", "create");

print &ui_form_start("create.cgi", "post");
print &ui_hidden("type", $in{'type'});
print &ui_table_start($text{'create_header'}, undef, 2);

# Type of system
$tfunc = "type_".$in{'type'}."_desc";
print &ui_table_row($text{'add_type'}, &$tfunc());

# Hostname
$hfunc = "type_".$in{'type'}."_no_create_hostname";
if (!defined(&$hfunc) || !&$hfunc()) {
	print &ui_table_row($text{'create_host'},
			    &ui_textbox("host", undef, 40);
	}

# Description
print &ui_table_row($text{'add_desc'},
	&ui_textbox("desc", undef, 60));

# Root password / SSH key
$pfunc = "type_".$in{'type'}."_no_create_pass";
if (defined(&$pfunc) && &$pfunc()) {
	# This server type doesn't set a root password at creation (ie. EC2)
	print &ui_table_row($text{'create_sshkey'},
			    &ssh_key_menu("key", $in{'type'}));
	print &ui_hidden("auth_mode", 1);
	}
else {
	print &ui_table_row($text{'add_auth'},
		&ui_radio("auth_mode", 0,
		      [ [ 0, &text('add_auth0',
				   &ui_textbox("upass", undef, 20))."<br>" ],
			[ 1, &text('add_auth1', &ssh_key_menu("key")) ] ]));
	}

# Webmin login
print &ui_table_row($text{'add_webmin'},
	&ui_radio("webmin_mode", 0,
	      [ [ 0, $text{'create_webmin0'}."<br>" ],
		[ 1, $text{'add_webmin1'}."<br>" ],
		[ 2, &text('add_webmin2',
			   &ui_textbox("wuser", "root", 20),
			   &ui_textbox("wpass", undef, 20)) ] ]));

# Can add domains?
print &ui_table_row($text{'add_canvirt'},
	&ui_yesno_radio("canvirt", 1));

# Type-specific options
$ffunc = "type_".$in{'type'}."_create_form";
if (defined(&$ffunc)) {
	print &$ffunc();
	}

print &ui_table_end();
print &ui_form_end([ [ undef, $text{'create_ok'} ] ]);

&ui_print_footer("", $text{'index_return'});

