# Functions for virtual system bandwidth monitoring
# - Every hour, poll all real interfaces and get byte counts
# - Compare with last run, if positive add to total for the day
# - Graphing per system / per period
# - Ability to email or shutdown system if over limit
# - Cron job to poll up systems
# - Support vservers and zones

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
		$rv[0] += $i->{'bytes_in'};
		$rv[1] += $i->{'bytes_out'};
		$rv[2] += $i->{'packets_in'};
		$rv[3] += $i->{'packets_out'};
		}
	return @rv;
	}
else {
	return ( );
	}
}

# get_bandwidth_message()
# Returns the message to send when a system exceeds it's bandwidth limit
sub get_bandwidth_message
{
local $f = "$module_config_directory/bw-template";
if (!-r $f) {
	$f = "$module_root_directory/bw-template";
	}
return &read_file_contents($f);
}

# save_bandwidth_message(msg)
# Save the email template for systems over their bandwidth quota
sub save_bandwidth_message
{
local ($msg) = @_;
&open_lock_tempfile(MSG, ">$module_config_directory/bw-template");
&print_tempfile(MSG, $msg);
&close_tempfile(MSG);
}

# find_bw_cron_job()
# Returns the job object for bandwidth monitoring
sub find_bw_cron_job
{
&foreign_require("cron", "cron-lib.pl");
local @jobs = &cron::list_cron_jobs();
local ($job) = grep { $_->{'user'} eq 'root' &&
		      $_->{'command'} = $bandwidth_cron_cmd } @jobs;
return $job;
}

1;

