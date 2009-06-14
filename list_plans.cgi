#!/usr/local/bin/perl
# Show a list of account plans for owners

require './server-manager-lib.pl';
&can_action_error(undef, "global");
&ui_print_header(undef, $text{'plans_title'}, "", "plans");

@links = ( &select_all_link("d"), &select_invert_link("d"),
	   "<a href='edit_plan.cgi?new=1'>$text{'plans_add'}</a>" );
@plans = &list_plans();
@owners = &list_system_owners();
print &ui_form_start("delete_plans.cgi", "post");
print &ui_links_row(\@links);
@tds = ( "width=5" );
print &ui_columns_start([ "",
			  $text{'plans_desc'},
			  $text{'plans_max_servers'},
			  $text{'plans_max_ram'},
			  $text{'plans_max_disk'},
			  $text{'plans_owners'}, ], 100, 0, \@tds);
foreach $p (@plans) {
	@users = grep { $_->{'acl'}->{'plan'} eq $p->{'id'} } @owners;
	$users = @users == 0 ? $text{'plans_nousers'} :
	    @users > 4 ? &text('plans_manyusers', scalar(@users)) :
	    join(", ", map { "<tt>$_->{'name'}</tt>" } @users);
	print &ui_checked_columns_row([
		"<a href='edit_plan.cgi?id=$p->{'id'}'>".
		 &html_escape($p->{'desc'})."</a>",
		$p->{'max_servers'} || $text{'domains_unlimited'},
		$p->{'max_ram'} ? &nice_size($p->{'max_ram'})
				: $text{'domains_unlimited'},
		$p->{'max_disk'} ? &nice_size($p->{'max_disk'})
				 : $text{'domains_unlimited'},
		$users,
		], \@tds, "d", $p->{'id'});
	}
print &ui_columns_end();
print &ui_links_row(\@links);
print &ui_form_end([ [ undef, $text{'plans_delete'} ] ]);

&ui_print_footer("", $text{'index_return'});

