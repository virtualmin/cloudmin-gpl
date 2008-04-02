# Functions for virtual system bandwidth monitoring
# - Every hour, poll all real interfaces and get byte counts
# - Compare with last run, if positive add to total for the day
# - Graphing per system / per period
# - Ability to email or shutdown system if over limit
# - Support vservers and zones
# - Sum up for period, show in UI and list-systems.pl
# - Nice graphs

use Time::Local;

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
	local $ifaces = &$ifunc($server, $vhost);
	if (!ref($ifaces)) {
		return ( );
		}
	local @rv = ( 0, 0, 0, 0 );
	foreach my $i (@$ifaces) {
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
return &find_server_manager_cron_job($bandwidth_cron_cmd);
}

# get_bandwidth(&server)
# Returns the bandwidth usage object for some server
sub get_bandwidth
{
if (!defined($get_bandwidth_cache{$_[0]->{'id'}})) {
	local %bwinfo;
	&read_file("$bandwidth_dir/$_[0]->{'id'}", \%bwinfo);
	$get_bandwidth_cache{$_[0]->{'id'}} = \%bwinfo;
	}
return $get_bandwidth_cache{$_[0]->{'id'}};
}

# save_bandwidth(&server, &info)
sub save_bandwidth
{
&make_dir($bandwidth_dir, 0700);
&write_file("$bandwidth_dir/$_[0]->{'id'}", $_[1]);
$get_bandwidth_cache{$_[0]->{'id'}} ||= $_[1];
}

# get_bandwidth_time(&server)
# Returns the unix time of the last check for this server
sub get_bandwidth_time
{
local @st = stat("$bandwidth_dir/$_[0]->{'id'}");
return $st[9];
}

# describe_bandwidth_period(for-usage)
sub describe_bandwidth_period
{
local ($usage) = @_;
local $suffix = $usage ? 'bw_desc2' : 'bw_desc';
if ($config{'bw_period'}) {
	return &text($suffix.'_period', lc($config{'bw_period'}));
	}
else {
	return &text($suffix.'_days', $config{'bw_days'});
	}
}

# bandwidth_period_start([ago])
# Returns the unix time number on which the current (or some previous)
# bandwidth period started
sub bandwidth_period_start
{
local ($ago) = @_;
local $now = time();
local @tm = localtime(time());
local $day = timelocal(0, 0, 0, $tm[3], $tm[4], $tm[5]);  # Start of this day
local $rv;
if ($config{'bw_period'} eq 'week') {
	# Start on last sunday
	$rv = $day - $tm[6]*24*60*60;
	$rv -= $ago*7*24*60*60;
	}
elsif ($config{'bw_period'} eq 'month') {
	# Start at 1st of month
	for(my $i=0; $i<$ago; $i++) {
		$tm[4]--;
		if ($tm[4] < 0) {
			$tm[5]--;
			$tm[4] = 11;
			}
		}
	$rv = timelocal(0, 0, 0, 1, $tm[4], $tm[5]);
	}
elsif ($config{'bw_period'} eq 'year') {
	# Start at start of year
	$tm[4] -= $ago;
	$rv = timelocal(0, 0, 0, 1, 0, $tm[5]);
	}
else {
	# Start N days ago
	$rv = $day - $config{'bw_period'}*24*60*60;
	$rv -= $ago*$config{'bw_period'}*24*60*60;
	}
$rv = int($rv/3600)*3600;	# Round to hour, just in case
return $rv;
}

# bandwidth_period_end([ago])
# Returns the unix time on which some bandwidth period ends (inclusive)
sub bandwidth_period_end
{
local ($ago) = @_;
local $now = time();
if ($ago == 0) {
	# Current time
	$rv = $now;
	}
else {
	local $start = &bandwidth_period_start($ago);
	if ($config{'bw_period'} eq 'week') {
		# 7 days after start
		return $day + 7*24*60*60 - 1;
		}
	elsif ($config{'bw_period'} eq 'month') {
		# End of the month
		return &bandwidth_period_start($ago-1)-1;
		}
	elsif ($config{'bw_period'} eq 'year') {
		# End of the year
		return &bandwidth_period_start($ago-1)-1;
		}
	else {
		return $day + $config{'bw_days'}*24*60*60 - 1;
		}
	}
return $rv;
}



1;

