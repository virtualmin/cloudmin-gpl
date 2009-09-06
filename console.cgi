#!/usr/local/bin/perl
# Output the console messages from some system

require './server-manager-lib.pl';
&ReadParse();
$server = &get_managed_server($in{'id'});
$server || &error($text{'edit_egone'});
&can_action_error($server, "console");
&ui_print_header(&server_in($server), $text{'console_title'}, "");

$cfunc = "type_".$server->{'manager'}."_get_console_output";
($ok, $out) = &$cfunc($server);
$ok || &error(&text('console_eget', $out));

# Remove CRs and backspaces
$out =~ s/\r//g;
while($out =~ s/[^\010]\010//g) { }

# Wrap to 80 columns
@lines = split(/\n/, $out);
$out = "";
foreach my $l (@lines) {
	while(length($l) > 80) {
		$out .= substr($l, 0, 80)."\n";
		$l = substr($l, 80);
		}
	$out .= $l."\n";
	}

$c = $in{'count'}+1;
print "<div align=right><a href='console.cgi?id=$in{'id'}&count=$c#bottom'>$text{'console_refresh'}</a></div>\n";
print &ui_table_start(undef, "width=100%", 2);
print &ui_table_row(undef, "<pre>".&html_escape($out)."</pre>", 2);
print &ui_table_end();
print "<a name=bottom></a>\n";

&ui_print_footer("edit_serv.cgi?id=$in{'id'}", $text{'edit_return'});

