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
# XXX

# Destination
# XXX

# Shutdown or pause?
# XXX

print &ui_hidden_table_end("main");

print &ui_hidden_table_start($text{'backup_sched'}, "width=100%", 2,
                             "sched", 0);

# Backup on scheduled enabled?
# XXX

# Scheduled run time
# XXX

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
