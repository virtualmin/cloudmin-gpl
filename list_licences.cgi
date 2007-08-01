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
		    "<a href='edit_licence.cgi?serial=$l->{'serial'}'>".
		     $l->{'serial'}."</a>",
		    $l->{'key'},
		    $l->{'invalid'} ?
			"<font color=#ff0000>$text{'licences_invalid'}</font>" :
		    $l->{'vm2'} ?
			"<font color=#00aa00>$text{'licences_vm2'}</font>" :
		    !$l->{'free'} ?
			"<font color=#008800>$text{'licences_used'}</font>" :
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

# Show form to add one
print "<hr>\n";
print &ui_form_start("add_licences.cgi");
print &ui_table_start($text{'licences_header'}, undef, 4,
		      [ "width=20%", undef, "width=20%", undef ]);

print &ui_table_row($text{'licences_serial'},
		    &ui_textbox("serial", undef, 20));

print &ui_table_row($text{'licences_key'},
		    &ui_textbox("key", undef, 30));

print &ui_table_end();
print &ui_form_end([ [ undef, $text{'licences_addok'} ] ]);

# Show form to add in bulk
print "<hr>\n";
print $text{'licences_adddesc'},"<p>\n";
print &ui_form_start("add_licences.cgi", "post");
print &ui_textarea("licences", undef, 10, 70);
print &ui_form_end([ [ undef, $text{'licences_add'} ] ]);

&ui_print_footer("", $text{'index_return'});

