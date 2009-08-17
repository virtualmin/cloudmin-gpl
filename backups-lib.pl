# Functions for virtual system backups

# list_backups()
# Returns a list of backups configured by root or system owners
sub list_backups
{
opendir(BACKUPS, $scheduled_backups_dir);
foreach my $b (readdir(BACKUPS)) {
	if ($b ne "." && $b ne "..") {
		my %backup;
		&read_file("$scheduled_backups_dir/$b", \%backup);
		$backup{'id'} = $b;
		$backup{'file'} = "$scheduled_backups_dir/$b";
		delete($backup{'enabled'});	# Worked out below
		push(@rv, \%backup);
		}
	}
closedir(BACKUPS);

# Merge in cron jobs to see which are enabled
&foreign_require("cron", "cron-lib.pl");
my @jobs = &cron::list_cron_jobs();
foreach my $j (@jobs) {
	if ($j->{'user'} eq 'root' &&
	    $j->{'command'} =~ /^\Q$backup_cron_cmd\E(\s+\-\-id\s+(\d+))?/) {
		my $id = $2 || 1;
		my ($backup) = grep { $_->{'id'} eq $id } @rv;
		if ($backup) {
			$backup->{'enabled'} = 1;
			&copy_cron_sched_keys($j, $backup);
			}
		}
	}

@rv = sort { $a->{'id'} <=> $b->{'id'} } @rv;
return @rv;
}

# list_available_backups()
# Lists all backups the current user has access to
sub list_available_backups
{
my @backups = &list_backups();
if ($access{'owner'}) {
	@backups = grep { $_->{'owner'} eq $base_remote_user } @backups;
	}
return @backups;
}

# get_backup_servers(&backup)
# Converts a backup into a list of system hashes
sub get_backup_servers
{
my ($backup) = @_;
my @servers = &list_managed_servers();
if ($backup->{'servers'} eq '*') {
	return @servers;
	}
else {
	my %sids = map { $_, 1 } split(/\s+/, $backup->{'servers'});
	return grep { $sids{$_->{'id'}} } @servers;
	}
}

sub copy_cron_sched_keys
{
my ($src, $dst) = @_;
foreach my $k ('mins', 'hours', 'days', 'months', 'weekdays', 'special') {
	$dst->{$k} = $src->{$k};
	}
}

# save_backup(&backup)
# Create or update a scheduled backup. Also creates any needed cron job.
sub save_backup
{
my ($backup) = @_;
my $wasnew = !$backup->{'id'};
&make_dir($scheduled_backups_dir, 0700) if (!-d $scheduled_backups_dir);
$backup->{'id'} ||= &server_id();
$backup->{'file'} = "$scheduled_backups_dir/$backup->{'id'}";
&write_file($backup->{'file'}, $backup);

# Update or delete cron job
&foreign_require("cron", "cron-lib.pl");
my $cmd = $backup_cron_cmd." --id ".$backup->{'id'};
my $job;
if (!$wasnew) {
	($job) = &find_server_manager_cron_job($cmd);
	}
if ($backup->{'enabled'} && $job) {
	# Fix job schedule
	&copy_cron_sched_keys($backup, $job);
	&cron::change_cron_job($job);
	}
elsif ($backup->{'enabled'} && !$job) {
	# Create cron job
	$job = { 'user' => 'root',
		 'active' => 1,
		 'command' => $cmd };
	&copy_cron_sched_keys($backup, $job);
	&cron::create_cron_job($job);
	}
elsif (!$backup->{'enabled'} && $job) {
	# Delete cron job
	&cron::delete_cron_job($job);
	}
&cron::create_wrapper($backup_cron_cmd, $module_name, "backup.pl");
}

# delete_backup(&backup)
# Delete one scheduled backup, and its cron job
sub delete_backup
{
my ($backup) = @_;
&unlink_file($backup->{'file'});

# Delete cron too
&foreign_require("cron", "cron-lib.pl");
my $cmd = $backup_cron_cmd." --id ".$backup->{'id'};
my @jobs = &find_server_manager_cron_job($cmd);
if (@jobs) {
	&cron::delete_cron_job($jobs[0]);
	}
}

# parse_backup_destination(dest)
# Given a destination string, split into into a hash ref with keys
# mode = 0 = Cloudmin master
#        1 = Host system
#        2 = Other Cloudmin-managed system
#        3 = SSH server
#	 4 = FTP server
# id   = Cloudmin host ID
# host = SSH hostname
# port = SSH port number
# user = SSH login
# pass = SSH password
# path = Directory on host
sub parse_backup_destination
{
my ($dest) = @_;
if ($dest =~ /^master:(\/\S*)$/ || $dest =~ /^(\/\S*)$/) {
	return { 'mode' => 0, 'path' => $1 };
	}
elsif ($dest =~ /^host:(\/\S*)$/) {
	return { 'mode' => 1, 'path' => $1 };
	}
elsif ($dest =~ /^vm2:([^:]+):(\/\S*)$/) {
	return { 'mode' => 2, 'id' => $1, 'path' => $2 };
	}
elsif ($dest =~ /^ssh:([^:]+):([^\@]+)\@([^:\/]*)(:(\d+))?(\/\S*)$/) {
	return { 'mode' => 3, 'user' => $1, 'pass' => $2,
		 'host' => $3, 'port' => $5, 'path' => $6 };
	}
elsif ($dest =~ /^ftp:([^:]+):([^\@]+)\@([^:\/]*)(:(\d+))?(\/\S*)$/) {
	return { 'mode' => 4, 'user' => $1, 'pass' => $2,
		 'host' => $3, 'port' => $5, 'path' => $6 };
	}
elsif ($dest =~ /^([a-zA-Z0-9\.\-\_]+):(\/\S*)$/) {
	my ($hostname, $path) = ($1, $2);
	my $server = &get_managed_server_by("host", $hostname);
	$server || return undef;
	return { 'mode' => 2, 'id' => $server->{'id'}, 'path' => $path };
	}
else {
	return undef;
	}
}

# join_backup_destination(&dest)
# Converts a destination hash ref into a string, like vm2:3423423423:/backup
sub join_backup_destination
{
my ($dest) = @_;
if ($dest->{'mode'} == 0) {
	return "master:".$dest->{'path'};
	}
elsif ($dest->{'mode'} == 1) {
	return "host:".$dest->{'path'};
	}
elsif ($dest->{'mode'} == 2) {
	return "vm2:".$dest->{'id'}.":".$dest->{'path'};
	}
elsif ($dest->{'mode'} == 3) {
	return "ssh:".$dest->{'user'}.":".$dest->{'pass'}."\@".$dest->{'host'}.
	       ($dest->{'port'} ? ":".$dest->{'port'} : "").
	       $dest->{'path'};
	}
elsif ($dest->{'mode'} == 4) {
	return "ftp:".$dest->{'user'}.":".$dest->{'pass'}."\@".$dest->{'host'}.
	       ($dest->{'port'} ? ":".$dest->{'port'} : "").
	       $dest->{'path'};
	}
else {
	return undef;
	}
}

# nice_backup_destination(string|&dest)
# Convert a destination string into a human-readable format
sub nice_backup_destination
{
my ($dstr) = @_;
my $dest = ref($dstr) ? $dstr : &parse_backup_destination($dstr);
if ($dest->{'mode'} == 0) {
	return &text('bdest_mode0', $dest->{'path'});
	}
elsif ($dest->{'mode'} == 1) {
	return &text('bdest_mode1', $dest->{'path'});
	}
elsif ($dest->{'mode'} == 2) {
	my $server = &get_managed_server_by("id", $dest->{'id'});
	return &text('bdest_mode2', $server->{'host'}, $dest->{'path'});
	}
elsif ($dest->{'mode'} == 3) {
	return &text('bdest_mode3', $dest->{'user'}, $dest->{'host'},
				    $dest->{'path'});
	}
elsif ($dest->{'mode'} == 4) {
	return &text('bdest_mode4', $dest->{'user'}, $dest->{'host'},
				    $dest->{'path'});
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
my $mode = $dest ? $dest->{'mode'} : -1;
print &ui_table_row($text{'backups_def'},
    &ui_radio_table("backup_mode", $mode,
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
	       &show_backup_ssh_dest($mode == 3 ? $dest : { }, "ssh", 22) ],
	  [ 4, $text{'backups_mode4'},
	       &show_backup_ssh_dest($mode == 4 ? $dest : { }, "ftp", 21) ],
	]));

print &ui_hidden_table_end("backups");
}

# parse_default_backup_dest_table(&server, &in)
# Updates a server's backup_default key with details of the default 
# destination. Calls error on failure.
sub parse_default_backup_dest_table
{
my ($server, $in) = @_;
my $mode = $in->{'backup_mode'};
my $dest = $mode == -1 ? undef : { 'mode' => $mode };
if ($mode == 0) {
	$dest->{'path'} = $in->{'backup_masterdir'};
	$dest->{'path'} =~ /^\/\S+/ || &error($text{'backups_emode0'});
	}
elsif ($mode == 1) {
	$dest->{'path'} = $in->{'backup_hostdir'};
	$dest->{'path'} =~ /^\/\S+/ || &error($text{'backups_emode1'});
	}
elsif ($mode == 2) {
	$dest->{'path'} = $in->{'backup_vm2dir'};
	$dest->{'id'} = $in->{'backup_vm2'};
	$dest->{'path'} =~ /^\/\S+/ || &error($text{'backups_emode2'});
	}
elsif ($mode == 3) {
	my $err = &parse_backup_ssh_dest($dest, "ssh", $in);
	&error($err) if ($err);
	}
elsif ($mode == 4) {
	my $err = &parse_backup_ssh_dest($dest, "ftp", $in);
	&error($err) if ($err);
	}
$server->{'backup_default'} = $dest ? &join_backup_destination($dest) : undef;
}

# show_backup_ssh_dest(&destination, prefix, default-port)
# Returns HTML for entering SSH server details for a backup
sub show_backup_ssh_dest
{
my ($dest, $pfx, $defport) = @_;
my $noac = "autocomplete=off";
return "<table>".
       "<tr> <td><b>$text{'backups_'.$pfx.'host'}</b></td> ".
       "<td>".&ui_textbox($pfx."_host", $dest->{'host'}, 30)."</td> </tr>\n".
       "<tr> <td><b>$text{'backups_'.$pfx.'port'}</b></td> ".
       "<td>".&ui_opt_textbox($pfx."_port", $dest->{'port'}, 6,
			      $text{'default'}." ($defport)")."</td> </tr>\n".
       "<tr> <td><b>$text{'backups_'.$pfx.'user'}</b></td> ".
       "<td>".&ui_textbox($pfx."_user", $dest->{'user'}, 20,
			  0, undef, $noac)."</td> </tr>\n".
       "<tr> <td><b>$text{'backups_'.$pfx.'pass'}</b></td> ".
       "<td>".&ui_password($pfx."_pass", $dest->{'pass'}, 20,
			  0, undef, $noac)."</td> </tr>\n".
       "<tr> <td><b>$text{'backups_'.$pfx.'path'}</b></td> ".
       "<td>".&ui_textbox($pfx."_path", $dest->{'path'}, 40)."</td> </tr>\n".
       "</table>\n";
}

# parse_backup_ssh_dest(&destination, prefix, &in)
# Updates a destination hash based on input from a form generated by
# show_backup_ssh_dest. Returns undef on success, or an error message on
# failure.
sub parse_backup_ssh_dest
{
my ($dest, $pfx, $in) = @_;
$in->{$pfx."_host"} =~ /^\S+$/ || return $text{'backups_e'.$pfx.'host'};
gethostbyname($in->{$pfx."_host"}) || return $text{'backups_e'.$pfx.'host2'};
$dest->{'host'} = $in->{$pfx."_host"};

$in->{$pfx."_port_def"} || $in->{$pfx."_port"} =~ /^\d+$/ ||
	return $text{'backups_e'.$pfx.'port'};
$dest->{'port'} = $in->{$pfx."_port_def"} ? undef : $in->{$pfx."_port"};

$in->{$pfx."_user"} =~ /^[^\:\@ \t\r\n]+$/ ||
	return $text{'backups_e'.$pfx.'user'};
$dest->{'user'} = $in->{$pfx."_user"};

$in->{$pfx."_pass"} =~ /^[^\:\@ \t\r\n]*$/ ||
	return $text{'backups_e'.$pfx.'pass'};
$dest->{'pass'} = $in->{$pfx."_pass"};

$in->{$pfx."_path"} =~ /^\/\S*$/ ||
	return $text{'backups_e'.$pfx.'path'};
$dest->{'path'} = $in->{$pfx."_path"};

return undef;
}

# supports_backup(&server)
# Returns 1 if some system can be backed up
sub supports_backup
{
my ($server) = @_;
local $bfunc = "type_".$server->{'manager'}."_can_backup";
return defined(&$bfunc) && &$bfunc($server);
}

# virtualmin_ui_show_cron_time(name, &job, off-text)
# Returns HTML for a field for entering a cron time, or selecting a disabled
# option. Uses a popup for the complex time
sub virtualmin_ui_show_cron_time
{
return &theme_virtualmin_ui_show_cron_time(@_)
	if (defined(&theme_virtualmin_ui_show_cron_time));
local ($name, $job, $offmsg) = @_;
&foreign_require("cron", "cron-lib.pl");
local $rv;
local $mode = !$job ? 0 : $job->{'special'} ? 1 : 2;
local $complex = $mode == 2 ? &cron::when_text($job, 1) : undef;
local $button = "<input type=button onClick='cfield = form.${name}_complex; hfield = form.${name}_hidden; chooser = window.open(\"cron_chooser.cgi?complex=\"+escape(hfield.value), \"cronchooser\", \"toolbar=no,menubar=no,scrollbars=no,resizable=yes,width=800,height=400\"); chooser.cfield = cfield; window.cfield = cfield; chooser.hfield = hfield; window.hfield = hfield;' value=\"...\">\n";
local $hidden = $mode == 2 ?
	join(" ", $job->{'mins'}, $job->{'hours'},
		  $job->{'days'}, $job->{'months'}, $job->{'weekdays'}) : "";
return &ui_radio_table($name, $mode,
	 [ $offmsg ? ( [ 0, $offmsg ] ) : ( ),
	   $cron::config{'vixie_cron'} ? (
	   [ 1, $text{'cron_special'},
		   &ui_select($name."_special", $job->{'special'},
		      [ map { [ $_, $cron::text{'edit_special_'.$_} ] }
			    ('hourly', 'daily', 'weekly', 'monthly', 'yearly')
		      ]) ] ) : ( ),
	   [ 2, $text{'cron_complex'},
		   &ui_textbox($name."_complex", $complex, 40, 0, undef,
				  "readonly=true")." ".$button ],
	 ]).&ui_hidden($name."_hidden", $hidden);
}

# virtualmin_ui_parse_cron_time(name, &job, &in)
# Updates the given job object with the selected schedule. Return 1 if a
# schedule was chosen, 0 if not.
sub virtualmin_ui_parse_cron_time
{
return &theme_virtualmin_ui_parse_cron_time(@_)
	if (defined(&theme_virtualmin_ui_parse_cron_time));
local ($name, $job, $in) = @_;
if ($in{$name} == 0) {
	# Disabled
	return 0;
	}
else {
	&copy_cron_sched_keys({ }, $job);
	if ($in{$name} == 1) {
		# Simple time
		$job->{'special'} = $in{$name."_special"};
		}
	else {
		# Complex time
		local @j = split(/\s+/, $in{$name."_hidden"});
		@j == 5 || &error($text{'cron_ehidden'});
		$job->{'mins'} = $j[0];
		$job->{'hours'} = $j[1];
		$job->{'days'} = $j[2];
		$job->{'months'} = $j[3];
		$job->{'weekdays'} = $j[4];
		}
	return 1;
	}
}

# execute_backup(&backup)
# Run a backup of multiple virtual systems, to the destination set in the 
# backup or on the host system(s). Returns a hash ref mapping system IDs to
# status hashes with keys: 'ok', 'msg', 'size', 'dest'
sub execute_backup
{
my ($backup) = @_;

# Find the systems
&$first_print($text{'brun_finding'});
my %want = map { $_, 1 } split(/\s+/, $backup->{'servers'});
my @servers = grep { ($want{$_->{'id'}} || $want{'*'}) &&
		     &supports_backup($_) }
		   &list_available_managed_servers_sorted();
if ($backup->{'owner'}) {
	# Limit to systems owned by the backup's owner
	my $owner = &get_system_owner($backup->{'owner'});
	if ($owner) {
		my %oids = split(/\s+/, $owner->{'acl'}->{'servers'});
		@servers = grep { $oids{$_->{'id'}} } @servers;
		}
	}
&$second_print(&text('brun_found', scalar(@servers)));

# Work out the destination for each, perhaps from the host
&$first_print($text{'brun_findingdests'});
my %rv;
my %destmap;
foreach my $s (@servers) {
	my $destdir;
	if ($backup->{'dest'}) {
		# Use dir in backup
		$destdir = $backup->{'dest'};
		}
	else {
		# From host system, if we can find it
		my $vhost = &get_parent_server($s);
		$destdir = $vhost->{'dest'};
		if (!$destdir) {
			$rv{$s->{'id'}} = {
				'ok' => 1,
				'msg' => &text('brun_evhost', $vhost->{'host'}),
				};
			next;
			}
		if ($backup->{'owner'}) {
			$destdir .= '/'.$backup->{'owner'};
			}
		}
	$destmap{$s->{'id'}} = $destdir."/".$s->{'host'}.".tar.gz";
	}

# Exclude failures
@servers = grep { !$rv{$_->{'id'}} } @servers;
&$second_print(&text('brun_founddests', scalar(@servers)));

if ($backup->{'parallel'}) {
	# Run each of them in parallel
	my @prv = &parallel_server_function(\@servers,
			sub { my ($s) = @_;
			      return &execute_system_backup(
					$s, $destmap{$s->{'id'}},
					$backup->{'shutdown'}
					);
			    });
	for(my $i=0; $i<@prv; $i++) {
		my $s = $servers[$i];
		$rv{$s->{'id'}} = $prv[$i]->[0];
		}
	}
else {
	# Do them one by one
	foreach my $s (@servers) {
		my $srv = &execute_system_backup($s, $destmap{$s->{'id'}},
						 $backup->{'shutdown'});
		$rv{$s->{'id'}} = $srv;
		}
	}

return \%rv;
}

# execute_system_backup(&server, destination, shutdown?)
# Backup one virtual system to the given destination. Returns a status hash
# ref, with keys 'ok', 'msg', 'size'
sub execute_system_backup
{
my ($server, $dest, $shutdown) = @_;

# Check if running, and if so shut down
my $was_up = 0;
if ($server->{'status'} ne 'down' && $shutdown) {
	&$first_print(&text('brun_shutdown', $server->{'host'}));
	$err = &shutdown_server($server);
	if ($err) {
		return { 'ok' => 0,
			 'msg' => &text('smove_shutfailed', $err) };
		}
	$s->{'status'} = 'down';	# Assume it worked
	$was_up = 1;
	&$second_print($text{'create_done'});
	}

# Call the type-specific backup function
&$first_print(&text('brun_backing', $server->{'host'},
		    &nice_backup_destination($dest)));
&$indent_print();
my $bfunc = "type_".$server->{'manager'}."_backup_system";
my $rv = &$bfunc($server, $dest, $shutdown);
&$outdent_print();
if ($rv->{'ok'}) {
	&$second_print(&text('brun_backed', &nice_size($rv->{'size'})));
	}
else {
	&$second_print(&text('brun_failed', $rv->{'msg'}));
	}

# Start up again
if ($was_up) {
	&$first_print(&text('brun_startup', $server->{'host'}));
	&startup_server($server);
	&$second_print($text{'create_done'});
	}

return $rv;
}

# send_to_backup_dest(&server, file, &destination)
# Send some file to a backup destination. Returns an error on failure, undef on
# success.
sub send_to_backup_dest
{
my ($server, $file, $dest) = @_;
if ($dest->{'mode'} == 0) {
	# Download to Cloudmin master
	return &get_file_from_server($server, $file, $dest->{'path'});
	}
elsif ($dest->{'mode'} == 1) {
	# To host system, which makes no sense!
	return "send_to_backup_dest called with crazy mode $dest->{'mode'}";
	}
elsif ($dest->{'mode'} == 2) {
	# To some other Cloudmin system
	my $destserver = &get_managed_server_by("id", $dest->{'id'});
	$destserver || return "No Cloudmin system with ID $dest->{'id'} exists";
	return &transfer_file_between_servers($server, $destserver,
					      $file, $dest->{'path'}, 0);
	}
elsif ($dest->{'mode'} == 3) {
	# Send via SSH (using a fake server object)
	my $destserver = { 'id' => &server_id(),
			   'ssh_protocol' => 2,
			   'host' => $dest->{'host'},
			   'ssh_user' => $dest->{'user'},
			   'ssh_pass' => $dest->{'pass'},
			   'ssh_port' => $dest->{'port'},
			   'status' => 'nowebmin',
			  };
	return &transfer_file_between_servers($server, $destserver,
					      $file, $dest->{'path'}, 0);
	}
elsif ($dest->{'mode'} == 4) {
	# Send via FTP, using ftp command run in wrapper
	if (!&has_command_on_server($server, "ftp")) {
		return "Missing ftp command";
		}
	my $err = &put_file_to_server($server,
			"$module_root_directory/pty.pl", "/tmp/pty.pl");
	if ($err) {
		return "Failed to copy pty.pl : $err";
		}
	my $ftpin = &tempname_on_server($server);
	my $ftpdata = $dest->{'user'}."\n".
		      $dest->{'pass'}."\n".
		      "put $file $dest->{'path'}\n".
		      "quit\n";
	my $err = &put_file_data_to_server($server, $ftpdata, $ftpin);
	if ($err) {
		return "Failed to copy FTP login details : $err";
		}
	my ($out, $ex, $err) = &execute_command_on_server($server,
		"perl /tmp/pty.pl ftp ".quotemeta($dest->{'host'}).
		" 2>&1 <$ftpin");
	&delete_file_on_server($server, $ftpin);
	return $err ? $err : $ex ? "FTP upload failed : $out" : undef;
	}
else {
	return "Unknown destination mode $dest->{'mode'}";
	}
}

1;

