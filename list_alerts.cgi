#!/usr/local/bin/perl
# Show a list of system alert rules

require './server-manager-lib.pl';
&ui_print_header(undef, $text{'alerts_title'}, "", "alerts");
&can_action_error(undef, "global");

# Find existing alerts and list them
@links = ( "<a href='edit_alert.cgi?new=1'>$text{'alerts_add'}</a>" );
@alerts = &list_alerts();
if (@alerts) {
	print &ui_form_start("delete_alerts.cgi", "get");
	unshift(@links, &select_all_link("d"),
			&select_invert_link("d"));
	print &ui_links_row(\@links);
	@tds = ( "width=5" );
	$statuses = &get_alert_statuses();
	print &ui_columns_start([ "", $text{'alerts_servers'},
				  $text{'alerts_rule'},
				  $text{'alerts_status'} ], 100, 0, \@tds);
	foreach $a (@alerts) {
		$st = $statuses->{$a->{'id'}};
		print &ui_checked_columns_row([
			"<a href='edit_alert.cgi?id=$a->{'id'}'>".
			  &describe_alert_servers($a)."</a>",
			&describe_alert_rules($a),
			&describe_alert_status($a, $st),
			], \@tds, "d", $a->{'id'});
		}
	print &ui_columns_end();
	print &ui_links_row(\@links);
	print &ui_form_end([ [ 'delete', $text{'alerts_delete'} ],
			     [ 'silence', $text{'alerts_silence'} ],
			     [ 'unsilence', $text{'alerts_unsilence'} ],
			     [ 'refresh', $text{'alerts_refresh'} ],
			   ]);
	}
else {
	print "<b>$text{'alerts_none'}</b><p>\n";
	print &ui_links_row(\@links);
	}

# Show firing systems
$statuses = &get_alert_statuses();
foreach $a (@alerts) {
	$st = $statuses->{$a->{'id'}};
	next if (!$st);
	@names = split(/,/, $st->{'names'});
	@idvalues = split(/,/, $st->{'values'});
	for(my $i=0; $i<@names; $i++) {
		$name = $names[$i];
		($id, $value) = split(/:/, $idvalues[$i]);
		$s = &get_managed_server($id);
		next if (!$s);
		($r) = grep { $_->{'name'} eq $name } @{$a->{'rules'}};
		$p = 60*60;
		foreach $hp (@history_periods) {
			if ($r->{'for'} < $hp->[1]) {
				$p = $hp->[1];
				}
			}
		$hgraph = "history.cgi?id=$s->{'id'}&stat=$name&".
			  "search=$s->{'host'}&period=$p";
		@links = ( "<a href='$hgraph'>$text{'alerts_graph'}</a>" );
		$cutoff = ($r->{'over'} ? $text{'alert_over'}
				: $text{'alert_under'})." ".$r->{'value'};
		if ($r->{'value'} =~ /(K|M|G|T)B?$/) {
			$value = &nice_size($value);
			}
		push(@table, [
		    "<a href='edit_serv.cgi?id=$s->{'id'}'>$s->{'host'}</a>",
		    $text{'history_stat_'.$name},
		    $cutoff,
		    $value,
		    &ui_links_row(\@links, 1),
		    ]);
		}
	}
if (@table) {
	print &ui_subheading($text{'alerts_firing'});
	print &ui_columns_table(
		[ $text{'alerts_server'}, $text{'alerts_stat'},
		  $text{'alerts_cutoff'}, $text{'alerts_value'},
		  $text{'alerts_actions'} ], 100, \@table);
	}

&ui_print_footer("", $text{'index_return'});
