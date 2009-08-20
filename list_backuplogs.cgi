#!/usr/local/bin/perl
# Show the logs of backups

require './server-manager-lib.pl';
&ReadParse();
if ($in{'id'} ne '') {
	$server = &get_managed_server_by("id", $in{'id'});
	&can_action_error($server, "backup");
	$subh = &server_in($server);
	}
else {
	&can_action_error(undef, "backup");
	}
&ui_print_header($subh, $text{'backuplogs_title'}, "");

# Show search form
print &ui_form_start("list_backuplogs.cgi", "post");
print &ui_hidden("id", $in{'id'});
print "<b>$text{'backuplogs_find'}</b>\n",
      &ui_textbox("search", $in{'search'}, 30),"\n",
      &ui_submit($text{'backuplogs_ok'})," ",
      &ui_submit($text{'backuplogs_week'}, "week"),"\n";
print &ui_form_end(),"<p>\n";

if ($in{'search'} || $in{'week'}) {
	# Show matching backups (that the user is allowed to see)
	if ($server) {
		@backups = &list_backup_logs($server);
		%servermap = ( $server->{'id'}, $server );
		}
	else {
		@backups = &list_backup_logs();
		%servermap = map { $_->{'id'}, $_ }
				 &list_available_managed_servers();
		@backups = grep { $servermap{$_->{'server'}} } @backups;
		}

	# Filter by search
	if ($in{'week'}) {
		# Limit to last 7 days
		$cutoff = time()-(7*24*60*60);
		@backups = grep { $_->{'time'} >= $cutoff } @backups;
		$msg = &text('backuplogs_weekdesc', 7);
		}
	else {
		# Limit by search term
		@backups = grep { &match_backup($_, $in{'search'}) } @backups;
		$msg = &text('backuplogs_finddesc', "<i>$in{'search'}</i>");
		}
	@backups = sort { $b->{'time'} <=> $a->{'time'} } @backups;

	# Show the results, with links to restore
	if (@backups) {
		print $msg,"<br>\n";
		print &ui_columns_start([
			$text{'backuplogs_dest'},
			$text{'backuplogs_time'},
			$server ? ( ) :
				( $text{'backuplogs_server'} ),
			$text{'backuplogs_status'},
			], 100);
		foreach $b (@backups) {
			print &ui_columns_row([
				"<a href='restore_form.cgi?log=$b->{'id'}'>".
				 &nice_backup_destination($b->{'dest'}).
				 "</a>",
				&make_date($b->{'time'}),
				$server ? ( ) :
				 ( $servermap{$b->{'server'}}->{'host'} ),
				$b->{'ok'} ?
				  &text('backuplogs_size',
					&nice_size($b->{'size'})) :
				  &text('backuplogs_failed', $b->{'msg'}),
				]);
			}
		print &ui_columns_end();
		}
	else {
		print "<b>$text{'backuplogs_none'}</b><p>\n";
		}
	}

&ui_print_footer("", $text{'index_return'});

sub match_backup
{
my ($backuplog, $search) = @_;
my $server = $servermap{$_->{'server'}};
return $server->{'host'} =~ /\Q$search\E/i ||
       $backuplog->{'owner'} =~ /\Q$search\E/i ||
       &nice_backup_destination($backuplog->{'dest'}) =~ /\Q$search\E/i;
return 0;
}

