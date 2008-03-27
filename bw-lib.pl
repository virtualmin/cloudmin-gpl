# Functions for virtual system bandwidth monitoring
# - Every hour, poll all real interfaces and get byte counts
# - Compare with last run, if positive add to total for the day
# - Graphing per system / per period
# - Ability to email or shutdown system if over limit
# - Cron job to poll up systems

# get_server_traffic(&server)
# Returns the number of in and out bytes and packets for some virtual system,
# taken by sampling it's interface on the host system.
sub get_server_traffic
{
local ($server) = @_;
local $vhost = &get_parent_server($server);
return ( ) if (!$vhost);
local $ifunc = "type_".$server->{'manager'}."_real_interfaces";
if (defined(&$ifunc)) {
	local @ifaces = &$ifunc($server, $vhost);
	local @rv = ( 0, 0, 0, 0 );
	foreach my $i (@ifaces) {
		# XXX
		}
	return @rv;
	}
else {
	return ( );
	}
}

1;

