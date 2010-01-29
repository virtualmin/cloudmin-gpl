# Functions for configuring and performing Cloudmin replication

# is_cloudmin_replica()
# Returns 1 if this system is a replica
sub is_cloudmin_replica
{
return $config{'repl_mode'} == 1 ? 1 : 0;
}

# list_replica_servers()
# Returns the list of system objects to replicate to
# XXX may include self?
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

# save_replica_servers(&servers)
# Updates the list of replication replicas
sub save_replica_servers
{
my ($replicas) = @_;
$config{'repl_replicas'} = join(" ", map { $_->{'id'} } @$replicas);
&save_module_config();
}

1;

