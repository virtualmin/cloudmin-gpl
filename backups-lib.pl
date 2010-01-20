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
my @servers = grep { &supports_backup($_) } &list_managed_servers();
if ($backup->{'servers'} eq '*') {
	if ($backup->{'owner'}) {
		# Limit to backup's owner
		my $owner = &get_system_owner($backup->{'owner'});
		my %osys = map { $_, 1 }
				split(/\s+/, $owner->{'acl'}->{'servers'});
		@servers = grep { $osys{$_->{'id'}} } @servers;
		}
	return @servers;
	}
else {
	my %sids = map { $_, 1 } split(/\s+/, $backup->{'servers'});
	return grep { $sids{$_->{'id'}} } @servers;
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
&lock_file($backup->{'file'});
&write_file($backup->{'file'}, $backup);
&unlock_file($backup->{'file'});

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
	&lock_file(&cron::cron_file($job));
	&cron::change_cron_job($job);
	&unlock_file(&cron::cron_file($job));
	}
elsif ($backup->{'enabled'} && !$job) {
	# Create cron job
	$job = { 'user' => 'root',
		 'active' => 1,
		 'command' => $cmd };
	&copy_cron_sched_keys($backup, $job);
	&lock_file(&cron::cron_file($job));
	&cron::create_cron_job($job);
	&unlock_file(&cron::cron_file($job));
	}
elsif (!$backup->{'enabled'} && $job) {
	# Delete cron job
	&lock_file(&cron::cron_file($job));
	&cron::delete_cron_job($job);
	&unlock_file(&cron::cron_file($job));
	}
&cron::create_wrapper($backup_cron_cmd, $module_name, "backup.pl");
}

# delete_backup(&backup)
# Delete one scheduled backup, and its cron job
sub delete_backup
{
my ($backup) = @_;
&unlink_logged($backup->{'file'});

# Delete cron too
&foreign_require("cron", "cron-lib.pl");
my $cmd = $backup_cron_cmd." --id ".$backup->{'id'};
my ($job) = &find_server_manager_cron_job($cmd);
if ($job) {
	&lock_file(&cron::cron_file($job));
	&cron::delete_cron_job($job);
	&unlock_file(&cron::cron_file($job));
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
	if ($1 == 0) {
		return { 'mode' => 0, 'path' => $2 };
		}
	else {
		return { 'mode' => 2, 'id' => $1, 'path' => $2 };
		}
	}
elsif ($dest =~ /^ssh:\/*([^:]+):([^:\/]+)\@([^:\/]*)(:(\d+))?(\/\S*)$/) {
	return { 'mode' => 3, 'user' => $1, 'pass' => $2,
		 'host' => $3, 'port' => $5, 'path' => $6 };
	}
elsif ($dest =~ /^ftp:\/*([^:]+):([^:\/]+)\@([^:\/]*)(:(\d+))?(\/\S*)$/) {
	return { 'mode' => 4, 'user' => $1, 'pass' => $2,
		 'host' => $3, 'port' => $5, 'path' => $6 };
	}
elsif ($dest =~ /^([a-zA-Z0-9\.\-\_]+):(\/\S*)$/) {
	my ($hostname, $path) = ($1, $2);
	my $server = &get_managed_server_by("host", $hostname);
	$server || return undef;
	if ($server->{'id'} == 0) {
		return { 'mode' => 0, 'path' => $path };
		}
	else {
		return { 'mode' => 2, 'id' => $server->{'id'},'path' => $path };
		}
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

# normalize_backup_destination(deststr)
# Converts a backup destination string into a standard format, if possible.
sub normalize_backup_destination
{
my ($deststr) = @_;
my $dest = &parse_backup_destination($deststr);
return $dest ? &join_backup_destination($dest) : $deststr;
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
print &ui_table_row(&hlink($text{'backups_def'}, "backups_def"),
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
		  [ map { [ $_->{'id'}, $_->{'short_host'} ] } @servers ]).
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

$in->{$pfx."_user"} =~ /^[^\: \t\r\n]+$/ ||
	return $text{'backups_e'.$pfx.'user'};
$dest->{'user'} = $in->{$pfx."_user"};

$in->{$pfx."_pass"} =~ /^[^\:\/ \t\r\n]*$/ ||
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
my $bfunc = "type_".$server->{'manager'}."_can_backup";
return defined(&$bfunc) && &$bfunc($server);
}

# virtualmin_ui_show_cron_time(name, &job, off-text)
# Returns HTML for a field for entering a cron time, or selecting a disabled
# option. Uses a popup for the complex time
sub virtualmin_ui_show_cron_time
{
return &theme_virtualmin_ui_show_cron_time(@_)
	if (defined(&theme_virtualmin_ui_show_cron_time));
my ($name, $job, $offmsg) = @_;
&foreign_require("cron", "cron-lib.pl");
my $rv;
my $mode = !$job ? 0 : $job->{'special'} ? 1 : 2;
my $complex = $mode == 2 ? &cron::when_text($job, 1) : undef;
my $button = "<input type=button onClick='cfield = form.${name}_complex; hfield = form.${name}_hidden; chooser = window.open(\"cron_chooser.cgi?complex=\"+escape(hfield.value), \"cronchooser\", \"toolbar=no,menubar=no,scrollbars=no,resizable=yes,width=800,height=400\"); chooser.cfield = cfield; window.cfield = cfield; chooser.hfield = hfield; window.hfield = hfield;' value=\"...\">\n";
my $hidden = $mode == 2 ?
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
my ($name, $job, $in) = @_;
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
		my @j = split(/\s+/, $in{$name."_hidden"});
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
my $start = time();

# Find the systems, and make sure their hosts are up
my %rv;
&$first_print($text{'brun_finding'});
my @servers = &get_backup_servers($backup);
foreach my $s (@servers) {
	if ($s->{'status'} eq 'nohost') {
		$rv{$s->{'id'}} = {
			'ok' => 0,
			'msg' => &text('brun_ehostdown'),
			};
		}
	}
@servers = grep { !$rv{$_->{'id'}} } @servers;
&$second_print(&text('brun_found', scalar(@servers)));

# Work out the destination for each, perhaps from the host
&$first_print($text{'brun_findingdests'});
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
		$destdir = $vhost->{'backup_default'};
		if (!$destdir) {
			$rv{$s->{'id'}} = {
				'ok' => 0,
				'msg' => &text('brun_evhost', $vhost->{'host'}),
				};
			next;
			}
		if ($backup->{'owner'}) {
			$destdir .= '/'.$backup->{'owner'};
			}
		}
	$destmap{$s->{'id'}} = &backup_strftime($destdir).
				"/".$s->{'host'}.".".&get_backup_extension($s);
	}

# If backup is by an owner, check if he is over his backup space
if ($backup->{'owner'}) {
	my $limits = &get_owner_limits($backup->{'owner'});
	if ($limits && $limits->{'max_space'} &&
	    $limits->{'space'} >= $limits->{'max_space'}) {
		foreach my $s (@servers) {
			$rv{$s->{'id'}} ||= {
				'ok' => 0,
				'msg' => &text('brun_espace',
					    &nice_size($limits->{'max_space'})),
				};
			}
		}
	}

# Exclude failures
@servers = grep { !$rv{$_->{'id'}} } @servers;
&$second_print(&text('brun_founddests', scalar(@servers)));

if ($backup->{'parallel'}) {
	# Run each of them in parallel. If capturing output, add it all
	# from the sub-processes when they complete.
	my @prv = &parallel_server_function(\@servers,
			sub { my ($s) = @_;
			      $capture_print = undef;
			      my $r = &execute_system_backup(
					$s, $destmap{$s->{'id'}},
					$backup->{'shutdown'},
					$backup->{'owner'},
					);
			      &save_backup_log($s, $destmap{$s->{'id'}}, $r,
					       $backup, $start);
			      $r->{'capture'} = $capture_print;
			      return $r;
			    });
	for(my $i=0; $i<@prv; $i++) {
		my $s = $servers[$i];
		$rv{$s->{'id'}} = $prv[$i]->[0];
		if ($capture_print && $prv[$i]->[0]) {
			$capture_print .= $prv[$i]->[0]->{'capture'};
			}
		}
	}
else {
	# Do them one by one
	foreach my $s (@servers) {
		my $srv = &execute_system_backup($s, $destmap{$s->{'id'}},
						 $backup->{'shutdown'},
						 $backup->{'owner'});
		$rv{$s->{'id'}} = $srv;
		&save_backup_log($s, $destmap{$s->{'id'}}, $srv,
				 $backup, $start);
		}
	}

# If backup was by a system owner, re-compute his usage
if ($backup->{'owner'}) {
	&compute_backup_space();
	}

# Add in destinations to results
foreach my $s (@servers) {
	$rv{$s->{'id'}}->{'dest'} = $destmap{$s->{'id'}};
	}

return \%rv;
}

# execute_system_backup(&server, destination, shutdown?, owner-name)
# Backup one virtual system to the given destination. Returns a status hash
# ref, with keys 'ok', 'msg', 'size'
sub execute_system_backup
{
my ($server, $dest, $shutdown, $owner) = @_;

# Check if running, and if so shut down
my $was_up = 0;
if ($server->{'status'} ne 'down' && $shutdown) {
	&$first_print(&text('brun_shutdown', $server->{'host'}));
	$err = &shutdown_server($server);
	if ($err) {
		return { 'ok' => 0,
			 'msg' => &text('smove_shutfailed', $err) };
		}
	$server->{'status'} = 'down';	# Assume it worked
	$was_up = 1;
	&save_managed_server($server);
	&$second_print($text{'create_done'});
	}

# Call the type-specific backup function
&$first_print(&text('brun_backing', $server->{'host'},
		    &nice_backup_destination($dest)));
&$indent_print();
my $bfunc = "type_".$server->{'manager'}."_backup_system";
my $rv = &$bfunc($server, $dest, $shutdown, $owner);
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
	&check_server_status($server, 0, 1);
	&save_managed_server($server);
	&$second_print($text{'create_done'});
	}

return $rv;
}

# get_backup_extension(&server)
# Returns an extension for backup files, defaulting to tar.gz
sub get_backup_extension
{
my ($server) = @_;
my $efunc = "type_".$server->{'manager'}."_backup_extension";
return "tar.gz" if (!defined(&$efunc));
return &$efunc($server);
}

# get_backup_dest_server(&dest, &vhost)
# Given a backup destination hash ref, return a server object for it if
# possible (which it isn't for FTP)
sub get_backup_dest_server
{
my ($dest, $vhost) = @_;
if ($dest->{'mode'} == 0) {
	return &get_this_managed_server();
	}
elsif ($dest->{'mode'} == 1) {
	return $vhost;
	}
elsif ($dest->{'mode'} == 2) {
	return &get_managed_server_by("id", $dest->{'id'});
	}
elsif ($dest->{'mode'} == 3) {
	return { 'id' => &server_id(),
		 'ssh_protocol' => 2,
		 'host' => $dest->{'host'},
		 'ssh_user' => $dest->{'user'},
		 'ssh_pass' => $dest->{'pass'},
		 'ssh_port' => $dest->{'port'},
		 'status' => 'nowebmin', };
	}
else {
	return undef;
	}
}

# send_to_backup_dest(&server, file, &destination)
# Send some file to a backup destination. Returns an error on failure, undef on
# success.
sub send_to_backup_dest
{
my ($server, $file, $dest) = @_;
my $destdir = $dest->{'path'};
$destdir =~ s/\/([^\/]+)$//;
my $destserver = &get_backup_dest_server($dest);
if ($dest->{'mode'} == 0) {
	# Download to Cloudmin master
	if (!-d $destdir) {
		&make_dir($destdir, 0700, 1) ||
			return &text('brun_emkdir', "$!");
		}
	return &get_file_from_server($server, $file, $dest->{'path'});
	}
elsif ($dest->{'mode'} == 1) {
	# To host system, which makes no sense!
	return "send_to_backup_dest called with crazy mode $dest->{'mode'}";
	}
elsif ($dest->{'mode'} == 2) {
	# To some other Cloudmin system
	$destserver || return "No Cloudmin system with ID $dest->{'id'} exists";
	my $mkerr = &create_backup_dest_dir($destserver, $dest->{'path'});
	return &text('brun_emkdir', $mkerr) if ($mkerr);
	return &transfer_file_between_servers($server, $destserver,
					      $file, $dest->{'path'}, 0, 1);
	}
elsif ($dest->{'mode'} == 3) {
	# Send via SSH (using a fake server object)
	my $mkerr = &create_backup_dest_dir($destserver, $dest->{'path'});
	return &text('brun_emkdir', $mkerr) if ($mkerr);
	return &transfer_file_between_servers($server, $destserver,
					      $file, $dest->{'path'}, 0);
	}
elsif ($dest->{'mode'} == 4) {
	# Send via FTP, using our little FTP uploader
	my $err = &put_file_to_server($server,
		"$module_root_directory/ftpupload.pl", "/tmp/ftpupload.pl");
	if ($err) {
		return "Failed to copy ftpupload.pl : $err";
		}
	my ($out, $ex, $err) = &execute_command_on_server($server,
		"perl /tmp/ftpupload.pl ".
		quotemeta($dest->{'user'})." ".
		quotemeta($dest->{'pass'})." ".
		quotemeta($dest->{'host'})." ".
		($dest->{'port'} || 21)." ".
		quotemeta($dest->{'path'})." ".
		quotemeta($file)." 2>&1");
	return $err ? $err : $ex ? "FTP upload failed : $out" : undef;
	}
else {
	return "Unknown destination mode $dest->{'mode'}";
	}
}

# create_backup_dest_dir(&server, path)
# If needed, create the directory for a backup destination. Returns undef
# if OK, or an error on failure.
sub create_backup_dest_dir
{
my ($server, $path) = @_;
my $dir = $path;
$dir =~ s/\/([^\/]+)$//;
my $err = &make_dir_on_server($server, $dir, 0700, 1);
my ($out, $ex, $err) = &execute_command_on_server($server,
			"mkdir -p ".quotemeta($dir));
return $err ? $err : $ex ? $out : undef;
}

# execute_restore(&backup)
# Restores a backup of one or more virtual systems, and returns a map from
# system IDs to status hashes in the same format as execute_backup
sub execute_restore
{
my ($backup) = @_;

# Find the systems, and make sure their hosts are up
my %rv;
&$first_print($text{'rrun_finding'});
my @servers = &get_backup_servers($backup);
foreach my $s (@servers) {
	if ($s->{'status'} eq 'nohost') {
		$rv{$s->{'id'}} = {
			'ok' => 0,
			'msg' => &text('brun_ehostdown'),
			};
		}
	}
@servers = grep { !$rv{$_->{'id'}} } @servers;
&$second_print(&text('rrun_found', scalar(@servers)));

# Work out the source for each, based on the given destination spec
&$first_print($text{'rrun_findingdests'});
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
		$destdir = $vhost->{'backup_default'};
		if (!$destdir) {
			$rv{$s->{'id'}} = {
				'ok' => 0,
				'msg' => &text('brun_evhost', $vhost->{'host'}),
				};
			next;
			}
		if ($backup->{'owner'}) {
			$destdir .= '/'.$backup->{'owner'};
			}
		}
	$destmap{$s->{'id'}} = &backup_strftime($destdir).
			        "/".$s->{'host'}.".".&get_backup_extension($s);
	}

# Exclude failures
@servers = grep { !$rv{$_->{'id'}} } @servers;
&$second_print(&text('rrun_founddests', scalar(@servers)));

if ($backup->{'parallel'}) {
	# Run each of them in parallel
	my @prv = &parallel_server_function(\@servers,
			sub { my ($s) = @_;
			      my $r = &execute_system_restore(
					$s, $destmap{$s->{'id'}},
					);
			      return $r;
			    });
	for(my $i=0; $i<@prv; $i++) {
		my $s = $servers[$i];
		$rv{$s->{'id'}} = $prv[$i]->[0];
		}
	}
else {
	# Do them one by one
	foreach my $s (@servers) {
		my $srv = &execute_system_restore($s, $destmap{$s->{'id'}});
		$rv{$s->{'id'}} = $srv;
		}
	}

# Add in destinations to results
foreach my $s (@servers) {
	$rv{$s->{'id'}}->{'dest'} = $destmap{$s->{'id'}};
	}

return \%rv;

}

# execute_system_restore(&server, dest)
# Restore a backup of a single system, and return a status hash ref
sub execute_system_restore
{
my ($server, $dest) = @_;

# Check if running, and if so shut down
my $was_up = 0;
if ($server->{'status'} ne 'down') {
	&$first_print(&text('rrun_shutdown', $server->{'host'}));
	$err = &shutdown_server($server, 1);
	if ($err) {
		return { 'ok' => 0,
			 'msg' => &text('smove_shutfailed', $err) };
		}
	$server->{'status'} = 'down';	# Assume it worked
	$was_up = 1;
	&save_managed_server($server);
	&$second_print($text{'create_done'});
	}

# Call the type-specific backup function
&$first_print(&text('rrun_restoring', $server->{'host'},
		    &nice_backup_destination($dest)));
&$indent_print();
my $bfunc = "type_".$server->{'manager'}."_restore_system";
my $rv = &$bfunc($server, $dest);
&$outdent_print();
if ($rv->{'ok'}) {
	&$second_print($text{'rrun_restored'});
	}
else {
	&$second_print(&text('rrun_failed', $rv->{'msg'}));
	}

# Start up again
if ($was_up) {
	&$first_print(&text('rrun_startup', $server->{'host'}));
	&startup_server($server);
	&check_server_status($server, 0, 1);
	&save_managed_server($server);
	&$second_print($text{'create_done'});
	}

return $rv;
}

# list_backup_logs([&server])
# Return a list of all logged server backups, or just those for one system
sub list_backup_logs
{
my ($server) = @_;
my @rv;
opendir(LOGDIR, $backup_log_dir);
foreach my $f (readdir(LOGDIR)) {
	my ($time, $id) = split(/_/, $f, 2);
	next if ($time eq '' || $id eq '');
	next if ($server && $id ne $server->{'id'});
	my $log = &get_backup_log($f);
	if ($log) {
		push(@rv, $log);
		}
	}
closedir(LOGDIR);
return @rv;
}

# get_backup_log(id)
# Returns the hash ref for a backup log
sub get_backup_log
{
my ($id) = @_;
my %log;
&read_file("$backup_log_dir/$id", \%log) || return undef;
return \%log;
}

# save_backup_log(&server, server-dest, &result, &backup, start-time)
# Log the backup of one virtual system
sub save_backup_log
{
my ($server, $dest, $rv, $backup, $time) = @_;
if (!-d $backup_log_dir) {
	&make_dir($backup_log_dir, 0700);
	}
my $log = { 'time' => $time,
	    'server' => $server->{'id'},
	    'host' => $server->{'host'},
	    'dest' => $dest,
	    'ok' => $rv->{'ok'},
	    'size' => $rv->{'size'},
	    'msg' => $rv->{'msg'},
	    'base_dest' => $backup->{'dest'},
	    'backup' => $backup->{'id'},
	    'owner' => $backup->{'owner'} };
$log->{'id'} = $log->{'time'}.'_'.$server->{'id'};
&write_file("$backup_log_dir/$log->{'id'}", $log);
}

# delete_backup_log(&log)
# Delete a backup log entry
sub delete_backup_log
{
my ($log) = @_;
&unlink_file("$backup_log_dir/$log->{'id'}");
}

# tar_backup_system(&server, dest, root-dir, owner)
# Backup a virtual system by tarring up its filesystem on the host. Works
# with OpenVZ, Vservers and Zones.
sub tar_backup_system
{
my ($server, $deststr, $root, $owner) = @_;
my $vhost = &get_parent_server($server);
my $dest = &parse_backup_destination($deststr);
my $destserver = &get_backup_dest_server($dest, $vhost);
if ($destserver && $destserver->{'id'} eq $vhost->{'id'}) {
	$dest->{'mode'} = 1;
	}

# Pick a temp file on the host system, if needed
my $tarfile;
if ($dest->{'mode'} == 1) {
	# Target is on host already
	$tarfile = $dest->{'path'};
	my $mkerr = &create_backup_dest_dir($vhost, $tarfile);
	if ($mkerr) {
		return { 'ok' => 0,
			 'msg' => &text('brun_emkdir', $mkerr) };
		}
	}
elsif ($dest->{'mode'} == 2 || $dest->{'mode'} == 0) {
	# Transferring directly to dest host
	if (!$destserver) {
		return { 'ok' => 0, 'msg' => $text{'brun_edestserver'} };
		}
	$tarfile = undef;
	}
else {
	# Pick temp file for tar
	$tarfile = &tempname_on_server($vhost, $server->{'host'}.'.tar.gz');
	if (!$tarfile) {
		return { 'ok' => 0,
			 'msg' => &text('brun_etemp', $vhost->{'host'}) };
		}
	}

my $size;
if ($tarfile) {
	# Tar up the filesystem
	&$first_print(&text('brun_tarring', $server->{'host'}, $root));
	my ($out, $ex, $err) = &execute_command_on_server($vhost,
		"cd ".quotemeta($root)." && ".
		(&tar_supports_gzip($vhost) ?
			"tar czf ".quotemeta($tarfile)." ." :
			"tar cf - . | gzip -c >".quotemeta($tarfile)));
	if ($ex || $err) {
		$err = $out if ($ex);
		return { 'ok' => 0,
			 'msg' => &text('brun_etar',
					"<tt>".&html_escape($out)."</tt>") };
		}
	&remote_finished();

	# Get the size
	my @st = &stat_file_on_server($vhost, $tarfile);
	if (!@st || !$st[7]) {
		return { 'ok' => 0,
			 'msg' => &text('brun_estat', $tarfile) };
		}
	$size = $st[7];

	# Transfer to the destination, if needed
	if ($dest->{'mode'} != 1) {
		# Check if size would exceed limits
		my $err = &check_backup_dest_size($server, $dest,
						  $size, $owner);

		# Send via SCP or FTP
		if (!$err) {
			&$first_print(&text('brun_sending', $server->{'host'},
					    &nice_backup_destination($dest)));
			$err = &send_to_backup_dest($vhost, $tarfile, $dest);
			}

		# Delete from host
		&delete_file_on_server($vhost, $tarfile);

		if ($err) {
			return { 'ok' => 0,
				 'msg' => &text('brun_esend', $err) };
			}
		}
	}
else {
	# Tar directly to dest system
	&$first_print(&text('brun_tarring4', $server->{'host'}, $root,
					     $destserver->{'host'}));
	my $tarcmd = "cd ".quotemeta($root)." && ".
		     (&tar_supports_gzip($vhost) ?
		      "tar czf - ." : "tar cf - . | gzip -c");
	my $err = &pipe_command_to_server($vhost, $destserver, $tarcmd,
					  $dest->{'path'});
	if ($err) {
		return { 'ok' => 0,
			 'msg' => &text('brun_etar',
					"<tt>".&html_escape($err)."</tt>") };
		}
	&remote_finished();

	# Get the resulting size
	my @st = &stat_file_on_server($destserver, $dest->{'path'});
	if (!@st || !$st[7]) {
		return { 'ok' => 0,
			 'msg' => &text('brun_estat', $tarfile) };
		}
	$size = $st[7];
	}

# Return status
return { 'ok' => 1,
	 'size' => $size };
}

# tar_restore_system(&server, dest, root-dir)
# Restore a virtual system by un-tarring up its filesystem on the host. Works
# with OpenVZ, Vservers and Zones.
sub tar_restore_system
{
my ($server, $deststr, $root) = @_;
my $vhost = &get_parent_server($server);
my $dest = &parse_backup_destination($deststr);
my $destserver = &get_backup_dest_server($dest, $vhost);
if ($destserver && $destserver->{'id'} eq $vhost->{'id'}) {
	$dest->{'mode'} = 1;
	}

# Pick a temp file on the host system, if needed
my $tarfile;
if ($dest->{'mode'} == 1) {
	# Source file is on host already
	$tarfile = $dest->{'path'};
	}
elsif ($dest->{'mode'} == 2 || $dest->{'mode'} == 0) {
	# Transferring directly from source host
	$tarfile = undef;
	}
else {
	# Pick temp file for tar
	$tarfile = &tempname_on_server($vhost, $server->{'host'}.'.tar.gz');
	if (!$tarfile) {
		return { 'ok' => 0,
			 'msg' => &text('brun_etemp', $vhost->{'host'}) };
		}
	}

my $size;
my $tarerr;
if ($tarfile) {
	# Copy in the tar.gz backup file, if needed
	if ($dest->{'mode'} != 1) {
		&$first_print(&text('rrun_getting', $server->{'host'},
					    &nice_backup_destination($dest)));
		my $err = &get_from_backup_dest($vhost, $tarfile, $dest);
		if ($err) {
			return { 'ok' => 0,
				 'msg' => &text('rrun_eget', $err) };
			}
		}
	my @st = &stat_file_on_server($vhost, $tarfile);
	if (!@st || !$st[7]) {
		return { 'ok' => 0,
			 'msg' => &text('rrun_estat', $tarfile) };
		}
	$size = $st[7];

	# Un-tar the filesystem
	&$first_print(&text('rrun_untarring', $server->{'host'}, $root));
	my ($out, $ex, $err) = &execute_command_on_server($vhost,
		"cd ".quotemeta($root)." && ".
		"rm -rf * && ".
		(&tar_supports_gzip($vhost) ?
			"tar xpzf ".quotemeta($tarfile) :
			"gunzip -c ".quotemeta($tarfile)." | tar xpf -"));
	if ($ex || $err) {
		$err = $out if ($ex);
		$tarerr = &text('rrun_etar', "<tt>".&html_escape($out)."</tt>");
		}
	&remote_finished();

	# Remove the temp file if needed
	if ($dest->{'mode'} != 1) {
		&delete_file_on_server($vhost, $tarfile);
		}
	}
else {
	# Un-tar directly from the source system
	&$first_print(&text('rrun_untarring4', $server->{'host'}, $root,
					       $destserver->{'host'}));
	my $tarcmd = "cd ".quotemeta($root)." && ".
		     "rm -rf * && ".
		     (&tar_supports_gzip($vhost) ?
			   "tar xpzf - " :
			   "gunzip -c | tar xpf -");
	my $err = &pipe_command_from_server($destserver, $vhost, $tarcmd,
					    $dest->{'path'});
	if ($err) {
		return { 'ok' => 0,
			 'msg' => &text('rrun_etar',
					"<tt>".&html_escape($err)."</tt>") };
		}
	&remote_finished();

	# Get the source file size
	my @st = &stat_file_on_server($destserver, $dest->{'path'});
	if (!@st || !$st[7]) {
		return { 'ok' => 0,
			 'msg' => &text('brun_estat', $tarfile) };
		}
	$size = $st[7];
	}

# Return status
if ($tarerr) {
	return { 'ok' => 0, 'msg' => $tarerr };
	}
else {
	return { 'ok' => 1, 'size' => $size };
	}
}

# get_from_backup_dest(&server, file, &destination)
# Get some file from a backup destination and put it on the given server.
# Returns an error on failure, undef on success.
sub get_from_backup_dest
{
my ($server, $file, $dest) = @_;
if ($dest->{'mode'} == 0) {
	# Upload from Cloudmin master
	return &put_file_to_server($server, $dest->{'path'}, $file);
	}
elsif ($dest->{'mode'} == 1) {
	# From host system, which makes no sense!
	return "get_from_backup_dest called with crazy mode $dest->{'mode'}";
	}
elsif ($dest->{'mode'} == 2) {
	# From some other Cloudmin system
	my $destserver = &get_managed_server_by("id", $dest->{'id'});
	$destserver ||
		return "No Cloudmin system with ID $dest->{'id'} exists";
	return &transfer_file_between_servers($destserver, $server,
					      $dest->{'path'}, $file, 0, 1);
	}
elsif ($dest->{'mode'} == 3) {
	# Get via SSH (using a fake server object)
	my $destserver = { 'id' => &server_id(),
			   'ssh_protocol' => 2,
			   'host' => $dest->{'host'},
			   'ssh_user' => $dest->{'user'},
			   'ssh_pass' => $dest->{'pass'},
			   'ssh_port' => $dest->{'port'},
			   'status' => 'nowebmin',
			  };
	return &transfer_file_between_servers($destserver, $server,
					      $dest->{'path'}, $file, 0);
	}
elsif ($dest->{'mode'} == 4) {
	# Download via FTP, using wget command
	if (!&has_command_on_server($server, "wget")) {
		return "Missing wget command";
		}
	my $cmd = "wget -O ".quotemeta($file)." ".
		  "ftp://".quotemeta($dest->{'user'}).":".
		  	   quotemeta($dest->{'pass'})."\@".
		  $dest->{'host'}.($dest->{'port'} ? ":$dest->{'port'}" : "").
		  "/".quotemeta($dest->{'path'});
	my ($out, $ex, $err) = &execute_command_on_server($server, $cmd);
	return $err ? $err : $ex ? "FTP download failed : $out" : undef;
	}
else {
	return "Unknown destination mode $dest->{'mode'}";
	}
}

# delete_backup_dest(&dest, &server)
# Delete the file at some backup destination, return undef if OK, or an error
# message on failure.
sub delete_backup_dest
{
my ($dest, $server) = @_;
if ($dest->{'mode'} == 0) {
	# Just remove locally
	return &unlink_file($dest->{'path'}) ? undef : "$!";
	}
elsif ($dest->{'mode'} == 1) {
	# From host system
	my $vhost = &get_parent_server($server);
	$vhost || return "No host system for $server->{'host'} found";
	return &delete_file_on_server($vhost, $dest->{'path'});
	}
elsif ($dest->{'mode'} == 2) {
	# From other Cloudmin system
	my $destserver = &get_managed_server_by("id", $dest->{'id'});
	$destserver || return "No Cloudmin system with ID $dest->{'id'} found";
	return &delete_file_on_server($destserver, $dest->{'path'});
	}
elsif ($dest->{'mode'} == 3) {
	# From SSH server
	my $destserver = { 'id' => &server_id(),
			   'ssh_protocol' => 2,
			   'host' => $dest->{'host'},
			   'ssh_user' => $dest->{'user'},
			   'ssh_pass' => $dest->{'pass'},
			   'ssh_port' => $dest->{'port'},
			   'status' => 'nowebmin',
			  };
	return &delete_file_on_server($destserver, $dest->{'path'});
	}
elsif ($dest->{'mode'} == 4) {
	# From FTP server
	my $err = &put_file_to_server($server,
		"$module_root_directory/ftpupload.pl", "/tmp/ftpupload.pl");
	if ($err) {
		return "Failed to copy ftpupload.pl : $err";
		}
	my ($out, $ex, $err) = &execute_command_on_server($server,
		"perl /tmp/ftpupload.pl ".
		quotemeta($dest->{'user'})." ".
		quotemeta($dest->{'pass'})." ".
		quotemeta($dest->{'host'})." ".
		($dest->{'port'} || 21)." ".
		quotemeta($dest->{'path'})." ".
		"--delete 2>&1");
	return $err ? $err : $ex ? "FTP deletion failed : $out" : undef;
	}
else {
	return "Unknown backup destination mode $dest->{'mode'}";
	}
}

# compute_backup_space()
# Update all system owners with the amount of disk space they are using for
# backups that actually exist.
sub compute_backup_space
{
# Init size counts and latest backups for owner
my @owners = &list_system_owners();
my %ownermap;
my %changed;
foreach my $o (@owners) {
	$o->{'acl'}->{'backup_size'} = 0;
	$o->{'acl'}->{'backup_list'} = '';
	$ownermap{$o->{'name'}} = $o;
	}

my %donedest;
my @ownerlogs = grep { $_->{'owner'} && $_->{'ok'} } &list_backup_logs();
my %servermap = map { $_->{'id'}, $_ } &list_managed_servers();
foreach my $l (sort { $b->{'time'} <=> $a->{'time'} } @ownerlogs) {
	next if ($donedest{$l->{'dest'}}++);
	my $owner = $ownermap{$l->{'owner'}};
	next if (!$owner);

	# Does the dest file still exist?
	my $dest = &parse_backup_destination($l->{'dest'});
	my $exists;
	if ($dest->{'mode'} == 0) {
		# Check on Cloudmin master
		$exists = -r $dest->{'path'} ? 1 : 0;
		}
	elsif ($dest->{'mode'} == 1) {
		# Check on host system
		my $vhost = &get_parent_server($s);
		if ($vhost) {
			my @st = &stat_file_on_server($vhost, $dest->{'path'});
			$exists = $st[7] ? 1 : 0;
			}
		}
	elsif ($dest->{'mode'} == 2) {
		# Check on some other system
		my $server = $servermap{$dest->{'id'}};
		if ($server) {
			my @st = &stat_file_on_server($server, $dest->{'path'});
			$exists = $st[7] ? 1 : 0;
			}
		}
	else {
		# For remote FTP or SSH, we don't care
		next;
		}

	# Add to size count for owner
	$owner->{'acl'}->{'backup_size'} += $l->{'size'};
	$owner->{'acl'}->{'backup_list'} .= $l->{'id'}.' ';
	$changed{$owner->{'name'}} = $owner;
	}

# Save out all changed owners
foreach my $owner (values %changed) {
	&save_system_owner($owner, $owner, 1);
	}

# XXX don't check same logs twice
}

# check_backup_dest_size(&server, &dest, size, $owner)
# Checks if transferring a backup to some destination would exceed the backup
# owner's size limit
sub check_backup_dest_size
{
my ($server, $dest, $size, $owner) = @_;
return undef if (!$owner);
my $limits = &get_owner_limits($owner);
return undef if (!$limits || !$limits->{'max_space'});
return undef if ($dest->{'mode'} >= 3);

# How big is the existing file at that dest?
my @st;
if ($dest->{'mode'} == 0) {
	# Check on Cloudmin master
	@st = stat($dest->{'path'});
	}
elsif ($dest->{'mode'} == 1) {
	# Check on host system
	my $vhost = &get_parent_server($s);
	if ($vhost) {
		@st = &stat_file_on_server($vhost, $dest->{'path'});
		}
	}
elsif ($dest->{'mode'} == 2) {
	# Check on some other system
	my $server = $servermap{$dest->{'id'}};
	if ($server) {
		@st = &stat_file_on_server($server, $dest->{'path'});
		}
	}

# Work out increment, check against limit
my $growth = $size - $st[7];
if ($limits->{'space'} + $growth > $limits->{'max_space'}) {
	return &text('brun_eover', &nice_size($limits->{'space'}),
				   &nice_size($limits->{'max_space'}),
				   &nice_size($size));
	}
return undef;
}

# backup_strftime(path)
# Replaces stftime-style % codes in a path with the current time
sub backup_strftime
{
local @tm = localtime(time());
&clear_time_locale();
local $rv = strftime($_[0], @tm);
&reset_time_locale();
return $rv;
}

1;

