#!/usr/local/bin/perl
# Show a list of DNS roundrobins

$trust_unknown_referers = 1;
require './server-manager-lib.pl';
&ui_print_header(undef, $text{'roundrobins_title'}, "", "roundrobins");
&can_action_error(undef, "global");

# Check for DNS zones
@zones = &list_bind_zones();
if (@zones) {
	@links = ( "<a href='edit_roundrobin.cgi?new=1'>".
		   "$text{'roundrobins_add'}</a>" );
	}
else {
	print "<b>$text{'roundrobins_ezones'}</b><p>\n";
	}

# Find existing alerts and list them
@roundrobins = &list_roundrobins();
if (@roundrobins) {
	print &ui_form_start("delete_roundrobins.cgi", "get");
	unshift(@links, &select_all_link("d"),
			&select_invert_link("d"));
	print &ui_links_row(\@links);
	@tds = ( "width=5" );
	$statuses = &get_roundrobin_statuses();
	print &ui_columns_start([ "", $text{'roundrobins_dom'},
				  $text{'roundrobins_servers'},
				  $text{'roundrobins_status'} ], 100, 0, \@tds);
	foreach $a (@roundrobins) {
		$st = $statuses->{$a->{'id'}};
		print &ui_checked_columns_row([
			"<a href='edit_roundrobin.cgi?id=$a->{'id'}'>".
			  $a->{'name'}.".".$a->{'dom'}."</a>",
			&describe_roundrobin_servers($a),
			&describe_roundrobin_status($a, $st),
			], \@tds, "d", $a->{'id'});
		}
	print &ui_columns_end();
	print &ui_links_row(\@links);
	print &ui_form_end([ [ 'delete', $text{'roundrobins_delete'} ],
			     [ 'refresh', $text{'roundrobins_refresh'} ],
			   ]);
	}
else {
	print "<b>$text{'roundrobins_none'}</b><p>\n";
	print &ui_links_row(\@links);
	}

&ui_print_footer("", $text{'index_return'});
