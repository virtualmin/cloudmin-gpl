# Functions for configuring and performing Cloudmin replication

# is_cloudmin_replica()
# Returns 1 if this system is a replica
sub is_cloudmin_replica
{
return &get_replication_mode() == 1 ? 1 : 0;
}

# get_replication_mode()
# Returns this system's replication mode. 0=None, 1=Replica, 2=Master
sub get_replication_mode
{
my $mode = &read_file_contents($repl_mode_file);
$mode =~ s/\r|\n//g;
return $mode || 0;
}

# save_replication_mode(mode)
# Saves the replication master / replica mode
sub save_replication_mode
{
my ($mode) = @_;
&open_tempfile(MODE, ">$repl_mode_file");
&print_tempfile(MODE, $mode);
&close_tempfile(MODE);
}

# get_replication_master()
# Returns the source host for replication to this system
sub get_replication_master
{
my $master = &read_file_contents($repl_master_file);
$master =~ s/\r|\n//g;
return $master;
}

# save_replication_master(host)
# Update the system that replication is coming from
sub save_replication_master
{
my ($master) = @_;
if ($master) {
	&open_tempfile(MASTER, ">$repl_master_file");
	&print_tempfile(MASTER, $master);
	&close_tempfile(MASTER);
	}
else {	
	&unlink_file($repl_master_file);
	}
}

# exit_if_cloudmin_replica()
# If this system is a replica, exit quietly. For calling from cron scripts.
sub exit_if_cloudmin_replica
{
exit(0) if (&is_cloudmin_replica());
}

# usage_if_cloudmin_replica()
# If a system is a replica, call &usage. For calling from API commands
sub usage_if_cloudmin_replica
{
&usage("This system is a Cloudmin replica - no changes are allowed")
	if (&is_cloudmin_replica());
}

# error_if_cloudmin_replica()
# If a system is a replica, call &error. For use by CGI scripts that would
# otherwise modify systems.
sub error_if_cloudmin_replica
{
&error($text{'repl_isreplica'}) if (&is_cloudmin_replica());
}

# list_replica_servers()
# Returns the list of system objects to replicate to
sub list_replica_servers
{
my @rv;
my $lref = &read_file_lines($repl_servers_file, 1);
foreach my $id (@$lref) {
	my $s = &get_managed_server($id);
	if ($s) {
		push(@rv, $s);
		}
	}
return @rv;
}

# save_replica_servers(&servers)
# Updates the list of servers to replicate to
sub save_replica_servers
{
my ($servers) = @_;
if ($servers) {
	&open_lock_tempfile(SERVERS, ">$repl_servers_file");
	foreach my $s (@$servers) {
		&print_tempfile(SERVERS, $s->{'id'},"\n");
		}
	&close_tempfile(SERVERS);
	}
else {
	&unlink_file($repl_servers_file);
	}
}

# replicate_to_servers(dry-run)
# Replicate all changed objects to all configured replicas, in parallel.
# Returns a list of replication status hash refs.
sub replicate_to_servers
{
my ($dryrun) = @_;
my @replicas = &list_replica_servers();
if (!@replicas) {
	return ( );
	}

# Test replication lock
if (&test_lock($repl_lock_file)) {
	return map { { 'ok' => 0,
		       'err' => $text{'repl_locked'},
		       'replica' => $_ } } @replicas;
	}
&lock_file($repl_lock_file);

my @rv;
if (@replicas == 1 && 0) {
	# Just do in this thread
	@rv = ( &replicate_to_one_server($replicas[0], $dryrun) );
	}
else {
	# Do in parallel
	@rv = map { $_->[0] }
		&parallel_server_function(\@replicas,
			\&replicate_to_one_server, $dryrun);
	}

&unlock_file($repl_lock_file);
return @rv;
}

# replicate_host_to_all_servers(&server, dry-run)
# Replicate changes to just one managed system to all replicas
sub replicate_host_to_all_servers
{
my ($changed, $dryrun) = @_;
my @replicas = &list_replica_servers();
if (!@replicas) {
	return ( );
	}
elsif (@replicas == 1) {
	# Just do in this thread
	return ( &replicate_host_to_one_server($replicas[0],
			[ $changed, $dryrun ]) );
	}
else {
	# Do in parallel
	return map { $_->[0] } 
		&parallel_server_function(\@replicas,
			\&replicate_host_to_one_server, [ $changed, $dryrun ]);
	}
}

# replicate_to_one_server(&server, dry-run)
# Replicate all changed objects to one replica. Returns a status hash ref
# with keys :
#  ok - 1 if all was OK, 0 if not
#  err - Error message on failure
#  replica - Object for this replica
#  servers - Objects for changed systems
#  copied - List of copied files
#  deleted - List of deleted files
sub replicate_to_one_server
{
my ($server, $dryrun) = @_;
my $rv = { 'replica' => $server,
	   'ok' => 0 };
if ($server->{'status'} ne 'virt' && $server->{'status'} ne 'novirt') {
	# Currently down, so do nothing
	$rv->{'err'} = $text{'repl_down'};
	return $rv;
	}

# Get files from remote system, if we can
$last_remote_error = undef;
&remote_foreign_require($server, "server-manager");
if ($last_remote_error) {
	# Cannot contact Webmin
	$rv->{'err'} = &text('repl_norequire', $last_remote_error);
	return $rv;
	}
my $isrepl = &remote_foreign_call($server, "server-manager",
					   "is_cloudmin_replica");
if (!$isrepl) {
	$rv->{'err'} = $text{'repl_notreplica'};
	return $rv;
	}
my @rfiles = &remote_foreign_call($server, "server-manager",
					   "get_last_modified_times");
if (@rfiles <= 1 || $last_remote_error) {
	$rv->{'err'} = &text('repl_nofiles',
			     $last_remote_error || $text{'repl_nofiles2'});
	return $rv;
	}
my %rfiles = map { $_->{'relfile'}, $_ } @rfiles;

# Get local files
my @lfiles = &get_last_modified_times();
my %lfiles = map { $_->{'relfile'}, $_ } @lfiles;

# Work out which directories must exist on remote already
my %made;
foreach my $r (@rfiles) {
	my $dir = $r->{'file'};
	$dir =~ s/\/([^\/]+)$//;
	$made{$dir}++;
	}

# For each local file that is newer, send it to the remote system
my $rconfig = $server->{'webmin_config_directory'} || "/etc/webmin";
my @tocopy;
my @servers;
foreach my $l (@lfiles) {
	my $r = $rfiles{$l->{'relfile'}};
	if (!$r || $r->{'time'} < $l->{'time'} ||
		   $r->{'size'} != $l->{'size'}) {
		# Work out destination path
		my $rfile = $r ? $r->{'file'} : undef;
		if (!$rfile && $l->{'relfile'} =~ /^\//) {
			# Copy to same path outside of /etc/webmin
			$rfile = $l->{'relfile'};
			}
		elsif (!$rfile && $l->{'relfile'} !~ /^\//) {
			# Copy to path relative to remove webmin config dir
			$rfile = $rconfig."/".$l->{'relfile'};
			}

		# Create dir if needed (if a sub-dir, and if not created yet)
		my $dir = $rfile;
		$dir =~ s/\/([^\/]+)$//;
		if ($dir !~ /^\Q$rconfig\E\/([^\/]+)$/ && !$made{$dir} &&
		    !$dryrun) {
			my $err = &make_dir_on_server($server, $dir, 0700, 1);
			if ($err) {
				$rv->{'err'} = &text('repl_mkdirfailed',
						     $dir, $err);
				return $rv;
				}
			$made{$dir}++;
			}

		# Add the file to the list to copy
		push(@tocopy, [ $l->{'file'}, $rfile ]);
		if ($l->{'server'}) {
			my $copiedserver = &get_managed_server($l->{'server'});
			if ($copiedserver) {
				push(@servers, $copiedserver);
				}
			}
		}
	}

# Actually copy all the files
if (!$dryrun && @tocopy) {
	my $err = &replicate_multiple_files($server, \@tocopy);
	if ($err) {
		$rv->{'err'} = &text('repl_copyfailed',
				     $lfile, $err);
		return $rv;
		}
	}
my @copied = map { $_->[0] } @tocopy;

# For any remote files that don't exist locally, delete them
my @deleted;
foreach my $r (@rfiles) {
	my $l = $lfiles{$r->{'relfile'}};
	if (!$l) {
		if (!$dryrun) {
			my $err = &delete_file_on_server($server, $r->{'file'});
			if ($err) {
				$rv->{'err'} = &text('repl_delfailed',
						     $r->{'file'}, $err);
				return $rv;
				}
			}
		push(@deleted, $r->{'file'});
		}
	}

# Create missing system owners on the remote system
my @rowners = &remote_foreign_call($server, "server-manager",
				   "list_system_owners");
my @lowners = &list_system_owners();
foreach my $lowner (@lowners) {
	my ($rowner) = grep { $_->{'name'} eq $lowner->{'name'} } @rowners;
	if (!$rowner || &hash_ref_differences($lowner, $rowner)) {
		&remote_foreign_call($server, "server-manager",
			"save_system_owner", $lowner, $rowner);
		}
	}

# Delete extra owners
foreach my $rowner (@rowners) {
	my ($lowner) = grep { $_->{'name'} eq $rowner->{'name'} } @lowners;
	if (!$lowner) {
		&remote_foreign_call($server, "server-manager",
			"delete_system_owner", $rowner);
		}
	}

# Call post-replication function to setup cron jobs / etc
my $this = &get_this_managed_server();
if (!$dryrun) {
	&remote_foreign_call($server, "server-manager", "replication_done",
			     $this->{'host'}, \@copied, \@deleted);
	}

# Return success
$rv->{'copied'} = \@copied;
$rv->{'deleted'} = \@deleted;
$rv->{'servers'} = \@servers;
$rv->{'ok'} = 1;
return $rv;
}

# replicate_host_to_one_server(&server, &changed-dry-run)
# Copy the details for just one managed system to a replica
sub replicate_host_to_one_server
{
my ($server, $cdr) = @_;
my ($changed, $dryrun) = @$cdr;
my $rv = { 'replica' => $server,
	   'ok' => 0,
	   'servers' => [ $changed ],
	 };
if ($server->{'status'} ne 'virt' && $server->{'status'} ne 'novirt') {
	# Currently down, so do nothing
	$rv->{'err'} = $text{'repl_down'};
	return $rv;
	}
my $rconfig = $server->{'webmin_config_directory'} || "/etc/webmin";
if ($changed->{'id'} eq '0') {
	$rv->{'err'} = $text{'repl_ethis'};
	return $rv;
	}
my @tocopy;
foreach my $lfile (&list_managed_server_files($changed)) {
	next if ($lfile =~ /\d+\-\d+$/);	# Exclude old history
	my $relfile = $lfile;
	$relfile =~ s/^\Q$config_directory\E\///;
	my $rfile = $relfile =~ /^\// ? $relfile : $rconfig.'/'.$relfile;
	push(@tocopy, [ $lfile, $rfile ]);
	}
if (!$dryrun && @tocopy) {
	my $err = &replicate_multiple_files($server, \@tocopy);
	if ($err) {
		$rv->{'err'} = &text('repl_copyfailed',
				     $lfile, $err);
		return $rv;
		}
	}
$rv->{'copied'} = [ map { $_->[0] } @tocopy ];
$rv->{'deleted'} = [ ];
$rv->{'ok'} = 1;
return $rv;
}

# replicate_multiple_files(&server, &files)
# Uploads multiple files to a Cloudmin replica, grouping them by directory
# to allow multiple in one scp command
sub replicate_multiple_files
{
my ($server, $files) = @_;

# Classify by directory
my %dirs;
foreach my $f (@$files) {
	my ($lfile, $rfile) = @$f;
	my $rdir = $rfile;
	$rdir =~ s/\/[^\/]+$//;
	$dirs{$rdir} ||= [ ];
	push(@{$dirs{$rdir}}, $f);
	}

# Issue scp commands
foreach my $rdir (keys %dirs) {
	my @files = map { $_->[0] } @{$dirs{$rdir}};
	my $err = &put_multiple_files_to_server($server, \@files, $rdir);
	return $err if ($err);
	}
return undef;
}

# get_last_modified_times()
# Returns a list of files used by Cloudmin and their last modification times.
# This is called on both the replication source and dest to compute what needs
# to be sent over.
sub get_last_modified_times
{
my (@files, @dirs);

# Build list of dirs to recurse into
push(@dirs, $ssh_keys_dir, $server_domains_dir, $server_collected_dir,
	    $historic_info_dir, $newfeatures_seen_dir, $usage_data_dir,
	    $bandwidth_dir, $shell_previous_dir, $owner_plans_dir,
	    $scheduled_backups_dir, $vsyncs_dir, $image_storages_dir,
	    $alerts_dir, $backup_log_dir, $scheduled_changes_dir,
	    $failover_groups_dir, $failover_files_dir, $status_history_dir,
	    $roundrobins_dir, $scalegroups_dir);
if ($ec2_accounts_dir) {
        push(@dirs, $ec2_accounts_dir);
        }
foreach my $p (@plugins) {
	if (&plugin_defined($p, "replication_dirs")) {
		push(@dirs, &plugin_call($p, "replication_dirs"));
		}
	}

# Search each one for files
foreach my $dir (@dirs) {
	push(@files, &recursive_search_dir($dir));
	}

# Add other config files
push(@files, $virtualmin_licences_file, $serial_cache_file,
	     $virtualmin_progress_file, $install_times_file,
	     $locations_file, $pools_file, $pools6_file,
	     $module_config_file, $default_search_file, $repl_servers_file,
	     $alert_status_file, $xen_cpu_seconds_file,
	     $server_images_cache,
	     "$module_config_directory/bw-template",
	     "$module_root_directory/owner-bw-template");
foreach my $p (@plugins) {
	if (&plugin_defined($p, "replication_files")) {
		push(@dirs, &plugin_call($p, "replication_files"));
		}
	}

# Add servers files
my %filemap;
foreach my $s (&list_managed_servers()) {
	if ($s->{'file'}) {
		push(@files, $s->{'file'});
		$filemap{$s->{'file'}} = $s->{'id'};
		}
	}

# Add image meta-files, and images stored on the cloudmin master
if (defined(&list_server_images)) {
	foreach my $i (&list_server_images()) {
		push(@files, $i->{'file'});
		my @imgfiles = split(/\s+/, $i->{'files'});
		foreach my $deststr (split(/\s+/, $i->{'dest'})) {
			my $dest = &parse_backup_destination($deststr);
			if ($dest->{'mode'} == 0) {
				foreach my $fl (@imgfiles) {
					push(@files, "$dest->{'path'}/$fl");
					}
				}
			}
		}
	}

# Remove files for 'this' system
@files = grep { $_ ne $server_collected_dir."/0" &&
		$_ ne $server_domains_dir."/0" &&
		$_ ne $usage_data_dir."/0" &&
		$_ !~ /\Q$historic_info_dir\E\/0\// } @files;

# Stat each file to get the time and size
my @rv;
foreach my $f (@files) {
	next if ($f =~ /\.(lock|bak|rpmsave|rpmnew)$/);
	my @st = stat($f);
	if (@st) {
		my $rf = $f;
		$rf =~ s/^\Q$config_directory\E\///;
		push(@rv, { 'file' => $f,
			    'relfile' => $rf,
			    'server' => $filemap{$f},
			    'time' => $st[9],
			    'size' => $st[7] });
		}
	}
return @rv;
}

# recursive_search_dir(dir)
# Recursively finds all files under some directory, and returns a list of them
sub recursive_search_dir
{
my ($dir) = @_;
opendir(DIR, $dir) || return ( );
my @files = readdir(DIR);
closedir(DIR);
my @rv;
foreach my $f (@files) {
	next if ($f eq "." || $f eq "..");
	my $path = "$dir/$f";
	if (-l $path) {
		# Skip links
		}
	elsif (-d $path) {
		# Recurse into
		push(@rv, &recursive_search_dir($path));
		}
	elsif (-f $path) {
		# Plain old file
		push(@rv, $path);
		}
	}
return @rv;
}

# replication_done(master, &copied-files, &deleted-files)
# Called by the replication master after some 
sub replication_done
{
my ($master, $copied, $deleted) = @_;
&foreign_require("cron", "cron-lib.pl");

# Flush any Webmin file caches, as files may have been over-written
&flush_webmin_caches();
%config = ( );
&read_file($module_config_file, \%config);

# Create or update cron jobs for backups
if (defined(&list_backups)) {
	my %backupids;
	foreach my $backup (&list_backups(1)) {
		&save_backup_cron($backup);
		if ($backup->{'enabled'}) {
			$backupids{$backup->{'id'}} = $backup;
			}
		}

	# Delete any backup.pl cron jobs that are no longer valid
	foreach my $job (&find_server_manager_cron_job($backup_cron_cmd)) {
		if ($job->{'command'} =~ /\-\-id\s+(\S+)/ && !$backupids{$1}) {
			&cron::delete_cron_job($job);
			}
		}
	}

if (defined(&list_virtualmin_syncs)) {
	# Create or update cron jobs for vsyncs
	my %vsyncids;
	foreach my $vsync (&list_virtualmin_syncs(1)) {
		&save_virtualmin_sync_cron($vsync);
		if ($vsync->{'enabled'}) {
			$vsyncids{$vsync->{'id'}} = $vsync;
			}
		}

	# Delete any vsync.pl cron jobs that are no longer valid
	foreach my $job (&find_server_manager_cron_job($vsync_cron_cmd)) {
		if ($job->{'command'} =~ /\-\-id\s+(\S+)/ && !$vsyncids{$1}) {
			&cron::delete_cron_job($job);
			}
		}
	}

if (defined(&setup_bandwidth_cron)) {
	# Setup or remove bandwidth cron job
	&setup_bandwidth_cron();
	}

&save_replication_master($master);
return undef;
}

1;

