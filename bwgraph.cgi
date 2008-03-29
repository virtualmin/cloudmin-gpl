#!/usr/local/bin/perl
# Show bandwidth usage for some or all systems with timeplot

require './server-manager-lib.pl';
&ui_print_header(undef, $text{'graph_title'}, "");

# XXX period selector
# XXX option to show total / breakdown by system
# XXX option to show bar chart by system and limit over the month

&ui_print_footer("", $text{'index_return'});
