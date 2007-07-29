#!/usr/local/bin/perl
# Shows a list of Virtualmin licences, including both those from running
# systems and those pre-registered. Also includes a form for bulk-adding
# new serials and keys

require './server-manager-lib.pl';
&ui_print_header(undef, $text{'licences_title'}, "", "licences");

# Show table of known licences
@lics = &list_virtualmin_licences();
if (@lics) {
	print &ui_form_start("delete_licences.cgi", "post");
	@tds = ( "width=5" );
	print &ui_columns_start([ "",
				  $text{'licences_serial'},
				  $text{'licences_key'},
				  $text{'licences_status'},
				  $text{'licences_domains'},
				  $text{'licences_servers'},
				  $text{'licences_users'} ], 100, 0, \@tds);
	foreach my $l (@lics) {
		@users = @{$l->{'users'}};
		$users = @users == 0 ? $text{'keys_nousers'} :
			 @users > 4 ? &text('keys_manyusers', scalar(@users)) :
			   join(", ", map { "<tt>$_->{'host'}</tt>" } @users);
		if ($l->{'progress'}) {
			$users .= &text('licences_progress', $l->{'progress'});
			}
		print &ui_checked_columns_row([
		    $l->{'serial'},
		    $l->{'key'},
		    $l->{'invalid'} ?
			"<font color=#ff0000>$text{'licences_invalid'}</font>" :
		    $l->{'vm2'} ?
			"<font color=#00aa00>$text{'licences_vm2'}</font>" :
			"<font color=#00aa00>$text{'licences_valid'}</font>",
		    $l->{'domains'} || $text{'licences_unlimited'},
		    $l->{'servers'} || $text{'licences_unlimited'},
		    $users ], \@tds, "d", $l->{'serial'});
		}
	print &ui_columns_end();
	print &ui_form_end([ [ undef, $text{'licences_delete'} ] ]);
	}
else {
	print "<b>$text{'licences_none'}</b><p>\n";
	}

# Show form to add
print "<hr>\n";
