# Functions for virtual system backups

# list_backups([keep-enabled-flag])
# Returns a list of backups configured by root or system owners
sub list_backups
{
my ($keepenabled) = @_;
opendir(BACKUPS, $scheduled_backups_dir);
foreach my $b (readdir(BACKUPS)) {
	if ($b ne "." && $b ne "..") {
		my %backup;
		&read_file("$scheduled_backups_dir/$b", \%backup);
		$backup{'id'} = $b;
		$backup{'file'} = "$scheduled_backups_dir/$b";
		if (!$keepenabled) {
			delete($backup{'enabled'});	# Worked out below
			}
		push(@rv, \%backup);
		}
	}
closedir(BACKUPS);

if (!$keepenabled) {
	# Merge in cron jobs to see which are enabled
	&foreign_require("cron", "cron-lib.pl");
	my @jobs = &cron::list_cron_jobs();
	foreach my $j (@jobs) {
		if ($j->{'user'} eq 'root' &&
		    $j->{'command'} =~
		      /^\Q$backup_cron_cmd\E(\s+\-\-id\s+(\d+))?/) {
			my $id = $2 || 1;
			my ($backup) = grep { $_->{'id'} eq $id } @rv;
			if ($backup) {
				$backup->{'enabled'} = 1;
				&copy_cron_sched_keys($j, $backup);
				}
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
my @canservers = grep { &supports_backup($_) } &list_managed_servers();
my @servers = &get_alert_servers($backup, \@canservers);
foreach my $h (split(/\s+/, $backup->{'missing'})) {
	# Read .serv files for systems that need to be re-created
	my $server = &get_missing_backup_server($h, $backup->{'dest'});
	push(@servers, $server) if ($server);
	}
if ($backup->{'owner'}) {
	# Limit to backup's owner
	my $owner = &get_system_owner($backup->{'owner'});
	my %osys = map { $_, 1 }
			split(/\s+/, $owner->{'acl'}->{'servers'});
	@servers = grep { $osys{$_->{'id'}} } @servers;
	}
return @servers;
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
&save_backup_cron($backup, $wasnew);
}

# save_backup_cron(&backup, was-new)
# Create, update or delete the cron job for a backup, based on whether it is
# enabled or not.
sub save_backup_cron
{
my ($backup, $wasnew) = @_;
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
my $failed = 0;

# Find the systems, and make sure their hosts are up
my %rv;
&$first_print($text{'brun_finding'});
my @servers = &get_backup_servers($backup);
foreach my $s (@servers) {
	if ($s->{'status'} eq 'nohost') {
		my $vhost = &get_parent_server($s);
		$rv{$s->{'id'}} = {
			'ok' => 0,
			'msg' => &text('brun_ehostdown', $vhost->{'host'}),
			};
		$failed++;
		}
	}
@servers = grep { !$rv{$_->{'id'}} } @servers;
&$second_print(&text('brun_found', scalar(@servers)));

# Work out the destination for each, perhaps from the host
&$first_print($text{'brun_findingdests'});
my %destmap;
foreach my $s (@servers) {
	my ($ok, $destfile) = &compute_backup_destination($s, $backup);
	if ($ok) {
		$destmap{$s->{'id'}} = $destfile;
		}
	else {
		$rv{$s->{'id'}} = { 'ok' => 0, 'msg' => $destfile, };
		$failed++;
		next;
		}
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
			$failed++;
			}
		}
	}

# Exclude failures
@servers = grep { !$rv{$_->{'id'}} } @servers;
&$second_print(&text('brun_founddests', scalar(@servers)));

# Run pre-backup command
if ($backup->{'pre'} =~ /\S/ && @servers) {
	&$first_print($text{'brun_pre'});
	($ok, $out) = &execute_prepost_command(
		$backup->{'pre'}, $backup->{'pre_host'}, \@servers);
	&$block_print($out);
	if ($ok) {
		&$second_print($text{'brun_predone'});
		}
	else {
		foreach my $s (@servers) {
			$rv{$s_>{'id'}} = { 'ok' => 0,
					    'msg' => $text{'brun_preskip'} };
			}
		&$second_print($text{'brun_prefailed'});
		return \%rv;
		}
	}

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
		$failed++ if (!$prv[$i]->[0]->{'ok'} &&
			      !$prv[$i]->[0]->{'empty'});
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
		$failed++ if (!$srv->{'ok'} &&
			      !$srv->{'empty'});
		&save_backup_log($s, $destmap{$s->{'id'}}, $srv,
				 $backup, $start);
		}
	}

# Purge old date-based backups
if ($backup->{'purge'}) {
	# Work out all destinations to purge
	my @purgedests;
	if ($backup->{'dest'}) {
		@purgedests = ( $backup->{'dest'} );
		}
	else {
		foreach my $s (@servers) {
			my $vhost = &get_parent_server($s);
			if ($vhost && $vhost->{'backup_default'}) {
				push(@purgedests, $vhost->{'backup_default'});
				}
			}
		@purgedests = &unique(@purgedests);
		}

	# Run purge on each one
	foreach my $purgedest (@purgedests) {
		my ($base, $re) = &extract_purge_path($purgedest);
		&$first_print(&text('brun_purging', $backup->{'purge'}, $base));
		if ($failed) {
			# Skip because some backups failed
			&$second_print($text{'brun_purgeskip'});
			}
		else {
			# Do the purge
			&$indent_print();
			my $err = &purge_old_backups($purgedest,
						     $backup->{'purge'});
			&$outdent_print();
			if ($err !~ /^\d+$/) {
				&$second_print(&text('brun_purgefailed', $err));
				}
			elsif ($err) {
				&$second_print(&text('brun_purgedone',
						     &nice_size($err)));
				}
			else {
				&$second_print($text{'brun_purgenone'});
				}
			}
		}
	}

# If backup was by a system owner, re-compute his usage
if ($backup->{'owner'}) {
	&compute_backup_space();
	}

# Run post-backup command
if ($backup->{'post'} =~ /\S/ && @servers) {
	&$first_print($text{'brun_post'});
	($ok, $out) = &execute_prepost_command(
		$backup->{'post'}, $backup->{'post_host'}, \@servers);
	&$block_print($out);
	if ($ok) {
		&$second_print($text{'brun_predone'});
		}
	else {
		&$second_print($text{'brun_prefailed'});
		}
	}

# Add in destinations to results
foreach my $s (@servers) {
	$rv{$s->{'id'}}->{'dest'} = $destmap{$s->{'id'}};
	}

return \%rv;
}

# execute_prepost_command(command, on-host, &servers)
# Executes a pre or post-backup command. Returns an OK flag and the output.
# May run multiple times if running on the host and there is more than one.
sub execute_prepost_command
{
my ($cmd, $onhost, $servers) = @_;
my @runon;
my @rv;
if ($onhost) {
	my %done;
	foreach my $s (@$servers) {
		my $vhost = &get_parent_server($s);
		push(@runon, $vhost) if ($vhost && !$done{$vhost->{'id'}}++);
		}
	}
else {
	push(@runon, &get_managed_server(0));
	}
foreach my $s (@runon) {
	my ($out, $ex, $err) = &execute_command_on_server($s, $cmd);
	push(@rv, [ $s, $ex || $err ? 0 : 1, $out ]);
	}
if (@rv == 1) {
	# Just one machine
	return ( $rv[0]->[1], $rv[0]->[2] );
	}
else {
	# Concatenate results from all hosts
	my $ok = 1;
	my $out;
	foreach my $r (@rv) {
		$ok = 0 if (!$r->[1]);
		$r->[2] =~ s/\n\s*$//;
		$out .= $r->[0]->{'host'}.": ".$r->[2]."\n";
		}
	return ( $ok, $out );
	}
}

# compute_backup_destination(&server, &backup)
# For some system returns a status code (0=failed, 1=ok) and either a backup
# destination or an error message
sub compute_backup_destination
{
my ($s, $backup) = @_;
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
		return ( 0, &text('brun_evhost', $vhost->{'host'}) );
		}
	if ($backup->{'owner'}) {
		$destdir .= '/'.$backup->{'owner'};
		}
	}
return ( 1, &backup_strftime($destdir)."/".$s->{'host'}.".".
            &get_backup_extension($s) );
}

# execute_system_backup(&server, destination, shutdown?, owner-name)
# Backup one virtual system to the given destination. Returns a status hash
# ref, with keys 'ok', 'msg', 'size'
sub execute_system_backup
{
my ($server, $deststr, $shutdown, $owner) = @_;

# Check for backup to self
my $vhost = &get_parent_server($server);
my $dest = &parse_backup_destination($deststr);
my $destserver = &get_backup_dest_server($dest, $vhost);
if ($destserver && $destserver->{'id'} eq $server->{'id'}) {
	return { 'ok' => 0,
		 'msg' => $text{'brun_eself'} };
	}

# Check if running, and if so shut down
my $was_up = 0;
if ($server->{'status'} ne 'down' && $shutdown) {
	&$first_print(&text('brun_shutdown', $server->{'host'}));
	$err = &shutdown_server($server);
	if ($err) {
		return { 'ok' => 0,
			 'msg' => &text('smove_shutfailed', $err) };
		}
	&check_server_status($server, 0, 1);
	$was_up = 1;
	&save_managed_server($server);
	&$second_print($text{'create_done'});
	}

# Call the type-specific backup function
&$first_print(&text('brun_backing', $server->{'host'},
		    &nice_backup_destination($deststr)));
&$indent_print();
my $bfunc = "type_".$server->{'manager'}."_backup_system";
my $rv = &$bfunc($server, $deststr, $shutdown, $owner);
&$outdent_print();
if ($rv->{'ok'}) {
	# Worked completely
	&$second_print(&text('brun_backed', &nice_size($rv->{'size'})));
	}
elsif ($rv->{'empty'}) {
	# All disks excluded, but didn't fail
	&$second_print(&text('brun_empty'));
	}
else {
	&$second_print(&text('brun_failed', $rv->{'msg'}));
	}

# Save system details, for use when restoring
if ($rv->{'ok'}) {
	my $server_deststr = $deststr;
	$server_deststr =~ s/\/[^\/]+$/\//;
	$server_deststr .= $server->{'host'}.".serv";
	my $server_dest = &parse_backup_destination($server_deststr);
	&$first_print(&text('brun_server', $server->{'host'},
			    &nice_backup_destination($server_deststr)));
	if ($server_dest->{'mode'} == 1) {
		# Set vhost as dest system
		$server_dest->{'mode'} = 2;
		$server_dest->{'id'} = $vhost->{'id'};
		}
	my $err = &send_to_backup_dest(&get_this_managed_server(),
				       $server->{'file'},
				       $server_dest);
	if ($err) {
		&$second_print(&text('brun_serverfailed', $err));
		}
	else {
		&$second_print($text{'create_done'});
		}
	}

# If more than one disk, save dump of disk details in a separate file
my $dfunc = "type_".$server->{'manager'}."_list_disks";
if ($rv->{'ok'} && defined(&$dfunc)) {
	my $disks = &$dfunc($server);
	if (ref($disks) && @$disks > 0) {
		my $dtemp = &transname();
		my $disks_deststr = $deststr;
		$disks_deststr =~ s/\/[^\/]+$/\//;
		$disks_deststr .= $server->{'host'}.".disks";
		my $disks_dest = &parse_backup_destination($disks_deststr);
		&$first_print(&text('brun_disks', $server->{'host'},
				    &nice_backup_destination($disks_deststr)));
		&open_tempfile(DTEMP, ">$dtemp", 0, 1);
		&print_tempfile(DTEMP, &serialise_variable($disks));
		&close_tempfile(DTEMP);
		if ($disks_dest->{'mode'} == 1) {
			# Set vhost as dest system
			$disks_dest->{'mode'} = 2;
			$disks_dest->{'id'} = $vhost->{'id'};
			}
		my $err = &send_to_backup_dest(&get_this_managed_server(),
					       $dtemp, $disks_dest);
		if ($err) {
			&$second_print(&text('brun_serverfailed', $err));
			}
		else {
			&$second_print($text{'create_done'});
			}
		}
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
		 'status' => 'nowebmin',
		 'force_root_shell' => 1,	# So that commands are
						# run in sh regardless
						# of SSH user's shell
	        };
	}
else {
	return undef;
	}
}

# send_to_backup_dest(&server, file, &destination, [extension])
# Send some file to a backup destination. Returns an error on failure, undef on
# success.
sub send_to_backup_dest
{
my ($server, $file, $dest, $ext) = @_;
my $destdir = $dest->{'path'};
$destdir =~ s/\/([^\/]+)$//;
my $destserver = &get_backup_dest_server($dest);
if ($dest->{'mode'} == 0) {
	# Download to Cloudmin master
	if (!-d $destdir) {
		&make_dir($destdir, 0700, 1) ||
			return &text('brun_emkdir', "$!");
		}
	return &get_file_from_server($server, $file, $dest->{'path'}.$ext);
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
				      $file, $dest->{'path'}.$ext, 0, 1);
	}
elsif ($dest->{'mode'} == 3) {
	# Send via SSH (using a fake server object)
	my $mkerr = &create_backup_dest_dir($destserver, $dest->{'path'});
	return &text('brun_emkdir', $mkerr) if ($mkerr);
	return &transfer_file_between_servers($server, $destserver,
					      $file, $dest->{'path'}.$ext, 0);
	}
elsif ($dest->{'mode'} == 4) {
	# Send via FTP, using our little FTP uploader
	my $err = &put_file_to_server($server,
		"$module_root_directory/ftpupload.pl", "/tmp/ftpupload.pl");
	if ($err) {
		return "Failed to copy ftpupload.pl : $err";
		}
	my $dir = $dest->{'path'};
	$dir =~ s/\/([^\/]+)$//;
	&ftp_onecommand($dest->{'host'}, "MKD $dir", \$err,
			$dest->{'user'}, $dest->{'pass'},$dest->{'port'} || 21);
	my ($out, $ex, $err) = &execute_command_on_server($server,
		"perl /tmp/ftpupload.pl ".
		quotemeta($dest->{'user'})." ".
		quotemeta($dest->{'pass'})." ".
		quotemeta($dest->{'host'})." ".
		($dest->{'port'} || 21)." ".
		quotemeta($dest->{'path'}.$ext)." ".
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
	my $vhost = &get_parent_server($s);
	if ($s->{'status'} eq 'nohost' ||
	    !&can_ssh_status($vhost)) {
		$rv{$s->{'id'}} = {
			'ok' => 0,
			'msg' => &text('brun_ehostdown', $vhost->{'host'}),
			};
		}
	if (&indexof($s->{'manager'}, @server_management_types) < 0) {
		$rv{$s->{'id'}} = {
			'ok' => 0,
			'msg' => &text('brun_emanager', $s->{'manager'}),
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

# Re-create missing systems
foreach my $s (grep { $_->{'missing'} } @servers) {
	&$first_print(&text('rrun_recreate', $s->{'host'}));
	my $err = &can_create_missing_backup_server($s);
	if ($err) {
		&$second_print(&text('rrun_erecreate', $err));
		$rv{$s->{'id'}} = { 'ok' => 0, 'msg' => $err, };
		}
	else {
		&$indent_print();
		my $ok = &create_missing_backup_server($s);
		&$outdent_print();
		if (!$ok) {
			&$second_print($text{'rrun_erecreate2'});
			$rv{$s->{'id'}} = { 'ok' => 0,
					    'msg' => $text{'rrun_erecreate2'} };
			}
		else {
			&$second_print($text{'create_done'});

			# Re-create any disks on the original systems
			my $disks = &get_missing_backup_server_disks(
					$s->{'host'}, $backup->{'dest'});
			if ($disks && ref($disks) && @$disks > 1) {
				&$first_print(&text('rrun_redisks',
					$s->{'host'}, scalar(@$disks)-1));
				my $err = &create_missing_backup_server_disks(
						$s, $disks);
				if ($err) {
					&$second_print(
						&text('rrun_eredisks', $err));
					}
				else {
					&$second_print($text{'create_done'});
					}
				}
			}
		}
	}

# Exclude re-create failures
@servers = grep { !$rv{$_->{'id'}} } @servers;

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
	&check_server_status($server, 0, 1);
	$was_up = 1;
	&save_managed_server($server);
	&$second_print($text{'create_done'});
	}

# Check for disks whose size doesn't match the size in the backup
my $disksdest = $dest;
$disksdest =~ s/\/([^\/]+)$//;	# Following function adds the server name back
my $olddisks = &get_missing_backup_server_disks(
		$server->{'host'}, $disksdest);
my $dfunc = "type_".$server->{'manager'}."_list_disks";
my $disks = defined(&$dfunc) ? &$dfunc($server, 0) : undef;
if (!$server->{'missing'} && ref($olddisks) && ref($disks) && @$olddisks > 0) {
	# Check for each original disk that the current disk exists, is not
	# the same size, and is a logical volume. File-based disks don't need
	# resizing, because they just get over-written.
	for(my $i=0; $i<@$olddisks; $i++) {
		my $inc = &get_disk_include($server, $disks->[$i]);
		if ($inc &&
		    $olddisks->[$i]->{'size'} &&
		    $i < @$disks &&
		    $disks->[$i]->{'size'} &&
		    $olddisks->[$i]->{'size'} != $disks->[$i]->{'size'} &&
		    $disks->[$i]->{'lv'}) {
			my $d = $disks->[$i];
			my $od = $olddisks->[$i];
			my $rdesc = &describe_disk($server, $d);
			&$first_print(&text('rrun_disksize',
					    $rdesc,
					    &nice_size($d->{'size'}),
					    &nice_size($od->{'size'})));
			my $nd = { %$d };
			$nd->{'size'} = $od->{'size'};
			my $mfunc = "type_".$server->{'manager'}."_modify_disk";
			my $err = &$mfunc($server, $nd, $d);
			if ($err) {
				&$second_print(&text('rrun_edisksize', $err));
				}
			else {
				&$second_print($text{'create_done'});
				}
			}
		}
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
	    'dests' => $rv->{'dests'} || $dest,
	    'ok' => $rv->{'ok'},
	    'empty' => $rv->{'empty'},
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
	return { 'ok' => 0,
		 'msg' => &text('brun_emkdir', $mkerr) } if ($mkerr);
	}
elsif (&can_transfer_directly($dest)) {
	# Transferring directly to dest host
	if (!$destserver) {
		return { 'ok' => 0, 'msg' => $text{'brun_edestserver'} };
		}
	my $mkerr = &create_backup_dest_dir($destserver, $dest->{'path'});
	return { 'ok' => 0,
		 'msg' => &text('brun_emkdir', $mkerr) } if ($mkerr);
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
	&start_background_dot_printer(
		&text('brun_tarring', $server->{'host'}, $root));
	my $tarcmd = "cd ".quotemeta($root)." && ".
		     &tar_gzip_command($vhost, ".", $tarfile);
	$tarcmd = &niced_backup_command($vhost, $tarcmd);
	my ($out, $ex, $err) = &execute_command_on_server($vhost, $tarcmd);
	&stop_background_dot_printer();
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
			&start_background_dot_printer(
				&text('brun_sending', $server->{'host'},
				      &nice_backup_destination($dest)));
			$err = &send_to_backup_dest($vhost, $tarfile, $dest);
			&stop_background_dot_printer();
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
	&start_background_dot_printer(
		&text('brun_tarring4', $server->{'host'}, $root,
		      $destserver->{'host'}));
	my $tarcmd = "cd ".quotemeta($root)." && ".
		     &tar_gzip_command($vhost, ".");
	$tarcmd = &niced_backup_command($vhost, $tarcmd);
	my $err = &pipe_command_to_server($vhost, $destserver, $tarcmd,
					  $dest->{'path'});
	&stop_background_dot_printer();
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
elsif (&can_transfer_directly($dest)) {
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
		&start_background_dot_printer(
			&text('rrun_getting', $server->{'host'},
			      &nice_backup_destination($dest)));
		my $err = &get_from_backup_dest($vhost, $tarfile, $dest);
		&stop_background_dot_printer();
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
	&start_background_dot_printer(
		&text('rrun_untarring', $server->{'host'}, $root));
	my $tarcmd = "cd ".quotemeta($root)." && ".
		     "rm -rf * && ".
		     &tar_gunzip_command($vhost, $tarfile);
	$tarcmd = &niced_backup_command($vhost, $tarcmd);
	my ($out, $ex, $err) = &execute_command_on_server($vhost, $tarcmd);
	&stop_background_dot_printer();
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
	&start_background_dot_printer(
		&text('rrun_untarring4', $server->{'host'}, $root,
		      $destserver->{'host'}));
	my $tarcmd = "cd ".quotemeta($root)." && ".
		     "rm -rf * && ".
		     &tar_gunzip_command($vhost, undef);
	$tarcmd = &niced_backup_command($vhost, $tarcmd);
	my $err = &pipe_command_from_server($destserver, $vhost, $tarcmd,
					    $dest->{'path'});
	&stop_background_dot_printer();
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

# images_backup_system(&server, dest, shutdown, owner-name)
# Backs up a virtual system that uses disk images
sub images_backup_system
{
my ($server, $deststr, $shutdown, $owner) = @_;
my $vhost = &get_parent_server($server);
my $dest = &parse_backup_destination($deststr);
my $origdest = { %$dest };
my $destserver = &get_backup_dest_server($dest, $vhost);
if ($destserver && $destserver->{'id'} eq $vhost->{'id'}) {
	$dest->{'mode'} = 1;
	}
my $manager = $server->{'manager'};

# Pick a temp file on the host system, if needed
my $gzfile;
if ($dest->{'mode'} == 1) {
	# Target is on host already
	$gzfile = $dest->{'path'};
	my $mkerr = &create_backup_dest_dir($vhost, $gzfile);
	return { 'ok' => 0,
		 'msg' => &text('brun_emkdir', $mkerr) } if ($mkerr);
	}
elsif (&can_transfer_directly($dest)) {
	# Transferring directly to dest host
	if (!$destserver) {
		return { 'ok' => 0, 'msg' => $text{'brun_edestserver'} };
		}
	my $mkerr = &create_backup_dest_dir($destserver, $dest->{'path'});
	return { 'ok' => 0,
		 'msg' => &text('brun_emkdir', $mkerr) } if ($mkerr);
	$gzfile = undef;
	}
else {
	# Pick temp file for compressed disks
	$gzfile = &tempname_on_server($vhost, $server->{'host'}.'.gz');
	if (!$gzfile) {
		return { 'ok' => 0,
			 'msg' => &text('brun_etemp', $vhost->{'host'}) };
		}
	}

# Get disk list
my $dfunc = "type_".$manager."_list_disks";
my $disks = &$dfunc($server, 1);
if (!ref($disks)) {
	$disks = &$dfunc($server, 0);
	}
if (!ref($disks)) {
	return { 'ok' => 0,
		 'msg' => &text('brun_edisks', $disks) };
	}

# Find LVM disks, and disks that are on regular files (or iSCSI)
my @lvmdisks = grep { $_->{'lv'} } @$disks;
my @filedisks = grep { !$_->{'device'} || $_->{'iscsi_server'} ne '' } @$disks;
my %skipdisks = map { $_->{'real'}, !&should_include_disk($server, $_) }
		    @$disks;

# Check if LVM on source is clustered
my $clusterlvm;
if ($server->{$manager.'_filesystem_lv'} && $server->{'status'} ne 'down' &&
    @lvmdisks) {
	my ($out, $ex, $err) = &execute_command_on_server($vhost,
				"vgdisplay ".$lvmdisks[0]->{'vg'});
	if ($out =~ /Clustered\s+yes/i) {
		$clusterlvm = 1;
		}
	}

if (&can_ssh_status($server)) {
	# Flush buffers to disk to ensure disk copy gets everything
	&execute_command_on_server($server, "sync ; sync ; sync");
	}

# If on LVM and we are not shutting down, take an LVM snapshot of each disk
my @snaps;
if ($server->{$manager.'_filesystem_lv'} && $server->{'status'} ne 'down' &&
    !$clusterlvm) {
	&$first_print(&text('brun_snapshot', $server->{'host'}));
	foreach my $d (@lvmdisks) {
		my $snaplv = { 'size' => int(($d->{'size'}/10)/1024),
			       'is_snap' => 1,
			       'snapof' => $d->{'lv'},
			       'name' => $d->{'lv'}.'_cloudmin_snap',
			       'vg' => $d->{'vg'},
			       'perm' => 'rw',
			       'alloc' => 'n', };
		$snaplv->{'device'} = '/dev/'.$snaplv->{'vg'}.'/'.
				      $snaplv->{'name'};
		if ($skipdisks{$d->{'real'}}) {
			# Skipping this LV, but save the snapshot device we
			# would have used in order to preserve the size of
			# @snaps
			$skipdisks{$snaplv->{'device'}} = 1;
			}
		else {
			&delete_all_disk_image_partitions($vhost, $snaplv);
			&remote_foreign_require($vhost, "lvm", "lvm-lib.pl");
			&remote_foreign_call($vhost, "lvm",
					     "delete_logical_volume", $snaplv);
			$last_remote_error = undef;
			my $err = &remote_foreign_call($vhost, "lvm",
					  "create_logical_volume", $snaplv);
			$err ||= $last_remote_error;
			if ($err) {
				return { 'ok' => 0,
					 'msg' => &text('brun_esnap',
							$d->{'real'}, $err) };
				}
			}
		push(@snaps, $snaplv);
		}
	}

# XXX handle different disk types on same system
my @devs;
if ($server->{$manager.'_filesystem_lv'}) {
	# Use LVM snapshots if possible, disk devices otherwise
	if (@snaps) {
		@devs = map { $_->{'device'} } @snaps;
		}
	else {
		@devs = map { $_->{'real'} } @lvmdisks;
		}
	}
else {
	# Use disk image files
	@devs = map { $_->{'real'} } @filedisks;
	}
my @do_devs = grep { !$skipdisks{$_} } @devs;
if (!@do_devs) {
	# All disks excluded .. but that may be OK, as long as some disks
	# were found
	return { 'ok' => 0,
		 'empty' => @devs ? 1 : 0,
		 'msg' => $text{'brun_allskip'} };
	}

my @gzfiles;
my $msg = $server->{$manager.'_filesystem_lv'} ? 'brun_ddone' : 'brun_ddfile';
if ($gzfile) {
	# Need to write to local files
	my $i = 0;
	&start_background_dot_printer(&text($msg, $server->{'host'}));
	foreach my $dev (@devs) {
		my $ext = $i ? ".$i" : "";
		if ($skipdisks{$dev}) {
			# Create empty file indicating skip
			&execute_command_on_server($vhost,
				"rm -f ".quotemeta($gzfile.$ext));
			&execute_command_on_server($vhost,
				"touch ".quotemeta($gzfile.$ext));
			}
		else {
			# Create gzip file from dd of disk
			my $ddcmd = "(".&dd_command($dev, undef).
				    " | gzip $config{'zip_args'} -c >".
				    $gzfile.$ext.") 2>&1";
			$ddcmd = &niced_backup_command($vhost, $ddcmd);
			my ($out, $ex, $err) = &execute_command_on_server(
						$vhost, $ddcmd);
			if ($ex || $err) {
				$ddfail = &text('brun_edd', $dev, $err || $out);
				last;
				}
			}
		push(@gzfiles, $gzfile.$ext);
		$i++;
		}
	&stop_background_dot_printer();
	}
else {
	# Can write directly to target system
	my $i = 0;
	&start_background_dot_printer(&text($msg.'2', $server->{'host'},
					   $destserver->{'host'}));
        foreach my $dev (@devs) {
		my $ext = $i ? ".$i" : "";
		my $err;
		if ($skipdisks{$dev}) {
			# Create empty file indicating skip
			my $empty = &transname();
			&open_tempfile(EMPTY, ">$empty", 0, 1);
			&close_tempfile(EMPTY);
			$err = &put_file_to_server($destserver,
				$empty, $dest->{'path'}.$ext);
			}
		else {
			# Create gzip file from dd of disk
			my $ddcmd = &dd_command($dev, undef).
				    " | gzip -c $config{'zip_args'}";
			$ddcmd = &niced_backup_command($vhost, $ddcmd);
			$err = &pipe_command_to_server(
					$vhost, $destserver, $ddcmd,
					$dest->{'path'}.$ext);
			}
		if ($err) {
			$ddfail = &text('brun_edd', $lvmdevs[0], $err);
			last;
			}
		push(@gzfiles, $dest->{'path'}.$ext);
		$i++;
		}
	&stop_background_dot_printer();
	}

# Close Webmin session, as it may have timed out
&remote_finished();

# Remove any LVM snapshots we created
if (@snaps) {
	&$first_print(&text('brun_unsnapshot', $server->{'host'}));
	&remote_foreign_require($vhost, "lvm", "lvm-lib.pl");
	foreach my $snaplv (@snaps) {
		if (!$skipdisks{$snaplv->{'device'}}) {
			&delete_all_disk_image_partitions($vhost, $snaplv);
			&remote_foreign_call($vhost, "lvm",
					     "delete_logical_volume", $snaplv);
			}
		}
	}

# Clean up and exit if DDing failed
if ($ddfail) {
	if ($gzfile) {
		foreach my $g (@gzfiles) {
			&delete_file_on_server($vhost, $g);
			}
		}
	return { 'ok' => 0, 'msg' => $ddfail };
	}

# Get the size
my $size = 0;
my $staton = $gzfile ? $vhost : $destserver;
foreach my $g (@gzfiles) {
	my @st = &stat_file_on_server($staton, $g);
	if (!@st) {
		return { 'ok' => 0,
			 'msg' => &text('brun_estat', $g) };
		}
	$size += $st[7];
	}

# Transfer to the destination, if needed
if ($dest->{'mode'} != 1 && $gzfile) {
	# Check if size would exceed limits
	my $err = &check_backup_dest_size($server, $dest, $size, $owner);

	if (!$err) {
		# Send via SCP or FTP
		&$first_print(&text('brun_sending', $server->{'host'},
					    &nice_backup_destination($dest)));
		foreach my $g (@gzfiles) {
			my ($ext) = ($g =~ /(\.\d+)$/ ? $1 : undef);
			$err = &send_to_backup_dest($vhost, $g, $dest, $ext);
			last if ($err);
			}
		}

	# Delete from host
	foreach my $g (@gzfiles) {
		&delete_file_on_server($vhost, $g);
		}

	if ($err) {
		return { 'ok' => 0,
			 'msg' => &text('brun_esend', $err) };
		}
	}

# Build list of destination files
my @dests;
foreach my $g (@gzfiles) {
	my ($ext) = ($g =~ /(\.\d+)$/ ? $1 : undef);
	push(@dests, &join_backup_destination($origdest).$ext);
	}

# Return status
return { 'ok' => 1,
	 'dests' => join(' ', @dests),
	 'size' => $size };
}

# image_restore_system(&server, dest, shutdown)
# Restore a disk-image based VM from the given destination, and return a backup
# status hash ref.
sub image_restore_system
{
my ($server, $deststr) = @_;
my $vhost = &get_parent_server($server);
my $dest = &parse_backup_destination($deststr);
my $destserver = &get_backup_dest_server($dest, $vhost);
if ($destserver && $destserver->{'id'} eq $vhost->{'id'}) {
	$dest->{'mode'} = 1;
	}
my $manager = $server->{'manager'};

# Check for an old tar.gz format backup if gz format is missing
if ($dest->{'mode'} == 0 || $dest->{'mode'} == 2) {
	my @dst = &stat_file_on_server($destserver, $dest->{'path'});
	if (!@dst) {
                my $altpath = $dest->{'path'};
		if ($altpath =~ /\.gz$/ && $altpath !~ /\.tar\.gz$/) {
			$altpath =~ s/\.gz$/\.tar\.gz/;
			}
		@dst = &stat_file_on_server($destserver, $altpath);
		if (@dst) {
			$dest->{'path'} = $altpath;
			}
		}
	}

# Work out original backup format - either a tar.gz of disks, or one gz file
# per disk
my $gzip_format;
if ($dest->{'path'} =~ /\.tar\.gz$/) {
	$gzip_format = 0;
	}
elsif ($dest->{'path'} =~ /\.gz$/) {
	$gzip_format = 1;
	}
else {
	return { 'ok' => 0,
		 'msg' => &text('brun_eformat', $dest->{'path'})
	       };
	}

# Pick a temp file on the host system, if needed
my $localfile;
if ($dest->{'mode'} == 1) {
	# Source file is on host already
	$localfile = $dest->{'path'};
	}
elsif (&can_transfer_directly($dest)) {
	# Transferring directly from source host
	$localfile = undef;
	}
else {
	# Pick temp file for tar.gz or gz file
	$localfile = &tempname_on_server($vhost,
		$server->{'host'}.($gzip_format ? '.gz' : '.tar.gz'));
	if (!$localfile) {
		return { 'ok' => 0,
			 'msg' => &text('brun_etemp', $vhost->{'host'}) };
		}
	}

# Get disk list
my $dfunc = "type_".$manager."_list_disks";
my $disks = &$dfunc($server, 1);
if (!ref($disks)) {
	$disks = &$dfunc($server, 0);
	}
if (!ref($disks)) {
        return { 'ok' => 0,
                 'msg' => &text('brun_edisks', $disks) };
        }
my @lvmdisks = grep { $_->{'lv'} } @$disks;
my @filedisks = grep { !$_->{'device'} || $_->{'iscsi_server'} ne '' } @$disks;
my @devs;
if ($server->{$manager.'_filesystem_lv'}) {
	if (!@lvmdisks) {
		return { 'ok' => 0,
			 'msg' => &text('brun_elvmdisks') };
		}
	@devs = map { $_->{'real'} } @lvmdisks;
	}
else {
	if (!@filedisks) {
		return { 'ok' => 0,
			 'msg' => &text('brun_efiledisks') };
		}
	@devs = map { $_->{'real'} } @filedisks;
	}

# Copy in the tar.gz or gz backup files, if needed
my @gzfiles;
my ($staton, @statfiles);
if ($dest->{'mode'} != 1 && $localfile) {
	# Files are not on the host already, and need to be downloaded via
	# FTP or SSH
        &start_background_dot_printer(&text('rrun_getting', $server->{'host'},
                                            &nice_backup_destination($dest)));
        my $err = &get_from_backup_dest($vhost, $localfile, $dest);
        if ($err) {
		&stop_background_dot_printer();
                return { 'ok' => 0,
                         'msg' => &text('rrun_eget', $err) };
                }
	$staton = $vhost;
	if ($gzip_format) {
		# Also load in additional .gz.* files
		push(@gzfiles, $localfile);
		my $i = 1;
		while(1) {
			my $err = &get_from_backup_dest(
				$vhost, $localfile.".".$i, $dest, ".".$i);
			last if ($err);
			push(@gzfiles, $localfile.".".$i);
			$i++;
			}
		@statfiles = @gzfiles;
		}
	else {
		# Only one tar.gz file
		@statfiles = ( $localfile );
		}
	&stop_background_dot_printer();
        }
elsif ($dest->{'mode'} == 1 && $localfile) {
	# Files are on the host already
	$staton = $vhost;
	@statfiles = ( $dest->{'path'} );
	if ($gzip_format) {
		my $glob = &glob_on_server($vhost,
					   $dest->{'path'}.".[0-9]");
		push(@statfiles, @$glob) if (ref($glob));
		}
	}
else {
	# Files are on another Cloudmin-managed system
	$staton = $destserver;
	@statfiles = ( $dest->{'path'} );
	if ($gzip_format) {
		my $glob = &glob_on_server($destserver,
					   $dest->{'path'}.".[0-9]");
		push(@statfiles, @$glob) if (ref($glob));
		}
	}

# Get size, either from temp tar file or source
my $size;
foreach my $g (@statfiles) {
	@st = &stat_file_on_server($staton, $g);
	if (!@st) {
		return { 'ok' => 0, 'msg' => &text('rrun_estat', $g) };
		}
	$size += $st[7];
	}

my $tarerr;
if ($gzip_format) {
	# Un-zip each .gz.* file over a disk
	if ($localfile) {
		# Just extract from local files
		my $i = 0;
		&start_background_dot_printer(
			&text('rrun_dd', $server->{'host'}));
		foreach my $dev (@devs) {
			my $ext = $i ? ".$i" : "";
			my @st = &stat_file_on_server($vhost, $localfile.$ext);
			if ($st[7]) {
				my $ddcmd =
				    "(gunzip -c ".quotemeta($localfile.$ext).
				    " | ".&dd_command(undef, $dev).") 2>&1";
				$ddcmd = &niced_backup_command($vhost, $ddcmd);
				my ($out, $ex, $err) =
				    &execute_command_on_server($vhost, $ddcmd);
				if ($ex || $err) {
					$tarerr = &text('rrun_edd', $dev,
							$err || $out);
					last;
					}
				}
			$i++;
			}
		}
	else {
		# Pipe in from remote system and extract
		my $i = 0;
		&start_background_dot_printer(
			&text('rrun_dd2', $server->{'host'},
			    $destserver->{'host'}));
		foreach my $dev (@devs) {
			my $ext = $i ? ".$i" : "";
			my @st = &stat_file_on_server($destserver,
						      $dest->{'path'}.$ext);
			if ($st[7]) {
				my $ddcmd = "(gunzip -c | ".
					    &dd_command(undef, $dev).") 2>&1";
				$ddcmd = &niced_backup_command($vhost, $ddcmd);
				my $err = &pipe_command_from_server(
					$destserver, $vhost, $ddcmd,
					$dest->{'path'}.$ext);
				if ($err) {
					$tarerr = &text('rrun_edd', $dev, $err);
					last;
					}
				}
			$i++;
			}
		}
	&stop_background_dot_printer();
	}
elsif ($server->{$manager.'_filesystem_lv'}) {
	# Overwrite logical volumes with tar piped into DD
	if ($localfile) {
		# From temp tar file
		&start_background_dot_printer(
			&text('rrun_dd', $server->{'host'}));
		foreach my $d (@lvmdisks) {
			my $devfile = $d->{'real'};
			$devfile =~ s/^(.*)\///;
			my $tarcmd = "gunzip -c ".quotemeta($localfile).
				     " | tar Oxpf - $devfile ./$devfile".
				     " | ".&dd_command(undef, $d->{'real'}).
				     "2>&1";
			$tarcmd = &niced_backup_command($vhost, $tarcmd);
			my ($out, $ex, $err) = &execute_command_on_server(
						$vhost, $tarcmd);
			if ($ex || $err) {
				$tarerr = &text('rrun_edd', $dev, $err || $out);
				last;
				}
			}
		}
	else {
		# From tar via SSH
		&start_background_dot_printer(
			&text('rrun_dd2', $server->{'host'},
			      $destserver->{'host'}));
		foreach my $d (@lvmdisks) {
			my $devfile = $d->{'real'};
			$devfile =~ s/^(.*)\///;
			my $tarcmd = "gunzip -c ".
				     " | tar Oxpf - $devfile ./$devfile".
				     " | ".&dd_command(undef, $d->{'real'});
			$tarcmd = &niced_backup_command($vhost, $tarcmd);
			my $err = &pipe_command_from_server($destserver, $vhost,
						    $tarcmd, $dest->{'path'});
			if ($err) {
				$tarerr = &text('rrun_edd', $dev, $err);
				last;
				}
			}
		}
	&stop_background_dot_printer();
	}
else {
	# Extract tar file of disk images in the disk base directory
	my $dir = $filedisks[0]->{'real'};
        $dir =~ s/\/[^\/]+$//;
	if ($localfile) {
		&start_background_dot_printer(&text('rrun_untarring2',
				    $server->{'host'}, $dir));
		my $tarcmd = "cd ".quotemeta($dir)." && ".
			     "gunzip -c ".quotemeta($localfile)." | tar xpf -";
		$tarcmd = &niced_backup_command($vhost, $tarcmd);
		my ($out, $ex, $err) = &execute_command_on_server(
					$vhost, $tarcmd);
		if ($ex || $err) {
			$err = $out if ($ex);
			$tarerr = &text('rrun_etar',
					"<tt>".&html_escape($out)."</tt>");
			}
		}
	else {
		# Fetch and extract tar file in one command
		&start_background_dot_printer(&text('rrun_untarring5',
			    $server->{'host'}, $dir, $destserver->{'host'}));
		my $tarcmd = "cd ".quotemeta($dir)." && ".
			     "gunzip -c | tar xpf -";
		$tarcmd = &niced_backup_command($vhost, $tarcmd);
		my $err = &pipe_command_from_server($destserver, $vhost,
						    $tarcmd, $dest->{'path'});
		if ($err) {
			$tarerr = &text('rrun_etar',
					"<tt>".&html_escape($err)."</tt>");
			}
		}
	&stop_background_dot_printer();
	}
&remote_finished();

# Remove the temp files if needed
if ($dest->{'mode'} != 1 && $localfile) {
	my @tempfiles = $gzip_format ? @gzfiles : ( $localfile );
	foreach my $g (@tempfiles) {
		&delete_file_on_server($vhost, $g);
		}
        }
if ($tempdir) {
	&delete_file_on_server($vhost, $tempdir);
	}

# Return status
if ($tarerr) {
        return { 'ok' => 0, 'msg' => $tarerr };
        }
else {
        return { 'ok' => 1, 'size' => $size };
        }

}

# get_from_backup_dest(&server, file, &destination, [extension])
# Get some file from a backup destination and put it on the given server.
# Returns an error on failure, undef on success.
sub get_from_backup_dest
{
my ($server, $file, $dest, $ext) = @_;
if ($dest->{'mode'} == 0) {
	# Upload from Cloudmin master
	return &put_file_to_server($server, $dest->{'path'}.$ext, $file);
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
				      $dest->{'path'}.$ext, $file, 0, 1);
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
			   'force_root_shell' => 1,	# So that commands are
							# run in sh regardless
							# of SSH user's shell
			  };
	return &transfer_file_between_servers($destserver, $server,
					      $dest->{'path'}.$ext, $file, 0);
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
		  "/".quotemeta($dest->{'path'}.$ext);
	my ($out, $ex, $err) = &execute_command_on_server($server, $cmd);
	return $err ? $err : $ex ? "FTP download failed : $out" : undef;
	}
else {
	return "Unknown destination mode $dest->{'mode'}";
	}
}

# delete_backup_dest(&dest, &server)
# Delete all the files at some backup destination, return undef if OK, or an
# error message on failure.
sub delete_backup_dest
{
my ($dest, $server) = @_;
my $err = &delete_one_backup_dest($dest, $server);
return $err if ($err);
if ($dest->{'path'} =~ /\.gz$/ && $dest->{'path'} !~ /\.tar\.gz$/) {
	# Also delete .1, .2, etc.. files
	my $i = 1;
	while(1) {
		$err = &delete_one_backup_dest($dest, $server, ".".$i);
		last if ($err);
		$i++;
		}
	}
# Also delete .serv file (may be missing)
foreach my $ext (".serv", ".disks") {
	my $serv_dest = { %$dest };
	$serv_dest->{'path'} =~ s/\/[^\/]+$/\//;
	$serv_dest->{'path'} .= $server->{'host'}.$ext;
	&delete_one_backup_dest($serv_dest, $server);
	}
return undef;
}

# delete_one_backup_dest(&dest, &server, [extension])
# Delete the file at some backup destination, return undef if OK, or an error
# message on failure.
sub delete_one_backup_dest
{
my ($dest, $server, $ext) = @_;
if ($dest->{'mode'} == 0) {
	# Just remove locally
	return &unlink_file($dest->{'path'}.$ext) ? undef : "$!";
	}
elsif ($dest->{'mode'} == 1) {
	# From host system
	my $vhost = &get_parent_server($server);
	$vhost || return "No host system for $server->{'host'} found";
	return &delete_file_on_server($vhost, $dest->{'path'}.$ext);
	}
elsif ($dest->{'mode'} == 2) {
	# From other Cloudmin system
	my $destserver = &get_managed_server_by("id", $dest->{'id'});
	$destserver || return "No Cloudmin system with ID $dest->{'id'} found";
	return &delete_file_on_server($destserver, $dest->{'path'}.$ext);
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
			   'force_root_shell' => 1,	# So that commands are
							# run in sh regardless
							# of SSH user's shell
			  };
	return &delete_file_on_server($destserver, $dest->{'path'}.$ext);
	}
elsif ($dest->{'mode'} == 4) {
	# From FTP server
	my $vhost = &get_parent_server($server);
	my $err = &put_file_to_server($vhost,
		"$module_root_directory/ftpupload.pl", "/tmp/ftpupload.pl");
	if ($err) {
		return "Failed to copy ftpupload.pl : $err";
		}
	my ($out, $ex, $err) = &execute_command_on_server($vhost,
		"perl /tmp/ftpupload.pl ".
		quotemeta($dest->{'user'})." ".
		quotemeta($dest->{'pass'})." ".
		quotemeta($dest->{'host'})." ".
		($dest->{'port'} || 21)." ".
		quotemeta($dest->{'path'}.$ext)." ".
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

# can_transfer_directly(&dest)
# Returns 1 if a direct transfer to the destination via SSH is possible
sub can_transfer_directly
{
my ($dest) = @_;
if ($dest->{'mode'} == 2 || $dest->{'mode'} == 0) {
	# Cloudmin-managed system
	return 1;
	}
elsif ($dest->{'mode'} == 3) {
	# SSH server .. check if we can ssh in
	my $destserver = &get_backup_dest_server($dest);
	my ($out, $ex, $err) = &execute_command_on_server($destserver,
							  "echo ok");
	if (!$ex && !$err && $out =~ /ok/) {
		return 1;
		}
	}
return 0;
}

# niced_backup_command(&server, command)
# Given a command that does a backup and will be run on some system, return
# a new command using ionice to run it with the appropriate priorities
sub niced_backup_command
{
my ($server, $cmd) = @_;
return $cmd if ($config{'sclass'} eq '' && $config{'sprio'} eq '');
return $cmd if (!&has_command_on_server($server, "ionice"));
my $rv = "ionice";
if ($config{'sclass'} ne '') {
	$rv .= " -c ".int($config{'sclass'});
	}
if ($config{'sprio'} ne '') {
	$rv .= " -n ".int($config{'sprio'});
	}
$rv .= " sh -c ".quotemeta($cmd);
return $rv;
}

# purge_old_backups(dest, days)
# Delete from the parent dir of some destination date-based backups that are
# older than some number of days
sub purge_old_backups
{
my ($deststr, $days) = @_;
my $dest = &parse_backup_destination($deststr);

# Extract the base path
my ($base, $re) = &extract_purge_path($deststr);
$base && $re || return $text{'purge_edatepath'};
my $cutoff = time() - $days*24*60*60;

# Find old files
my $destserver = &get_backup_dest_server($dest);
if ($dest->{'mode'} == 4) {
	# List on FTP server
	my $err;
	my $files = &ftp_listdir($dest->{'host'}, $base, \$err, $dest->{'user'},
			         $dest->{'pass'}, $dest->{'port'} || 21, 1);
	if ($err) {
		return &text('purge_els', $base, $err);
		}
	$files = [ grep { $_->[13] ne "." && $_->[13] ne ".." } @$files ];
	if (@$files && !$files->[0]->[9]) {
		return &text('purge_elstimes', $base);
		return 0;
		}
	foreach my $f (@$files) {
		next if ($f->[13] !~ /^$re$/);
		if ($f->[9] && $f->[9] < $cutoff) {
			# Found deletion candidate
			push(@delfiles, $base."/".$f->[13]);
			}
		}
	}
else {
	# List on some managed system
	my $files = &list_dir_on_server($destserver, $base);
	ref($files) || return &text('purge_els', $base, $files);
	foreach my $f (@$files) {
		next if ($f !~ /^$re$/);
		my @st = &stat_file_on_server($destserver, $base."/".$f);
		next if (!@st || @st == 1);
		if ($st[9] < $cutoff) {
			# Found deletion candidate
			push(@delfiles, $base."/".$f);
			}
		}
	}

# Delete old backups
my $sz = 0;
if (@delfiles && $dest->{'mode'} == 4) {
	# Delete via FTP
	foreach my $f (@delfiles) {
		&$first_print(&text('purge_deletingftp', $f));
		my $err;
		$sz += &ftp_deletefile($dest->{'host'}, $f, \$err,
				       $dest->{'user'}, $dest->{'pass'},
				       $dest->{'port'} || 21);
		if ($err) {
			&$second_print(&text('purge_edelete', $err));
			}
		else {
			&$second_print($text{'create_done'});
			}
		}
	}
elsif (@delfiles) {
	# Delete via SSH
	foreach my $f (@delfiles) {
		&$first_print(&text('purge_deleting', $f));
		my $fsz = &disk_usage_on_server($destserver, $f);
		if ($fsz =~ /^\d+$/) {
			$sz += $fsz;
			}
		my $err = &delete_file_on_server($destserver, $f);
		if ($err) {
			&$second_print(&text('purge_edelete', $err));
			}
		else {
			&$second_print($text{'create_done'});
			}
		}
	}

return $sz;
}

# extract_purge_path(dest)
# Given a backup URL with a path like /backup/%d-%m-%Y, return the base
# directory (like /backup) and the regexp matching the date-based filename
# (like .*-.*-.*)
sub extract_purge_path
{
my ($deststr) = @_;
my $dest = &parse_backup_destination($deststr);
if ($dest->{'path'} =~ /^(\S+)\/([^%]*%.*)$/) {
	my ($base, $date) = ($1, $2);
	$date =~ s/%[_\-0\^\#]*\d*[A-Za-z]/\.\*/g;
	return ($base, $date);
	}
else {
	return ( );
	}
}

# tar_gzip_command(&vhost, directory, [file])
# Returns a command to create a tar.gz file of some directory, and optionally
# write to some file (otherwise stdout)
sub tar_gzip_command
{
my ($vhost, $dir, $file) = @_;
my $use_tar = !$config{'zip_args'} && &tar_supports_gzip($vhost);
if ($use_tar) {
	return "tar czf ".($file ? quotemeta($file) : "-")." ".$dir;
	}
else {
	return "tar cf - ".$dir." | gzip -c ".$config{'zip_args'}.
	       ($file ? " >".quotemeta($file) : "");
	}
}

# tar_gunzip_command(&vhost, [file])
# Returns a command to extract a tar.gz file (or stdin) into the current
# directory
sub tar_gunzip_command
{
my ($vhost, $file) = @_;
my $use_tar = &tar_supports_gzip($vhost);
if ($use_tar) {
	return "tar xpzf ".($file ? quotemeta($file) : "-");
	}
else {
	return "gunzip -c ".quotemeta($file)." | tar xpf -";
	}
}

# get_disk_include(&server, &disk)
# Returns 1 if some disk should be included in backups, 0 if not
sub get_disk_include
{
my ($server, $disk) = @_;
my $id = $disk->{'lv'} || $disk->{'real'};
return !$server->{'disk_exclude_'.$id};
}

# save_disk_include(&server, &disk, flag)
# Change the server-level setting that controls if  some disk should be
# included in backups
sub save_disk_include
{
my ($server, $disk, $inc) = @_;
my $id = $disk->{'lv'} || $disk->{'real'};
$server->{'disk_exclude_'.$id} = !$inc;
}

# should_include_disk(&server, &disk)
# Returns 1 if some disk should be included in backups
sub should_include_disk
{
my ($server, $disk) = @_;
return 0 if ($disk->{'swap'});
return 0 if (!&get_disk_include($server, $disk));
return 1;
}

# get_missing_backup_server(hostname, dest-str)
# If a deleted server was backed up to some destination, read it's .serv file
# and return
sub get_missing_backup_server
{
my ($hostname, $deststr) = @_;
my $server_deststr = $deststr;
$server_deststr .= "/".$hostname.".serv";
my $server_dest = &parse_backup_destination($server_deststr);
my $temp = &transname();
my $err = &get_from_backup_dest(&get_this_managed_server(),
				$temp,
				$server_dest);
return undef if ($err);
my $server = { };
&read_file($temp, $server);
return undef if (!$server->{'id'} || !$server->{'host'});
&unlink_file($temp);
$server->{'missing'} = 1;
my $vhost = &get_parent_server($server);
$server->{'status'} = $vhost ? 'down' : 'nohost';
return $server;
}

# get_missing_backup_server_disks(hostname, dest-str)
# Returns an array ref of disks that belonged to some system when it was
# backed up
sub get_missing_backup_server_disks
{
my ($hostname, $deststr) = @_;
my $disks_deststr = $deststr;
$disks_deststr .= "/".$hostname.".disks";
my $disks_dest = &parse_backup_destination($disks_deststr);
my $temp = &transname();
my $err = &get_from_backup_dest(&get_this_managed_server(),
                                $temp,
                                $disks_dest);
return undef if ($err);
my $disks = &unserialise_variable(&read_file_contents($temp));
&unlink_file($temp);
return ref($disks) ? $disks : undef;
}

# can_create_missing_backup_server(&server)
# Checks if some system being re-created from a backup can actually be created
sub can_create_missing_backup_server
{
my ($server) = @_;

# Check licence and system count limits
my ($ok, $err) = &can_create_server($server->{'manager'});
return $err if (!$ok);

# Check for ID clash
my $clash = &get_managed_server($server->{'id'});
$clash && return &text('rrun_eidclash', $server->{'id'}, $clash->{'host'});

# Check owner resource limits
my $limits = &get_owner_limits();
if ($limits) {
	# Validate disk limit
	my $dsfunc = "type_".$server->{'manager'}."_get_disk_size";
	my $incr = defined(&$dsfunc) ? &$dsfunc($server) : undef;
	if ($incr && $limits->{'max_disk'}) {
		# May be over disk limit
		if ($limits->{'disk'} + $incr > $limits->{'max_disk'}) {
			return &text('create_edisklimit',
			       &nice_size($limits->{'max_disk'}),
			       &nice_size($limits->{'disk'}));
			}
		}
	elsif (!$incr && $limits->{'max_disk'}) {
		# System has no disk limits, but owner does
		return &text('create_edisklimit2',
		       &nice_size($limits->{'max_disk'}));
		}

	# Validate RAM limit
	my $mfunc = "type_".$server->{'manager'}."_get_memory_size";
	$incr = defined(&$mfunc) ? &$mfunc($server) : undef;
	if ($incr && $limits->{'max_ram'}) {
		# May be over RAM limit
		if ($limits->{'ram'} + $incr > $limits->{'max_ram'}) {
			return &text('create_eramlimit',
			       &nice_size($limits->{'max_ram'}),
			       &nice_size($limits->{'ram'}));
			}
		}
	elsif (!$incr && $limits->{'max_ram'}) {
		# System has no RAM limits, but owner does
		return &text('create_eramlimit2',
		       &nice_size($limits->{'max_ram'}));
		}

	# Validate CPU limit
	$cfunc = "type_".$server->{'manager'}."_get_cpu_size";
	$incr = defined(&$cfunc) ? &$cfunc($server) : undef;
	if ($incr && $limits->{'max_cpu'}) {
		# May be over CPU limit
		if ($limits->{'cpu'} + $incr > $limits->{'max_cpu'}) {
			return &text('create_ecpulimit',
			       $limits->{'max_cpu'},
			       $limits->{'cpu'});
			}
		}
	elsif (!$incr && $limits->{'max_cpu'}) {
		# System has no CPU limit, but owner does
		return &text('create_ecpulimit2',
		       $limits->{'max_cpu'});
		}

	# Validate IPs limit, assuming new system will have exactly 1
	$incr = scalar(split(/\s+/, $server->{'ip_addresses'})) || 1;
	if ($limits->{'max_ips'}) {
		if ($limits->{'ips'} + $incr > $limits->{'max_ips'}) {
			return &text('create_eipslimit',
			       $limits->{'max_ips'},
			       $limits->{'ips'});
			}
		}
	}

# Check disk image directory
if ($server->{'directory'}) {
	my $err = &validate_directory($server);
	return &text('create_edirectory', $err) if ($err);
	}

# Must have an image
# XXX isn't really needed, but makes code below simpler
my $img = $server->{'image'} ? &get_server_image($server->{'image'}) : undef;
return $text{'rrun_erecreateimage'} if (!$img);

return undef;
}

# create_missing_backup_server(&server)
# Actually perform the process of creating a missing system. Returns 0 on
# failure, 1 on success
sub create_missing_backup_server
{
my ($server) = @_;
$server->{'status'} = 'create';

&obtain_lock_server($server);

# Run pre-creation script
if (!&run_system_script($server, 'before', 'create')) {
	return 0;
	}

# If there is an image file, copy to the server
my $vhost = &get_parent_server($server);
my $img = &get_server_image($server->{'image'});
if ($img) {
	&$first_print(&text('create_copying', &nice_size($img->{'size'}),
			    $vhost->{'host'}));
	($imageok, $imagetemp) = &transfer_image_files($server, 0);
	if ($imageok == 0) {
		# Copy failed
		print &text('create_ecopy', $imagetemp),"<p>\n";
		return 0;
		}
	else {
		$server->{'imagetemp'} = $imagetemp;
		$server->{'imagelocal'} = ($imageok != 1);
		&$second_print($imageok == 1 ? $text{'create_done'} :
			       $imageok == 2 ? $text{'create_nocopy'} :
			       $imageok == 3 ? $text{'create_incache'} :
					       $text{'create_addcache'});
		}
	}

# Call the server type's creation function, then wait for it to be come ready
my $tfunc = "type_".$server->{'manager'}."_desc";
&$first_print(&text('create_creating', &$tfunc()));
my $cfunc = "type_".$server->{'manager'}."_create";
my $err = &$cfunc($server, undef, undef, 0, 0, 1);
if ($err) {
	&$second_print(&text('create_ecreate', $err));
	return 0;
	}
my $dfunc = "type_".$server->{'manager'}."_create_done";
if (defined(&$dfunc)) {
	&$second_print($text{'create_created'});
	&$first_print($text{'create_waiting'});
	while(1) {
		$err = &$dfunc($server);
		if ($err eq "OK") {
			last;
			}
		elsif ($err) {
			if ($imageok == 1) {
				&cleanup_image_files($server, $imagetemp);
				}
			&$first_print(&text('create_ewait', $err));
			return 0;
			}
		sleep(1);
		}
	&$second_print($text{'create_waited'});
	}
else {
	&$second_print($text{'create_created2'});
	}
if ($imageok == 1) {
	&cleanup_image_files($server, $imagetemp);
	}
&complete_managed_server($server);
&save_managed_server($server);

# Remove old SSH keys for this system
&clear_ssh_host_key($server);
if ($vhost) {
	&clear_remote_ssh_host_key($server, $vhost);
	}

# Call any post-creation function
my $dfunc = "type_".$server->{'manager'}."_create_post";
if (defined(&$dfunc)) {
	&$dfunc($server, undef, undef, 0, 0, 1);
	}

# Call any really final post-creation function
my $dfunc = "type_".$server->{'manager'}."_create_ready";
if (defined(&$dfunc)) {
	&$dfunc($server);
	}

# Re-check and save the status
&$first_print($text{'add_statusing'});
&save_managed_server($server);
&check_server_status($server, 1);
&save_managed_server($server);
&$second_print(&text('add_statusok', &describe_status($server, 1)));

if ($vhost) {
	# Re-check and save the host status
	&$first_print(&text('add_statusing2', $vhost->{'host'}));
	&obtain_lock_server($vhost);
	&check_server_status($vhost);
	&save_managed_server($vhost);
	&release_lock_server($vhost);
	&$second_print(&text('add_statusok', &describe_status($vhost, 1)));
	}

# Forcibly shut down if running (shouldn't be, due to flag to create func)
if ($server->{'status'} ne 'down') {
	&$first_print(&text('brun_shutdown', $server->{'host'}));
	&shutdown_server($server, 1);
	&check_server_status($server, 0, 1);
	&save_managed_server($server);
	&$second_print($text{'create_done'});
	}

# Enable at boot time, if possible
my $bfunc = "type_".$server->{'manager'}."_set_atboot";
if (defined(&$bfunc)) {
	&$first_print($text{'create_atbooting'});
	&$bfunc($server, 1);
	&$second_print($text{'create_done'});
	}

# Create console user
$cfunc = "type_".$server->{'manager'}."_supports_console_login";
if (defined(&$cfunc)) {
	&$first_print($text{'create_consoleuser'});
	my $err = &create_console_user($server);
	if ($err) {
		&$second_print(&text('create_ecreate', $err));
		}
	else {
		&$second_print($text{'create_done'});
		}
	&save_managed_server($server);
	}

# Run post-creation script
&run_system_script($server, 'after', 'create');

# If restoring by an owner, grant to him
if ($access{'owner'}) {
	my $owner = &get_system_owner($base_remote_user);
	if ($owner) {
		&grant_to_system_owner($owner, $server);
		}
	}

$server->{'missing'} = 0;

return 1;
}

# create_missing_backup_server_disks(&server, &disks)
# Re-create any disks that belonged to a virtual system originally
sub create_missing_backup_server_disks
{
my ($server, $disks) = @_;
my $cfunc = "type_".$server->{'manager'}."_create_disk";
my $nfunc = "type_".$server->{'manager'}."_new_disk";
my $lfunc = "type_".$server->{'manager'}."_list_disks";
my $lasterr;
foreach my $disk (@$disks[1 .. (@$disks-1)]) {
	my $currentdisks = &$lfunc($server);
	return $currentdisks if (!ref($currentdisks));
	if ($disk->{'device'} && !$disk->{'lv'} && !$disk->{'storage'}) {
		# Just adding an existing file as a disk
		# XXX anything to do here?
		}
	else {
		# Creating a new disk file or LV
		my $newdisk = &$nfunc($server, $currentdisks, 0);
		$disk->{'real'} = $newdisk->{'real'};
		$disk->{'vg'} = $newdisk->{'vg'};
		$disk->{'lv'} = $newdisk->{'lv'};
		$disk->{'storage_id'} = $newdisk->{'storage_id'};
		}
	my ($already) = grep { $_->{'real'} eq $disk->{'real'} ||
			       $_->{'virt'} eq $disk->{'virt'} } @$currentdisks;
	if ($already) {
		# Disk already exists, perhaps a swap disk that got created
		# along with the system
		next;
		}
	my $err = &$cfunc($server, $disk);
	$lasterr ||= $err;
	}
return $lasterr;
}

1;

