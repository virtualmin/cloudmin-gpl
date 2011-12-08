#!/usr/local/bin/perl
# Show all new features from older versions

require './server-manager-lib.pl';
&ui_print_header(undef, $text{'newchangelog_title'}, "");

@servers = &list_available_managed_servers_sorted();
$html = &get_new_features_html($servers[0], 1);
$html = $text{'newchangelog_desc'}."<p>\n".$html;
print &ui_table_start(undef, "width=100%", 2);
print &ui_table_row(undef, $html, 2);
print &ui_table_end();

&ui_print_footer("", $text{'index_return'});

