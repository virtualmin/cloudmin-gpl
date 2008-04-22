#!/usr/local/bin/perl
# Show a list of system owners

require './server-manager-lib.pl';
&ui_print_header(undef, $text{'owners_title'}, "", "owners");
@allservers = &list_managed_servers();

@links = ( &select_all_link("d"), &select_invert_link("d"),
	   "<a href='edit_owner.cgi?new=1'>$text{'owners_add'}</a>" );
@owners = &list_system_owners();
if (@owners) {
	print &ui_form_start("delete_owners.cgi", "post");
	print &ui_links_row(\@links);
	@tds = ( "width=5" );
	print &ui_columns_start([ "", $text{'owners_name'},
				  $text{'owners_real'},
				  $text{'owners_users'} ], \@tds);
	foreach $o (@owners) {
		%canservers = map { $_, 1 }
			split(/\s+/, $o->{'acl'}->{'servers'});
		@users = grep { $canservers{$_->{'id'}} } @allservers;
		$users = @users == 0 ? $text{'xens_nousers'} :
		    @users > 4 ? &text('xens_manyusers', scalar(@users)) :
		    join(", ", map { "<tt>$_->{'host'}</tt>" } @users);
		print &ui_checked_columns_row([
			"<a href='edit_owner.cgi?name=".&urlize($o->{'name'}).
			 "'>$o->{'name'}</a>",
			$o->{'real'},
			$users,
			], \@tds, "d", $o->{'name'});
		}
	print &ui_columns_end();
	print &ui_links_row(\@links);
	print &ui_form_end([ [ undef, $text{'owners_delete'} ] ]);
	}
else {
	print "<b>$text{'owners_none'}</b><p>\n";
	shift(@links); shift(@links); 
	print &ui_links_row(\@links);
	}

&ui_print_footer("", $text{'index_return'});

