#!/usr/local/bin/perl
# Delete one or more backups for specific systems

require './server-manager-lib.pl';
&ReadParse();
&error_setup($text{'dbackup_err'});
&error_if_cloudmin_replica();
@d = split(/\0/, $in{'d'});
@d || &error($text{'dbackup_enone'});

# Get the system, if any
if ($in{'id'} ne '') {
	$server = &get_managed_server_by("id", $in{'id'});
	&can_action_error($server, "backup");
	$subh = &server_in($server);
	}
else {
	&can_action_error(undef, "backup");
	}

# Get and check the backups and systems
%servermap = map { $_->{'id'}, $_ }
		 &list_available_managed_servers();
foreach $id (@d) {
	$log = &get_backup_log($id);
	$log || &error(&text('dbackup_egone', $id));
	$server = $servermap{$log->{'server'}};
	$server || &error(&text('dbackup_egone2', $id));
	push(@logs, $log);
	}

# Do it, showing progress to the user
&ui_print_unbuffered_header($subh, $text{'dbackup_title'}, "");

@dest = ( );
foreach $log (@logs) {
	$server = $servermap{$log->{'server'}};
	&$first_print(&text('dbackup_deleting', $server->{'host'},
			    &nice_backup_destination($log->{'dest'})));
	$err = &delete_backup_dest(&parse_backup_destination($log->{'dest'}),
				   $server);
	if ($err) {
		&$second_print(&text('dbackup_failed', $err));
		}
	else {
		&$second_print(&text('dbackup_done',
				     &nice_size($log->{'size'})));

		# Also remove other logs for this dest
		@samelogs = grep { $_->{'dest'} eq $log->{'dest'} }
				 &list_backup_logs($server);
		foreach $samelog (@samelogs) {
			&delete_backup_log($samelog);
			}
		push(@dest, $log->{'dest'});
		}
	}
&compute_backup_space();
@dest = &unique(@dest);
if (@dest) {
	&webmin_log("delete", "backuplog", scalar(@dest),
		    { 'dest' => join(' ', @dest) });
	}

&ui_print_footer("list_backuplogs.cgi?id=$in{'id'}",
		 $text{'backuplogs_return'});
