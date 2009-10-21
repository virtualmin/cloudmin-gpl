#!/usr/local/bin/perl
# Show a list of domain syncs between virtual systems

require './server-manager-lib.pl';
&ui_print_header(undef, $text{'vsyncs_title'}, "", "vsyncs");
&can_action_error(undef, "domains");

# Find existing syncs and list them
@links = ( "<a href='edit_vsync.cgi?new=1'>$text{'vsyncs_add'}</a>" );
@vsyncs = grep { &can_virtualmin_sync($_) } &list_virtualmin_syncs();
if (@vsyncs) {
	print &ui_links_row(\@links);
	print &ui_columns_start([ $text{'vsyncs_src'},
				  $text{'vsyncs_dest'},
				  $text{'vsyncs_what'},
				  $text{'vsyncs_sched'} ], 100);
	foreach $v (@vsyncs) {
		$src = &get_managed_server($v->{'src'});
		@users = &get_virtualmin_sync_dests($v);
		$users = @users == 0 ? $text{'keys_nousers'} :
                         @users > 4 ? &text('keys_manyusers', scalar(@users)) :
                           join(", ", map { "<tt>$_->{'host'}</tt>" } @users);
		@doms = split(/\s+/, $v->{'doms'});
		$what = @doms == 0 ? $text{'vsyncs_templates'} :
			@doms > 4 ? &text('vsyncs_manydoms', scalar(@doms)) :
			  join(", ", map { "<tt>$_</tt>" } @doms);
		print &columns_row([
			"<a href='edit_vsync.cgi?id=$v->{'id'}'>".
			  $src->{'host'}."</a>",
			$users,
			$what,
			$v->{'enabled'} ? &cron::when_text($v, 1)
				        : $text{'backups_dis'},
			]);
		}
	print &ui_columns_end();
	}
else {
	print "<b>$text{'vsyncs_none'}</b><p>\n";
	}
print &ui_links_row(\@links);

&ui_print_footer("", $text{'index_return'});
