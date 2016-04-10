#!/usr/local/bin/perl
# Show a form for importing VMs from a host system

require './server-manager-lib.pl';
&ReadParse();
$type = $in{'type'};
&can_add_server_error($type);
$server = &get_managed_server_by("id", $in{'id'});
$server || &error($text{'edit_egone'});
&ui_print_header(&server_in($server), $text{'find_title_'.$type},
		 "", "find".$type);

print &ui_form_start("find.cgi", "post");
print &ui_hidden("type", $type);
print &ui_hidden("id", $in{'id'});
print &ui_table_start($text{'find_header'}, undef, 2);

# Type of system
$tfunc = "type_".$type."_desc";
print &ui_table_row($text{'find_type'}, &$tfunc());

# Base directory for .cfg files (if it makes sense)
if (!$in{'nodir'}) {
	print &ui_table_row($text{'find_dir'},
		&ui_opt_textbox("dir", undef, 40, $text{'find_dirauto'}));
	}

# Limit to running instances?
print &ui_table_row($text{'find_running'},
	&ui_yesno_radio("running",
			defined($in{'running'}) ? $in{'running'} : 1));

# Demo mode
#print &ui_table_row($text{'find_show'},
#	&ui_yesno_radio("show", 1));

# SSH login details for found instances
$nsfunc = "type_".$type."_no_ssh";
if (!defined(&$nsfunc) || !&$nsfunc()) {
	print &ui_table_hr();
	&show_ssh_login_form($server, $type);
	}

# Webmin login details
$nwfunc = "type_".$type."_no_webmin";
if (!defined(&$nwfunc) || !&$nwfunc()) {
	print &ui_table_hr();
	&show_webmin_login_form($server, $type);
	}

print &ui_table_end();
print &ui_form_end([ [ undef, $text{'find_ok'} ] ]);

&ui_print_footer("edit_serv.cgi?id=$in{'id'}", $text{'edit_return'});

