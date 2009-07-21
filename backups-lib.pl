# Functions for virtual system backups

# list_backups()
# Returns a list of backups configured by root or system owners
sub list_backups
{
}

sub save_backup
{
}

sub delete_backup
{
}

sub execute_backup
{
}

sub restore_backup
{
}

# parse_backup_destination(dest)
# Given a destination string, split into into a hash ref with keys
# mode = 0 = Cloudmin master
#        1 = Host system
#        2 = Other Cloudmin-managed system
#        3 = SSH server
# id   = Cloudmin host ID
# host = SSH hostname
# port = SSH port number
# user = SSH login
# pass = SSH password
# path = Directory on host
sub parse_backup_destination
{
my ($dest) = @_;
if ($dest =~ /^master:(\/\S*)$/) {
	return { 'mode' => 0, 'path' => $1 };
	}
elsif ($dest =~ /^host:(\/\S*)$/) {
	return { 'mode' => 1, 'path' => $1 };
	}
elsif ($dest =~ /^vm2:([^:]+):(\/\S*)$/) {
	return { 'mode' => 2, 'id' => $1, 'path' => $2 };
	}
elsif ($dest =~ /^ssh:([^:]+):([^\@]+)\@([^:\/]+)(:(\d+))?(\/\S*)$/) {
	return { 'mode' => 3, 'user' => $1, 'pass' => $2,
		 'host' => $3, 'port' => $5, 'path' => $6 };
	}
else {
	return undef;
	}
}

# show_default_backup_dest_table(&server)
# Output a table for a host system's page for selecting a default backup
# destination for instances on that host.
sub show_default_backup_dest_table
{
my ($server) = @_;
print &ui_hidden_table_start($text{'backups_dheader'}, "width=100%", 2,
			     "backups", 0);

my $dstr = $server->{'backup_default'};
my $dest = &parse_backup_destination($dstr);

my @servers = grep { $_->{'id'} ne '0' } &list_managed_servers_sorted();
print &ui_table_row($text{'backups_def'},
    &ui_radio_table("backup_mode", $dest ? $dest->{'mode'} : -1,
	[ [ -1, $text{'backups_modenone'} ],
	  [ 0, $text{'backups_mode0'},
	       &ui_textbox("backup_masterdir", $dest->{'mode'} == 0 ?
						$dest->{'path'} : "", 40) ],
	  [ 1, $text{'backups_mode1'},
	       &ui_textbox("backup_hostdir", $dest->{'mode'} == 1 ?
						$dest->{'path'} : "", 40) ],
	  [ 2, $text{'backups_mode2'},
	       &ui_select("backup_vm2", $dest->{'id'},
			  [ map { [ $_->{'id'}, $_->{'host'} ] } @servers ]).
	       " ".
	       &ui_textbox("backup_vm2dir", $dest->{'mode'} == 2 ?
						$dest->{'path'} : "", 40) ],
	  [ 3, $text{'backups_mode3'},
	       &show_backup_ssh_dest($dest, "backup") ] ]));

print &ui_hidden_table_end("backups");
}

# parse_default_backup_dest_table(&server, &in)
# Updates a server's backup_default key with details of the default 
# destination. May call error if input is invalid
sub parse_default_backup_dest_table
{
my ($server, $in) = @_;
# XXX
}

# show_backup_ssh_dest(&destination, prefix)
# Returns HTML for entering SSH server details for a backup
sub show_backup_ssh_dest
{
my ($dest, $pfx) = @_;
return "<table>".
       "<tr> <td><b>$text{'backups_sshhost'}</b></td> ".
       "<td>".&ui_textbox($pfx."_host", $dest->{'host'}, 30)."</td> </tr>\n".
       "<tr> <td><b>$text{'backups_sshport'}</b></td> ".
       "<td>".&ui_opt_textbox($pfx."_port", $dest->{'port'}, 6,
			      $text{'default'}." (22)")."</td> </tr>\n".
       "<tr> <td><b>$text{'backups_sshuser'}</b></td> ".
       "<td>".&ui_textbox($pfx."_user", $dest->{'user'}, 20)."</td> </tr>\n".
       "<tr> <td><b>$text{'backups_sshpass'}</b></td> ".
       "<td>".&ui_password($pfx."_pass", $dest->{'pass'}, 20)."</td> </tr>\n".
       "<tr> <td><b>$text{'backups_sshpath'}</b></td> ".
       "<td>".&ui_textbox($pfx."_path", $dest->{'path'}, 40)."</td> </tr>\n".
       "</table>\n";
}

1;

