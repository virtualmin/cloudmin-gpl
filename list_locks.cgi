#!/usr/local/bin/perl
# Show a list of all servers that have locks on them

require './server-manager-lib.pl';
&can_action_error(undef, "global");
&ui_print_header(undef, $text{'locks_title'}, "");

@locks = &list_running_actions();
if (@locks) {
	# Show table of existing servers
	@tds = ( "width=5" );
	print &ui_form_start("kill_locks.cgi", "post");
	print &ui_columns_start([ "",
				  $text{'locks_host'},
				  $text{'locks_short'},
				  $text{'locks_pid'},
				  $text{'locks_time'},
				  $text{'locks_age'} ], 100, 0, \@tds);
	foreach my $l (@locks) {
		$s = $l->{'server'};
		print &ui_checked_columns_row([
		    "<a href='edit_serv.cgi?id=$s->{'id'}'>".
		      $s->{'host'}."</a>",
		    "<tt>".&html_escape($l->{'short'})."</tt>",
		    $l->{'pid'},
		    &make_date($l->{'time'}),
		    &nice_hour_mins_secs(time() - $l->{'time'}),
		    ], \@tds, "d", $l->{'pid'}, 0, $l->{'safe'} == 0);
		}
	print &ui_columns_end();
	print &ui_form_end([ [ undef, $text{'locks_kill'} ] ]);
	}
else {
	print "<b>$text{'locks_none'}</b><p>\n";
	}

&ui_print_footer("", $text{'index_return'});
