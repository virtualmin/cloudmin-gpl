#!/usr/local/bin/perl
# Show a list of auto-scaling groups

$trust_unknown_referers = 1;
require './server-manager-lib.pl';
&ui_print_header(undef, $text{'scalegroups_title'}, "", "scalegroups");
&can_action_error(undef, "global");
@links = ( "<a href='edit_scalegroup.cgi?new=1'>".
	   "$text{'scalegroups_add'}</a>" );

# Find existing alerts and list them
@scalegroups = &list_scalegroups();
if (@scalegroups) {
	print &ui_form_start("delete_scalegroups.cgi", "get");
	unshift(@links, &select_all_link("d"),
			&select_invert_link("d"));
	print &ui_links_row(\@links);
	@tds = ( "width=5" );
	print &ui_columns_start([ "", $text{'scalegroups_host'},
				  $text{'scalegroups_manager'},
				  $text{'scalegroups_cond'},
				  $text{'scalegroups_status'} ], 100, 0, \@tds);
	foreach $s (@scalegroups) {
		print &ui_checked_columns_row([
			"<a href='edit_scalegroup.cgi?id=$s->{'id'}'>".
			  $s->{'host'}."</a>",
			$text{$s->{'manager'}.'_typedesc'},
			&describe_scalegroup_cond($s),
			&describe_scalegroup_status($s),
			], \@tds, "d", $a->{'id'});
		}
	print &ui_columns_end();
	print &ui_links_row(\@links);
	print &ui_form_end([ [ 'delete', $text{'scalegroups_delete'} ],
			     [ 'refresh', $text{'scalegroups_refresh'} ],
			   ]);
	}
else {
	print "<b>$text{'scalegroups_none'}</b><p>\n";
	print &ui_links_row(\@links);
	}

&ui_print_footer("", $text{'index_return'});
