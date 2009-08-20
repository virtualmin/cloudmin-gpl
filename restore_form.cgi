#!/usr/local/bin/perl
# Show a form for restoring a backup

require './server-manager-lib.pl';
&can_action_error(undef, "backup");
&ReadParse();
if ($in{'log'}) {
	# From backup log, for one system
	$backuplog = &get_backup_log($in{'log'});
	$backuplog || &error($text{'restore_egone'});
	@servers = ( &get_managed_server_by("id", $backuplog->{'server'}) );
	$dest = $backuplog->{'dest'};
	}
elsif ($in{'id'}) {
	# All systems from a backup schedule
	($backup) = grep { $_->{'id'} eq $in{'id'} } &list_backups();
	$backup || &error($text{'restore_egone2'});
	!$access{'owner'} || $access{'owner'} eq $backup->{'owner'} ||
		&error($text{'restore_ecannot'});
	@servers = &get_backup_servers($backup);
	$dest = $backup->{'dest'};
	}
else {
	# Allow free choice of systems and source (Host, FTP or SSH)
	# XXX
	}

&ui_print_header(undef, $text{'restore_title'}, "");

print &ui_form_start("restore.cgi", "post");
print &ui_table_start($text{'restore_header'}, "width=100%", 2);

# Systems to include
# XXX limit to owner

# Parallel mode
print &ui_table_row($text{'restore_parallel'},
	&ui_radio("parallel", int($backup->{'parallel'}),
		  [ [ 1, $text{'backup_parallel1'} ],
		    [ 0, $text{'backup_parallel0'} ] ]));

# Destination
# XXX (may be fixed if $dest is set)

print &ui_form_end([ [ undef, $text{'restore_ok'} ] ]);

&ui_print_footer("", $text{'return'});

