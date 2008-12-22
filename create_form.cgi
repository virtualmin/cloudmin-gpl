#!/usr/local/bin/perl
# Show a form for creating a new server, on some virtualization system that
# supports it

require './server-manager-lib.pl';
&ReadParse();
&can_create_server_error($in{'type'});
&ui_print_header(undef, $text{'create_title'}, "", "new".$in{'type'});

print &ui_form_start("create.cgi", "post");
print &ui_hidden("type", $in{'type'});
print &ui_hidden_table_start($text{'create_header'}, "width=100%", 2,
			     "main", 1);

# Type of system
$tfunc = "type_".$in{'type'}."_desc";
print &ui_table_row($text{'add_type'}, &$tfunc());

# Hostname
$hfunc = "type_".$in{'type'}."_no_create_hostname";
if (!defined(&$hfunc) || !&$hfunc()) {
	print &ui_table_row($text{'create_host'},
			    &ui_textbox("host", undef, 40));
	}

# Description
print &ui_table_row($text{'add_desc'},
	&ui_textbox("desc", undef, 60));

# System image, if any are available for the server type
@images = &list_server_images($in{'type'});
if (@images) {
	$ifunc = "type_".$in{'type'}."_must_image";
	$mustimage = defined(&$ifunc) && &$ifunc();
	print &ui_table_row($text{'create_image'},
		&ui_select("image", undef,
			[ $mustimage ? ( )
				     : ( [ undef, $text{'create_noimage'} ] ),
			  map { [ $_->{'id'}, $_->{'desc'} ] } @images ]));
	}

# Root password / SSH key (if possible)
$sfunc = "type_".$in{'type'}."_no_ssh";
$no_ssh = defined(&$sfunc) && &$sfunc();
if (!$no_ssh) {
	$pfunc = "type_".$in{'type'}."_no_create_pass";
	if (defined(&$pfunc) && &$pfunc()) {
		# This server type doesn't set a root password at creation
		# (ie. EC2)
		$has_root_password = 0;
		print &ui_table_row($text{'create_sshkey'},
				    &ssh_key_menu("key", $in{'type'}));
		print &ui_hidden("auth_mode", 1);
		}
	else {
		$has_root_password = 1;
		print &ui_table_row($text{'add_auth'},
		    &ui_radio("auth_mode", 0,
		      [ [ 0, &text('add_auth0',
			   &ui_textbox("upass", undef, 20))."<br>" ],
			[ 1, &text('add_auth1', &ssh_key_menu("key")) ] ]));
		}
	}
else {
	$has_root_password = 0;
	}

# Webmin login
print &ui_table_row($text{'create_webmin'},
	&ui_radio("webmin_mode", 0,
	      [ [ 0, $text{'create_webmin0'}."<br>" ],
		$has_root_password ? ( [ 1, $text{'create_webmin1'}."<br>" ] )
				   : ( ),
		[ 2, &text('create_webmin2', "<tt>root</tt>",
			   &ui_textbox("wpass", undef, 20)) ] ]));

# Type-specific options
$ffunc = "type_".$in{'type'}."_create_form";
if (defined(&$ffunc)) {
	print &$ffunc();
	}

print &ui_table_end();

# Type-specific advanced options
$afunc = "type_".$in{'type'}."_advanced_create_form";
if (defined(&$afunc)) {
	print &ui_hidden_table_start($text{'create_aheader'}, "width=100%", 2,
				     "advanced", 0);
	print &$afunc();
	print &ui_hidden_table_end();
	}

# Start of section for Virtualmin options
print &ui_hidden_table_start($text{'create_vheader'}, "width=100%", 2,
			     "virtualmin");

# Virtualmin licence
print &ui_table_row($text{'create_vlicence'},
	&virtualmin_licence_form("licence", 0));

# Can add domains?
print &ui_table_row($text{'add_canvirt'},
	&ui_yesno_radio("canvirt", 1));

# Update Virtualmin package?
print &ui_table_row($text{'create_update'},
	&ui_yesno_radio("update", 1));

print &ui_hidden_table_end();

print &ui_form_end([ [ undef, $text{'create_ok'} ] ]);

&ui_print_footer("", $text{'index_return'});

