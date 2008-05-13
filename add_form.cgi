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

# Root password / SSH key
$sfunc = "type_".$in{'type'}."_no_ssh";
$no_ssh = defined(&$sfunc) && &$sfunc();
if (!$no_ssh) {
	print &ui_table_row($text{'add_auth'},
		&ui_radio("auth_mode", 0,
		      [ [ 0, &text('add_auth0',
				   &ui_textbox("upass", undef, 20))."<br>" ],
			[ 1, &text('add_auth1',
				&ssh_key_menu("key", $in{'type'}))] ]));
	print &ui_table_row($text{'add_protocol'},
		&ui_radio("protocol", 2, [ [ 2 ], [ 1 ] ]));
	}

if (!$no_ssh) {
	# Root login
	print &ui_table_row($text{'add_user'},
		&ui_textbox("uuser", "root", 20));

	# SSH port number
	print &ui_table_row($text{'add_sshport'},
		&ui_opt_textbox("uport", undef, 5, $text{'default'}." (22)"));
	}

# Webmin login
print &ui_table_row($text{'add_webmin'},
	&ui_radio("webmin_mode", 0,
	      [ [ 0, $text{'add_webmin0'}."<br>" ],
		$no_ssh ? ( ) : ( [ 1, $text{'add_webmin1'}."<br>" ] ),
		[ 2, &text('add_webmin2',
			   &ui_textbox("wuser", "root", 20),
			   &ui_textbox("wpass", undef, 20)) ] ])."<br>".
	&ui_checkbox("ssl", 1, $text{'add_ssl'}, 1));

# Webmin port
print &ui_table_row($text{'add_port'},
	&ui_textbox("port", 10000, 6));

# Can add domains?
print &ui_table_row($text{'add_canvirt'},
	&ui_yesno_radio("canvirt", 1));

# Type-specific options
$ffunc = "type_".$in{'type'}."_add_form";
if (defined(&$ffunc)) {
	print &$ffunc();
	}

print &ui_table_end();
print &ui_form_end([ [ undef, $text{'add_ok'} ] ]);

&ui_print_footer("", $text{'index_return'});

