#!/usr/local/bin/perl
# Shows a list of known SSH keys

require './server-manager-lib.pl';
&can_action_error(undef, "global");
&ui_print_header(undef, $text{'keys_title'}, "", "keys");

@keys = &list_ssh_keys();
@links = ( &select_all_link("d"), &select_invert_link("d"),
	   "<a href='edit_key.cgi?new=1'>$text{'keys_add'}</a>" );
if (@keys) {
	# Show table
	@servers = &list_managed_servers();
	print &ui_form_start("delete_keys.cgi", "post");
	print &ui_links_row(\@links);
	@tds = ( "width=5" );
	print &ui_columns_start([ "",
				  $text{'keys_desc'},
				  $text{'keys_external'},
				  $text{'keys_users'} ]);
	foreach $k (@keys) {
		@users = grep { $_->{'key'} eq $k->{'id'} } @servers;
		$users = @users == 0 ? $text{'keys_nousers'} :
			 @users > 4 ? &text('keys_manyusers', scalar(@users)) :
			   join(", ", map { "<tt>$_->{'host'}</tt>" } @users);
		print &ui_checked_columns_row([
			"<a href='edit_key.cgi?id=$k->{'id'}'>$k->{'desc'}</a>",
			$k->{'external'} ? $text{'keys_ext'} :$text{'keys_int'},
			$users
			], \@tds, "d", $k->{'id'});
		}
	print &ui_columns_end();
	print &ui_links_row(\@links);
	print &ui_form_end([ [ "delete", $text{'keys_delete'} ] ]);
	}
else {
	print "<b>$text{'keys_none'}</b><p>\n";
	@links = ( $links[2] );
	print &ui_links_row(\@links);
	}

&ui_print_footer("", $text{'index_return'});


