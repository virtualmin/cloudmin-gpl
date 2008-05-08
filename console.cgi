#!/usr/local/bin/perl
# Output the console messages from some system

require './server-manager-lib.pl';
&ReadParse();
($server) = grep { $_->{'id'} == $in{'id'} } &list_managed_servers();
$server || &error($text{'edit_egone'});
&can_action_error($server, "console");
&ui_print_header(&server_in($server), $text{'console_title'}, "");

$cfunc = "type_".$server->{'manager'}."_get_console_output";
($ok, $out) = &$cfunc($server);
$ok || &error(&text('console_eget', $out));

print &ui_table_start(undef, "width=100%", 2);
print &ui_table_row(undef, "<pre>".&html_escape($out)."</pre>", 2);
print &ui_table_end();

&ui_print_footer("edit_serv.cgi?id=$in{'id'}", $text{'edit_return'});

