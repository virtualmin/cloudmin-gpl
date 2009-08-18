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
print &ui_form_end();

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
		print "<b>",&text('backuplogs_weekdesc', 7),"</b><p>\n";
		}
	else {
		# Limit by search term
		# XXX
		}

	# XXX
	if (@backups) {
		}
	else {
		}
	}

&ui_print_footer("", $text{'index_return'});
