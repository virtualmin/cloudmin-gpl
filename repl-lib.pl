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

# XXX call post-replication function to setup cron jobs / etc

return $rv;
}

1;

