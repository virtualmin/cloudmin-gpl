# Functions for configuring and performing Cloudmin replication

# is_cloudmin_replica()
# Returns 1 if this system is a replica
sub is_cloudmin_replica
{
return $config{'repl_mode'} == 1 ? 1 : 0;
}

# list_replica_servers()
# Returns the list of system objects to replicate to
sub list_replica_servers
{
my @rv;
foreach my $id (split(/\s+/, $config{'repl_replicas'})) {
	my $s = &get_managed_server($id);
	if ($s) {
		push(@rv, $s);
		}
	}
return @rv;
}

# replicate_to_servers()
# Replicate all changed objects to all configured replicas, in parallel.
# Returns a list of replication status hash refs.
sub replicate_to_servers
{
my @replicas = &list_replica_servers();
if (!@replicas) {
	return ( );
	}
elsif (@replicas == 1) {
	# Just do in this thread
	return ( &replicate_to_one_server($replicas[0]) );
	}
else {
	# Do in parallel
	return &parallel_server_function(\@replica, \&replicate_to_one_server);
	}
}

# replicate_to_one_server(&server)
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
my ($server) = @_;
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
my @rfiles = &remote_foreign_call($server, "get_last_modified_times");
if (@rfiles <= 1 || $last_remote_error) {
	$rv->{'err'} = &text('repl_nofiles', $last_remote_error);
	return $rv;
	}
my %rfiles = map { $_->{'relfile'}, $_ } @rfiles;

# Work out remote Webmin base dir
my $rconfig;
foreach my $r (@rfiles) {
	if ($r->{'file'} ne $r->{'relfile'}) {
		$rconfig = substr($r->{'file'}, 0, length($r->{'file'}) -
						   length($r->{'relfile'}));
		last;
		}
	}
if (!$rconfig || $rconfig !~ /^\//) {
	$rv->{'err'} = $text{'repl_norconfig'};
	return $rv;
	}

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
my @copied;
my @servers;
foreach my $l (@lfiles) {
	my $r = $rfiles{$l->{'relfile'}};
	if (!$r || $r->{'time'} != $l->{'time'} ||
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
		if ($dir !~ /^\Q$rconfig\E\/([^\/]+)$/ && !$made{$dir}) {
			my $err = &make_dir_on_server($server, $dir, 0700, 1);
			if ($err) {
				$rv->{'err'} = &text('repl_mkdirfailed',
						     $dir, $err);
				return $rv;
				}
			$made{$dir}++;
			}

		# Copy the file
		my $err = &put_file_to_server($server, $l->{'file'}, $rfile);
		if ($err) {
			$rv->{'err'} = &text('repl_copyfailed',
					     $l->{'file'}, $err);
			return $rv;
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
		my $err = &delete_file_on_server($server, $r->{'file'});
		if ($err) {
			$rv->{'err'} = &text('repl_delfailed',
					     $r->{'file'}, $err);
			return $rv;
			}
		}
	}

# XXX call post-replication function to setup cron jobs / etc

# Return success
$rv->{'copied'} = \@copied;
$rv->{'deleted'} = \@deleted;
$rv->{'servers'} = \@servers;
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
	     $module_config_file);

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

1;

