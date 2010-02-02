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
elsif (@replicas == 1) {
	# Just do in this thread
	return ( &replicate_to_one_server($replicas[0], $dryrun) );
	}
else {
	# Do in parallel
	return map { $_->[0] }
		&parallel_server_function(\@replica,
			\&replicate_to_one_server, $dryrun);
	}
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
	return ( &replicate_host_to_one_server($replicas[0], $changed) );
	}
else {
	# Do in parallel
	return map { $_->[0] } 
		&parallel_server_function(\@replica,
			\&replicate_host_to_one_server, $changed);
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
my @copied;
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

		# Copy the file
		if (!$dryrun) {
			my $err = &put_file_to_server(
				$server, $l->{'file'}, $rfile);
			if ($err) {
				$rv->{'err'} = &text('repl_copyfailed',
						     $l->{'file'}, $err);
				return $rv;
				}
			}
		push(@copied, $l->{'file'});
		if ($l->{'server'}) {
			my $copiedserver = &get_managed_server($l->{'server'});
			if ($copiedserver) {
				push(@servers, $copiedserver);
				}
			}
		}
	}

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

# Call post-replication function to setup cron jobs / etc
my $this = &get_this_managed_server();
if ((scalar(@copied) || scalar(@deleted)) && !$dryrun) {
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

# replicate_host_to_one_server(&server, &changed)
# Copy the details for just one managed system to a replica
sub replicate_host_to_one_server
{
my ($server, $changed) = @_;
my $rv = { 'replica' => $server,
	   'ok' => 0 };
my $rconfig = $server->{'webmin_config_directory'} || "/etc/webmin";

# XXX to what directory though?
# XXX copy main file
# XXX copy bandwidth / etc too

$rv->{'ok'} = 1;
return $rv;
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
	    $bandwidth_dir, $shell_previous_dir, $owner_plans_dir,
	    $scheduled_backups_dir, $vsyncs_dir, $image_storages_dir,
	    $alerts_dir);
if ($ec2_accounts_dir) {
        push(@dirs, $ec2_accounts_dir);
        }

# Search each one for files
foreach my $dir (@dirs) {
	push(@files, &recursive_search_dir($dir));
	}

# Add other config files
push(@files, $virtualmin_licences_file, $locations_file, $pools_file,
	     $module_config_file, $default_search_file, $repl_servers_file);

# Add servers files
my %filemap;
foreach my $s (&list_managed_servers()) {
	if ($s->{'file'}) {
		push(@files, $s->{'file'});
		$filemap{$s->{'file'}} = $s->{'id'};
		}
	}

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

# Update cron jobs
# XXX

&save_replication_master($master);
return undef;
}

1;

