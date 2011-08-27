#!/usr/local/bin/perl
# Show the logs of backups

require './server-manager-lib.pl';
&ReadParse();
if ($in{'id'} ne '') {
	$server = &get_managed_server_by("id", $in{'id'});
	&can_action_error($server, "backup");
	$subh = &server_in($server);
	}
elsif ($in{'log'}) {
	($backup) = grep { $_->{'id'} eq $in{'log'} }
			 &list_available_backups();
	$backup || &error($text{'backup_egone'});
	if ($backup->{'dest'}) {
		$subh = &text('backuplogs_subh',
			      &nice_backup_destination($backup->{'dest'}));
		}
	else {
		$subh = &text('backuplogs_subh2');
		}
	}
else {
	&can_action_error(undef, "backup");
	}
&ui_print_header($subh, $text{'backuplogs_title'}, "");
$days = $config{'backuplog_days'} || 7;

# Show search form
if (!$in{'log'}) {
	print &ui_form_start("list_backuplogs.cgi", "post");
	print &ui_hidden("id", $in{'id'});
	print "<b>$text{'backuplogs_find'}</b>\n",
	      &ui_textbox("search", $in{'search'}, 30),"\n",
	      &ui_submit($text{'backuplogs_ok'})," ",
	      &ui_submit(&text('backuplogs_week', $days), "week"),"\n";
	print &ui_form_end(),"<p>\n";
	}
$params = "id=".&urlize($in{'id'})."&log=".&urlize($in{'log'}).
	  "&search=".&urlize($in{'search'});

if ($in{'search'} || $in{'week'} || $in{'log'}) {
	# Show matching backups (that the user is allowed to see)
	if ($server) {
		# For one system
		@backups = &list_backup_logs($server);
		%servermap = ( $server->{'id'}, $server );
		}
	elsif ($in{'log'}) {
		# From one scheduled backup
		@backups = &list_backup_logs();
		%servermap = map { $_->{'id'}, $_ }
				 &list_available_managed_servers();
		@backups = grep { $_->{'backup'} eq $in{'log'} } @backups;
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
		$cutoff = time()-($days*24*60*60);
		@backups = grep { $_->{'time'} >= $cutoff } @backups;
		$msg = &text('backuplogs_weekdesc', $days);
		}
	elsif ($in{'search'}) {
		# Limit by search term
		@backups = grep { &match_backup($_, $in{'search'}) } @backups;
		$msg = &text('backuplogs_finddesc', "<i>$in{'search'}</i>");
		}
	@backups = sort { $b->{'time'} <=> $a->{'time'} } @backups;

	# Show the results, with links to restore
	if (@backups) {
		print $msg,"<br>\n" if ($msg);
		print $text{'backuplogs_help'},"<br>\n";
		@tds = ( "width=5" );
		print &ui_form_start("delete_backuplogs.cgi", "post");
		print &ui_hidden("id", $in{'id'});
		print &ui_columns_start([
			"",
			$text{'backuplogs_dest'},
			$text{'backuplogs_time'},
			$server ? ( ) :
				( $text{'backuplogs_server'} ),
			$text{'backuplogs_status'},
			], 100, 0, \@tds);
		foreach $b (@backups) {
			$candelete = $dest->{'mode'} <= 2 &&
				     $b->{'ok'};
			print &ui_checked_columns_row([
				"<a href='view_backuplog.cgi?".
				 "bid=$b->{'id'}&$params'>".
				 &nice_backup_destination($b->{'dest'}).
				 "</a>",
				&make_date($b->{'time'}),
				$server ? ( ) :
				 ( $servermap{$b->{'server'}}->{'host'} ),
				$b->{'ok'} ?
				  &text('backuplogs_size',
					&nice_size($b->{'size'})) :
				  &text('backuplogs_failed', $b->{'msg'}),
				], \@tds, "d", $b->{'id'}, 0, !$candelete);
			}
		print &ui_columns_end();
		print &ui_form_end([ [ undef, $text{'backuplogs_delete'} ] ]);
		}
	else {
		print "<b>$text{'backuplogs_none'}</b><p>\n";
		}
	}

if ($in{'log'}) {
	&ui_print_footer("edit_backup.cgi?id=$in{'log'}",
			 $text{'backup_return'});
	}
else {
	&ui_print_footer("", $text{'index_return'});
	}

sub match_backup
{
my ($backuplog, $search) = @_;
my $server = $servermap{$_->{'server'}};
return $server->{'host'} =~ /\Q$search\E/i ||
       $backuplog->{'owner'} =~ /\Q$search\E/i ||
       &nice_backup_destination($backuplog->{'dest'}) =~ /\Q$search\E/i;
return 0;
}

