#!/usr/local/bin/perl
# Show a form for restoring a backup

require './server-manager-lib.pl';
&can_action_error(undef, "backup");
&ReadParse();
if ($in{'log'}) {
	# From backup log, for one system
	$backuplog = &get_backup_log($in{'log'});
	$backuplog || &error($text{'restore_egone'});
	$server = &get_managed_server($backuplog->{'server'}) ||
		  &get_managed_server_by("host", $backuplog->{'host'});
	if ($server) {
		# Restoring existing system
		@servers = ( $server );
		}
	elsif ($backuplog->{'host'}) {
		# Check if we have details to restore
		$server = &get_missing_backup_server($backuplog->{'host'},
						     $backuplog->{'base_dest'});
		$server || &error($text{'restore_egone3'});
		@servers = ( $server );
		}
	else {
		&error($text{'restore_egone4'});
		}
	$dest = $backuplog->{'dest'};
	$dest =~ s/\/([^\/]+)$//;	# Remove host.tar.gz
	}
elsif ($in{'id'}) {
	# All systems from a backup schedule
	($backup) = grep { $_->{'id'} eq $in{'id'} } &list_backups();
	$backup || &error($text{'restore_egone2'});
	!$access{'owner'} || $backup->{'owner'} eq $base_remote_user ||
		&error($text{'restore_ecannot'});
	@servers = &get_backup_servers($backup);
	$dest = $backup->{'dest'};
	}
else {
	# Allow free choice of systems and source (Host, FTP or SSH)
	$dest = undef;
	}

&ui_print_header(undef, $text{'restore_title'}, "");

print $text{'restore_desc'},"<p>\n";

print &ui_form_start("restore.cgi", "post");
print &ui_hidden("log", $in{'log'});
print &ui_hidden("id", $in{'id'});
print &ui_table_start($text{'restore_header'}, "width=100%", 2);

# Systems to include
if ($in{'log'}) {
	# Exactly one system
	print &ui_table_row($text{'restore_servers'},
		"<tt>$servers[0]->{'host'}</tt>".
		($servers[0]->{'missing'} ? " (".$text{'restore_missing'}.")"
					  : ""));
	print &ui_hidden("servers", $servers[0]->{'id'});
	}
else {
	# Allow selection, with those from backup checked by default
	@allservers = grep { &supports_backup($_) }
			&list_available_managed_servers_sorted();
	print &ui_table_row($text{'restore_servers'},
		&ui_select("servers", [ map { $_->{'id'} } @servers ],
			   [ map { [ $_->{'id'}, $_->{'host'} ] } @allservers ],
			   10, 1));
	}

# Parallel mode
if (!$in{'log'}) {
	print &ui_table_row($text{'restore_parallel'},
		&ui_radio("parallel", int($backup->{'parallel'}),
			  [ [ 1, $text{'backup_parallel1'} ],
			    [ 0, $text{'backup_parallel0'} ] ]));
	}

# Destination, which may be fixed
if ($dest) {
	print &ui_table_row($text{'restore_dest'},
		&nice_backup_destination($dest));
	}
else {
	print &ui_table_row($text{'restore_dest'},
	    &ui_radio_table("dest_mode", -1,
		[ [ -1, $text{'backup_dest0'} ],
		  [ 3, $text{'backup_dest3'},
			&show_backup_ssh_dest({ }, "ssh", 22) ],
		  [ 4, $text{'backup_dest4'},
			&show_backup_ssh_dest({ }, "ftp", 21) ],
	 	]));
	}

print &ui_table_end();
print &ui_form_end([ [ undef, $text{'restore_ok'} ] ]);

&ui_print_footer("", $text{'return'});

