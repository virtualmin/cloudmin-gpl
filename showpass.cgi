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
	print &ui_table_row($text{'showpass_wuser'}, $server->{'user'});
	print &ui_table_row($text{'showpass_wpass'}, $server->{'pass'});
	}
else {
	print &ui_table_row($text{'showpass_suser'}, $server->{'ssh_user'});
	print &ui_table_row($text{'showpass_spass'}, $server->{'ssh_pass'});
	}
print &ui_table_end();
print "</center>\n";

&popup_footer();
