#!/usr/local/bin/perl
# Show a virtual system's SSH or Webmin password

$trust_unknown_referers = 1;
require './server-manager-lib.pl';
&ReadParse();
$server = &get_managed_server($in{'id'});
$server || &error($text{'edit_egone'});
&can_action_error($server, "edit");

&popup_header($text{'showpass_title'});

print "<center>\n";
print &ui_table_start(undef, undef, 2);
if ($in{'mode'} eq 'webmin') {
	print &ui_table_row($text{'showpass_wuser'},
		&html_escape($server->{'user'}));
	print &ui_table_row($text{'showpass_wpass'},
		&html_escape($server->{'pass'}));
	}
elsif ($in{'mode'} eq 'ssh') {
	print &ui_table_row($text{'showpass_suser'},
		&html_escape($server->{'ssh_user'}));
	print &ui_table_row($text{'showpass_spass'},
		&html_escape($server->{'ssh_pass'}));
	}
elsif ($in{'mode'} eq 'vnc') {
	$gfunc = "type_".$server->{'manager'}."_get_graphical_password";
	$pass = &$gfunc($server);
	print &ui_table_row($text{'showpass_vpass'},
		&html_escape($pass));
	}
print &ui_table_end();
print "</center>\n";

&popup_footer();
