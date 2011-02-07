# Functions for virtual system bandwidth monitoring
# - Every hour, poll all real interfaces and get byte counts
# - Compare with last run, if positive add to total for the day
# - Graphing per system / per period
# - Ability to email or shutdown system if over limit
# - Support vservers and zones
# - Sum up for period, show in UI and list-systems.pl
# - Nice graphs

# get_server_traffic(&server)
# Returns the number of in and out bytes and packets for some virtual system,
# taken by sampling it's interface on the host system.
sub get_server_traffic
{
my ($server) = @_;
my $vhost = &get_parent_server($server);
return ( ) if (!$vhost && $server->{'manager'} ne 'real' &&
			  $server->{'manager'} ne 'this');
my $ifunc = "type_".$server->{'manager'}."_real_interfaces";
if (defined(&$ifunc)) {
	my $ifaces = &$ifunc($server, $vhost);
	if (!ref($ifaces)) {
		return ( );
		}
	my @rv = ( 0, 0, 0, 0 );
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
my $f = "$module_config_directory/bw-template";
if (!-r $f) {
	$f = "$module_root_directory/bw-template";
	}
return &read_file_contents($f);
}

# save_bandwidth_message(msg)
# Save the email template for systems over their bandwidth quota
sub save_bandwidth_message
{
my ($msg) = @_;
&open_lock_tempfile(MSG, ">$module_config_directory/bw-template");
&print_tempfile(MSG, $msg);
&close_tempfile(MSG);
}

# get_owner_bandwidth_message()
# Returns the message to send when an owner exceeds his bandwidth limit
sub get_owner_bandwidth_message
{
my $f = "$module_config_directory/owner-bw-template";
if (!-r $f) {
	$f = "$module_root_directory/owner-bw-template";
	}
return &read_file_contents($f);
}

# save_owner_bandwidth_message(msg)
# Save the email template for owners over their bandwidth quota
sub save_owner_bandwidth_message
{
my ($msg) = @_;
&open_lock_tempfile(MSG, ">$module_config_directory/owner-bw-template");
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
	my %bwinfo;
	&read_file("$bandwidth_dir/$_[0]->{'id'}", \%bwinfo);
	$get_bandwidth_cache{$_[0]->{'id'}} = \%bwinfo;
	}
return $get_bandwidth_cache{$_[0]->{'id'}};
}

# save_bandwidth(&server, &info)
# Updates collected bandwidth counts for some server
sub save_bandwidth
{
&make_dir($bandwidth_dir, 0700);
&write_file("$bandwidth_dir/$_[0]->{'id'}", $_[1]);
$get_bandwidth_cache{$_[0]->{'id'}} ||= $_[1];
}

# delete_bandwidth(&server)
# Remove all bandwidth counts for some server
sub delete_bandwidth
{
&unlink_file("$bandwidth_dir/$_[0]->{'id'}");
delete($get_bandwidth_cache{$_[0]->{'id'}});
}

# get_bandwidth_time(&server)
# Returns the unix time of the last check for this server
sub get_bandwidth_time
{
my @st = stat("$bandwidth_dir/$_[0]->{'id'}");
return $st[9];
}

# describe_bandwidth_period(for-usage)
sub describe_bandwidth_period
{
my ($usage) = @_;
my $suffix = $usage ? 'bw_desc2' : 'bw_desc';
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
my ($ago) = @_;
my $now = time();
my @tm = localtime(time());
my $day = timelocal(0, 0, 0, $tm[3], $tm[4], $tm[5]);  # Start of this day
my $rv;
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
my ($ago) = @_;
my $now = time();
if ($ago == 0) {
	# Current time
	$rv = $now;
	}
else {
	my $start = &bandwidth_period_start($ago);
	if ($config{'bw_period'} eq 'week') {
		# 7 days after start
		$rv = $start + 7*24*60*60 - 1;
		}
	elsif ($config{'bw_period'} eq 'month') {
		# End of the month
		$rv = &bandwidth_period_start($ago-1)-1;
		}
	elsif ($config{'bw_period'} eq 'year') {
		# End of the year
		$rv = &bandwidth_period_start($ago-1)-1;
		}
	else {
		$rv = $start + $config{'bw_days'}*24*60*60 - 1;
		}
	}
return $rv;
}

# bandwidth_usage_message(&server)
# Returns text describing usage over this period
sub bandwidth_usage_message
{
my ($server) = @_;
my $umsg = &nice_size($server->{'bw_usage'})." ".
	      &describe_bandwidth_period(1);
if ($server->{'bw_limit'} &&
    $server->{'bw_usage'} > $server->{'bw_limit'}) {
	# Over limit! Highlight it
	$umsg = "<font color=#ff0000>$umsg</font>";
	if ($server->{'bw_notify'}) {
		$umsg .= " (".&text('edit_lnotify',
			&make_date($server->{'bw_notify'})).")";
		}
	}
return $umsg;
}

# setup_bandwidth_cron()
# Create or delete the bandwidth monitoring cron job, based on the bw_enabled
# config flag.
sub setup_bandwidth_cron
{
my $job = &find_bw_cron_job();
if (!$job && $config{'bw_enabled'}) {
	# Create the job
	$job = { 'command' => $bandwidth_cron_cmd,
		 'user' => 'root',
		 'mins' => '2,7,12,17,22,27,32,37,42,47,52,57',
		 'hours' => '*',
		 'days' => '*',
		 'weekdays' => '*',
		 'months' => '*',
		 'active' => 1, };
	&lock_file(&cron::cron_file($job));
	&cron::create_cron_job($job);
	&cron::create_wrapper($bandwidth_cron_cmd, $module_name,"bandwidth.pl");
	&unlock_file(&cron::cron_file($job));
	}
elsif ($job && !$config{'bw_enabled'}) {
	# Delete the job
	&lock_file(&cron::cron_file($job));
	&cron::delete_cron_job($job);
	&unlock_file(&cron::cron_file($job));
	}
}


1;

