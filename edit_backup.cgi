#!/usr/local/bin/perl
# Show a form for editing or creating a backup

require './server-manager-lib.pl';
&can_action_error(undef, "backup");
&ReadParse();
if ($in{'new'}) {
	&ui_print_header(undef, $text{'backup_title1'}, "");
	$backup = { 'special' => 'daily',
		    'servers' => '*' };
	if ($access{'owner'}) {
		$owner = &get_system_owner($base_remote_user);
		$backup->{'email'} = $owner->{'acl'}->{'email'};
		}
	}
else {
	($backup) = grep { $_->{'id'} eq $in{'id'} } &list_available_backups();
	$backup || &error($text{'backup_egone'});
	&ui_print_header(undef, $text{'backup_title2'}, "");
	}

print &ui_form_start("save_backup.cgi", "post");
print &ui_hidden("id", $in{'id'});
print &ui_hidden("new", $in{'new'});
print &ui_hidden_table_start($text{'backup_header'}, "width=100%", 2,
			     "main", 1, [ "width=30%" ]);

# Systems to backup
@servers = grep { &supports_backup($_) }
		&list_available_managed_servers_sorted();
print &ui_table_row($text{'backup_servers'},
	&ui_radio("servers_def", $backup->{'servers'} eq '*' ? 1 : 0,
		  [ [ 1, $backup->{'owner'} ? 
				&text('backup_servers1a', $backup->{'owner'}) :
				$text{'backup_servers1'} ],
		    [ 0, $text{'backup_servers0'} ] ])."<br>\n".
	&ui_select("servers", [ split(/\s+/, $backup->{'servers'}) ],
		   [ map { [ $_->{'id'}, $_->{'host'} ] } @servers ],
		   10, 1));

# Owner, if logged in as root
if (!$access{'owner'} && $backup->{'owner'}) {
	print &ui_table_row($text{'backup_owner'},
		"<a href='edit_owner.cgi?name=".&urlize($backup->{'owner'}).
		"'>".&html_escape($backup->{'owner'})."</a>");
	}

# Shutdown or pause?
print &ui_table_row($text{'backup_shutdown'},
	&ui_radio("shutdown", int($backup->{'shutdown'}),
		  [ [ 1, $text{'backup_shutdown1'} ],
		    [ 0, $text{'backup_shutdown0'} ] ]));

# Parallel mode
print &ui_table_row($text{'backup_parallel'},
	&ui_radio("parallel", int($backup->{'parallel'}),
		  [ [ 1, $text{'backup_parallel1'} ],
		    [ 0, $text{'backup_parallel0'} ] ]));

print &ui_hidden_table_end("main");

print &ui_hidden_table_start($text{'backup_sched'}, "width=100%", 2,
                             "sched", 0, [ "width=30%" ]);

# Destination
$dest = $backup->{'dest'} ? &parse_backup_destination($backup->{'dest'})
			  : undef;
$mode = !$backup->{'dest'} ? -1 : $dest->{'mode'};
print &ui_table_row($text{'backup_dest'},
	&ui_radio_table("dest_mode", $mode,
		[ [ -1, $text{'backup_dest0'} ],
		  [ 3, $text{'backup_dest3'},
			&show_backup_ssh_dest(
			    $mode == 3 ? $dest : { }, "ssh", 22) ],
		  [ 4, $text{'backup_dest4'},
			&show_backup_ssh_dest(
			    $mode == 4 ? $dest : { }, "ftp", 21) ],
	 	]));

print &ui_table_hr();

# Backup on scheduled enabled?
print &ui_table_row($text{'backup_enabled'},
	&ui_yesno_radio("enabled", $backup->{'enabled'}));

# Scheduled run time
print &ui_table_row($text{'backup_when'},
	&virtualmin_ui_show_cron_time("when", $backup, undef));

# Who to notify
print &ui_table_row($text{'backup_email'},
	&ui_opt_textbox("email", $backup->{'email'}, 40,
			$text{'backup_noemail'}));

# When to send
print &ui_table_row($text{'backup_always'},
	&ui_radio("always", int($backup->{'always'}),
		  [ [ 1, $text{'backup_always1'} ],
		    [ 0, $text{'backup_always0'} ] ]));

print &ui_hidden_table_end("sched");

if ($in{'new'}) {
	print &ui_form_end([ [ undef, $text{'create'} ] ]);
	}
else {
	print &ui_form_end([ [ undef, $text{'save'} ],
			     [ 'run', $text{'backup_run'} ],
			     [ 'restore', $text{'backup_restore'} ],
			     [ 'logs', $text{'backup_logs'} ],
			     [ 'delete', $text{'delete'} ] ]);
	}

&ui_print_footer("list_backups.cgi", $text{'backups_return'});
