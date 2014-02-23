#!/usr/local/bin/perl
# Show a form for backing up one system

require './server-manager-lib.pl';
&error_setup($text{'onebackup_err'});
&can_action_error(undef, "backup");
&ReadParse();
my $server = &get_managed_server($in{'id'});
$server || &error($text{'edit_egone'});
&ui_print_header(&server_in($server), $text{'onebackup_title'}, "");

my $efunc = "type_".$server->{'manager'}."_backup_extension";
my $ext = defined(&$efunc) ? &$efunc($server) : undef;
$ext ||= "gz";

print &ui_form_start("onebackup.cgi/$server->{'host'}.$ext", "post");
print &ui_hidden("id", $in{'id'});
print &ui_table_start($text{'onebackup_header'}, "width=100%", 2);

# Destination
@allservers = &list_available_managed_servers_sorted();
@allservers = grep { &can_ssh_status($_) &&
		     $_->{'id'} != $server->{'id'} } @allservers;
print &ui_table_row($text{'backup_dest'},
	&ui_radio_table("dest_mode", 7,
		[ [ 7, $text{'backups_mode7'} ],
		  @allservers ?
		  ( [ 2, $text{'backups_mode2'},
		         "<table>\n".
		         "<tr> <td><b>$text{'backups_dirhost'}</b></td>\n".
		         "<td>".&ui_select("vm2", undef,
				 [ map { [ $_->{'id'}, $_->{'short_host'} ] }
				       @allservers ])."</td> </tr>\n".
		         "<tr> <td><b>$text{'backups_dirdir'}</b></td>\n".
		         "<td>".&ui_textbox("vm2dir", "/backup", 40).
			 "</td> </tr>\n".
		         "</table>" ] ) : ( ),
		  [ 3, $text{'backup_dest3'},
			&show_backup_ssh_dest({ }, "ssh", 22) ],
		  [ 4, $text{'backup_dest4'},
			&show_backup_ssh_dest({ }, "ftp", 21) ],
		  [ 5, $text{'backup_dest5'},
			&show_backup_s3_dest({ }, 0) ],
		  [ 6, $text{'backup_dest6'},
			&show_backup_rs_dest({ }, 0) ],
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
