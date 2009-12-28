#!/usr/local/bin/perl
# Show a list of system alert rules

require './server-manager-lib.pl';
&ui_print_header(undef, $text{'alerts_title'}, "", "alerts");
&can_action_error(undef, "global");

# Find existing alerts and list them
@links = ( "<a href='edit_alert.cgi?new=1'>$text{'alerts_add'}</a>" );
@alerts = &list_alerts();
if (@alerts) {
	print &ui_form_start("delete_alerts.cgi", "post");
	unshift(@links, &select_all_link("d"),
			&select_invert_link("d"));
	print &ui_links_row(\@links);
	@tds = ( "width=5" );
	print &ui_columns_start([ "", $text{'alerts_servers'},
				  $text{'alerts_rule'},
				  $text{'alerts_status'} ], 100, 0, \@tds);
	foreach $a (@alerts) {
		print &ui_checked_columns_row([
			"<a href='edit_alert.cgi?id=$a->{'id'}'>".
			  &describe_alert_servers($a)."</a>",
			&describe_alert_rules($a),
			"XXX",
			], \@tds, "d", $a->{'id'});
		}
	print &ui_columns_end();
	print &ui_links_row(\@links);
	print &ui_form_end([ [ 'delete', $text{'alerts_delete'} ],
			     [ 'silence', $text{'alerts_silence'} ],
			     [ 'unsilence', $text{'alerts_unsilence'} ] ]);
	}
else {
	print "<b>$text{'alerts_none'}</b><p>\n";
	print &ui_links_row(\@links);
	}

&ui_print_footer("", $text{'index_return'});
