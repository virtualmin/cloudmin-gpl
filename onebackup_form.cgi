#!/usr/local/bin/perl
# Show a form for backing up one system

require './server-manager-lib.pl';
&error_setup($text{'onebackup_err'});
&can_action_error(undef, "backup");
&ReadParse();
my $server = &get_managed_server($in{'id'});
$server || &error($text{'edit_egone'});
&ui_print_header(&server_in($server), $text{'onebackup_title'}, "");

print &ui_form_start("onebackup.cgi", "post");
print &ui_hidden("id", $in{'id'});
print &ui_table_start($text{'onebackup_header'}, "width=100%", 2);

# Destination
$dest = $backup->{'dest'} ? &parse_backup_destination($backup->{'dest'})
			  : undef;
if ($dest && $dest->{'mode'} == 0) {
	# On master, convert to on-host mode
	$dest->{'mode'} = 2;
	$dest->{'id'} = '0';
	}
@allservers = &list_available_managed_servers_sorted();
print &ui_table_row($text{'backup_dest'},
	&ui_radio_table("dest_mode", 7,
		[ [ 7, $text{'backups_mode7'} ],
		  [ 2, $text{'backups_mode2'},
		       "<table>\n".
		       "<tr> <td><b>$text{'backups_dirhost'}</b></td>\n".
		       "<td>".&ui_select("vm2", $dest->{'id'},
					 [ map { [ $_->{'id'}, $_->{'short_host'} ] }
					       @allservers ])."</td> </tr>\n".
		       "<tr> <td><b>$text{'backups_dirdir'}</b></td>\n".
		       "<td>".&ui_textbox("vm2dir",
					   $dest->{'mode'} == 2 ? $dest->{'path'} : "", 40)."</td> </tr>\n".
		       "</table>" ],
		  [ 3, $text{'backup_dest3'},
			&show_backup_ssh_dest(
			    $mode == 3 ? $dest : { }, "ssh", 22) ],
		  [ 4, $text{'backup_dest4'},
			&show_backup_ssh_dest(
			    $mode == 4 ? $dest : { }, "ftp", 21) ],
		  [ 5, $text{'backup_dest5'},
			&show_backup_s3_dest($mode == 5 ? $dest : { }, 0) ],
		  [ 6, $text{'backup_dest6'},
			&show_backup_rs_dest($mode == 6 ? $dest : { }, 0) ],
	 	]));

# Shutdown or pause?
if ($server->{'status'} ne 'down') {
	print &ui_table_row($text{'onebackup_shutdown'},
		&ui_radio("shutdown", 0,
			  [ [ 1, $text{'backup_shutdown1'} ],
			    [ 0, $text{'backup_shutdown0'} ] ]));
	}

print &ui_table_end();
print &ui_form_end([ [ undef, $text{'onebackup_run'} ] ]);

&ui_print_footer("list_backups.cgi", $text{'backups_return'});
