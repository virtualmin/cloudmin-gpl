#!/usr/local/bin/perl
# Show a form for editing or creating a backup

require './server-manager-lib.pl';
&can_action_error(undef, "backup");
&ReadParse();
if ($in{'new'}) {
	&ui_print_header(undef, $text{'backup_title1'}, "");
	}
else {
	($backup) = grep { $_->{'id'} eq $in{'id'} } &list_available_backups();
	$backup || &error($text{'backup_egone'});
	&ui_print_header(undef, $text{'backup_title2'}, "");
	}

print &ui_form_start("save_backup.cgi", "post");
print &ui_hidden_table_start($text{'backup_header'}, "width=100%", 2,
			     "main", 1);

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

# Destination
$dest = $backup->{'dest'} ? &parse_backup_destination($backup->{'dest'})
			  : undef;
print &ui_table_row($text{'backup_dest'},
	&ui_radio_table("dest_def", $backup->{'dest'} ? 0 : 1,
		[ [ 1, $text{'backup_dest1'} ],
		  [ 0, $text{'backup_dest0'},
			&show_backup_ssh_dest($dest, "ssh") ] ]));

# Owner, if logged in as root
if (!$access{'owner'} && $backup->{'owner'}) {
	print &ui_table_row($text{'backup_owner'},
		"<a href='edit_owner.cgi?name=".&urlize($backup->{'owner'}).
		"'>".&html_escape($backup->{'owner'})."</a>");
	}

# Shutdown or pause?
print &ui_table_row($text{'backup_shutdown'},
	&ui_radio("shutdown", int($backup->{'shutdown'}),
		  [ [ 1, $text{'backup_shutdown1'}."<br>" ],
		    [ 0, $text{'backup_shutdown0'} ] ]));

print &ui_hidden_table_end("main");

print &ui_hidden_table_start($text{'backup_sched'}, "width=100%", 2,
                             "sched", 0);

# Backup on scheduled enabled?
print &ui_table_row($text{'backup_enabled'},
	&ui_yesno_radio("enabled", $backup->{'enabled'}));

# Scheduled run time
# XXX
# XXX do nicely

print &ui_hidden_table_end("sched");

if ($in{'new'}) {
	print &ui_form_end([ [ undef, $text{'create'} ] ]);
	}
else {
	print &ui_form_end([ [ undef, $text{'save'} ],
			     [ 'run', $text{'backup_run'} ],
			     [ 'delete', $text{'delete'} ] ]);
	}

&ui_print_footer("list_backups.cgi", $text{'backups_return'});
