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
sub replicate_to_one_server
{
my ($server) = @_;
my $rv = { 'replica' => $server };

foreach my $s (&list_managed_servers()) {
	}

# XXX call post-replication function to setup cron jobs / etc

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
push(@files, map { $_->{'file'} }
		 grep { $_->{'file'} } &list_managed_servers());

# Stat each file to get the time and size
my @rv;
foreach my $f (@files) {
	next if ($f =~ /\.(lock|bak|rpmsave|rpmnew)$/);
	my @st = stat($f);
	if (@st) {
		push(@rv, [ $f, $st[9], $st[7] ]);
		}
	}
return @rv;
}

1;

