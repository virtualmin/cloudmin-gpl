#!/usr/local/bin/perl
# Show a list of scheduled backups for root or a system owner

require './server-manager-lib.pl';
&can_action_error(undef, "backup");
&ui_print_header(undef, $text{'backups_title'}, "", "backups");

@backups = &list_available_backups();
@links = ( "<a href='edit_backup.cgi?new=1'>$text{'backups_add'}</a>" );
if (@backups) {
	# Show table of existing backups
	print &ui_links_row(\@links);
	print &ui_columns_start([
		$text{'backups_servers'},
		$text{'backups_dest'},
		$access{'owner'} ? ( ) : ( $text{'backups_owner'} ),
		$text{'backups_sched'},
		], 100);
	foreach $b (@backups) {
		$servs = &describe_alert_servers($b);
		$dest = $b->{'dest'} ? &nice_backup_destination($b->{'dest'})
				     : "<i>$text{'backups_fromhost'}</i>";
		$when = $b->{'enabled'} ? &cron::when_text($b, 1)
					: $text{'backups_dis'};
		print &ui_columns_row([
			"<a href='edit_backup.cgi?id=$b->{'id'}'>$servs</a>",
			$dest,
			$access{'owner'} ? ( ) :
				( $b->{'owner'} ||
				  "<i>$text{'vservers_nousers'}</i>" ),
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
