#!/usr/local/bin/perl
# Show a list of scheduled backups for root or a system owner

require './server-manager-lib.pl';
&can_action_error(undef, "backup");
&ui_print_header(undef, $text{'backups_title'}, "", "backups");

@backups = &list_available_backups();
@links = ( "<a href='edit_backup.cgi?new=1'>$text{'backups_add'}</a>" );
if (@backups) {
	# Show table of existing backups
	unshift(@links, &select_all_link("d"), &select_invert_link("d"));
	print &ui_links_row(\@links);
	print &ui_columns_start([
		$text{'backups_servers'},
		$text{'backups_dest'},
		$access{'owner'} ? ( ) : ( $text{'backups_owner'} ),
		$text{'backups_sched'},
		], 100);
	foreach $b (@backups) {
		if ($b->{'servers'} eq '*') {
			$servs = "<i>$text{'backups_all'}</i>";
			}
		else {
			@users = &get_backup_servers($b);
			$servs = @users == 0 ? $text{'keys_nousers'} :
			 @users > 4 ? &text('keys_manyusers', scalar(@users)) :
			   join(", ", map { "<tt>$_->{'host'}</tt>" } @users);
			}
		$dest = &nice_backup_dest($b->{'dest'});
		$when = $backup->{'enabled'} ? &cron::when_text($backup, 1)
					     : $text{'backups_dis'};
		print &ui_columns_row([
			"<a href='edit_backup.cgi?id=$b->{'id'}'>$servs</a>",
			$dest,
			$access{'owner'} ? ( ) : ( $backup->{'owner'} ),
			$when,
			]);
		}
	print &ui_columns_end();
	}
else {
	print "<b>$text{'backups_none'}</b><p>\n";
	}
print &ui_links_row(\@links);

&ui_print_footer("", $text{'index_return'});
