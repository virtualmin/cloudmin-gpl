#!/usr/local/bin/perl
# Show a list of multi-system Virtualmin backups

require './server-manager-lib.pl';
&ui_print_header(undef, $text{'vbackups_title'}, "", "vbackups");
&can_action_error(undef, "domains");

# Find existing syncs and list them
@links = ( "<a href='edit_vbackup.cgi?new=1'>$text{'vbackups_add'}</a>" );
@vbackups = grep { &can_virtualmin_backup($_) } &list_virtualmin_backups();
if (@vbackups) {
	print &ui_links_row(\@links);
	print &ui_columns_start([ $text{'vbackups_srcs'},
				  $text{'vbackups_dest'},
				  $text{'vbackups_what'},
				  $text{'vbackups_sched'} ], 100);
	foreach $v (@vbackups) {
		@users = &get_virtualmin_backup_srcs($v);
		$users = @users == 0 ? $text{'keys_nousers'} :
                         @users > 4 ? &text('keys_manyusers', scalar(@users)) :
                           join(", ", map { "<tt>$_->{'host'}</tt>" } @users);
		@doms = split(/\s+/, $v->{'doms'});
		$what = $v->{'doms_all'} ? $text{'vsyncs_domsall'} :
		        @doms == 0 ? $text{'vsyncs_templates'} :
			@doms > 4 ? &text('vsyncs_manydoms', scalar(@doms)) :
			  join(", ", map { "<tt>$_</tt>" } @doms);
		print &ui_columns_row([
			"<a href='edit_vbackup.cgi?id=$v->{'id'}'>".
			  $users."</a>",
			$v->{'dest'},
			$what,
			$v->{'enabled'} ? &cron::when_text($v, 1)
				        : $text{'backups_dis'},
			]);
		}
	print &ui_columns_end();
	}
else {
	print "<b>$text{'vbackups_none'}</b><p>\n";
	}
print &ui_links_row(\@links);

&ui_print_footer("", $text{'index_return'});
