#!/usr/local/bin/perl
# Show a form for pausing a virtual system, with confirmation

require './server-manager-lib.pl';
&ReadParse();
$server = &get_managed_server($in{'id'});
$server || &error($text{'edit_egone'});
&can_action_error($server, "pause");

# Can we actually pause?
$cfunc = "type_".$server->{'manager'}."_can_pause";
defined(&$cfunc) && &$cfunc($server) == 1 || &error($text{'pause_ecannot'});

&ui_print_header(&server_in($server), $text{'pause_title'}, "", "pause");

print "<center>\n";
print &ui_form_start("pause.cgi");
print &ui_hidden("id", $in{'id'});
print &text('pause_rusure', "<tt>$server->{'host'}</tt>"),"<p>\n";
print &ui_form_end([ [ undef, $text{'pause_ok'} ] ]);
print "</center>\n";

&ui_print_footer("", $text{'index_return'});
