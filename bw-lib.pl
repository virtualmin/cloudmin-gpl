# Functions for virtual system bandwidth monitoring

# can_get_server_traffic(&server)
# Returns 1 if bandwidth monitoring is possible for a system
sub can_get_server_traffic
{
my ($server) = @_;
my $ifunc = "type_".$server->{'manager'}."_real_interfaces";
return defined(&$ifunc);
}

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

# get_bandwidth(&server, [start, end])
# Returns the bandwidth usage object for some server
sub get_bandwidth
{
my ($server, $start, $end) = @_;

# Find files for the server that fall within the time range
$get_bandwidth_cache{$server->{'id'}} ||= { };
foreach my $f (glob("$bandwidth_dir/$server->{'id'}-*"),
	       "$bandwidth_dir/$server->{'id'}") {
	next if ($get_bandwidth_cache_file{$f});	# In cache already
	my $want = 0;
	if ($f =~ /\-(\d+)\-(\d+)$/) {
		# Has a time range .. do we want it?
		my ($fstart, $fend) = ($1, $2);
		if (defined($start) && $start > $fend ||
		    defined($end) && $end < $fstart) {
			# Desired start range is beyond the end of this file,
			# or vice-versa .. skip it
			$want = 0;
			}
		else {
			$want = 1;
			}
		}
	else {
		# Assume yes (like for the latest file)
		$want = 1;
		}
	if ($want) {
		&read_file($f, $get_bandwidth_cache{$server->{'id'}});
		$get_bandwidth_cache_file{$f} = 1;
		}
	}
return $get_bandwidth_cache{$server->{'id'}};
}

# get_owner_bandwidth(&owner, start, end)
# Returns all bandwidth samples within some time period that are accounted to
# a system owner. Multiple samples for the same hour or minute are summed up.
sub get_owner_bandwidth
{
my ($owner, $start, $end) = @_;
my %canservers = map { $_, 1 } split(/\s+/, $owner->{'acl'}->{'servers'});
my %rv;
foreach my $id (split(/\s+/, $owner->{'acl'}->{'everservers'})) {
	my $fake = { 'id' => $id };
	my $sbw = &get_bandwidth($fake, $start, $end);
	foreach my $k (keys %$sbw) {
		if ($k =~ /^(hour|min)_(in|out|inp|outp)_(\d+)/ &&
		    $sbw->{$1.'_owner_'.$3} eq $owner->{'name'}) {
			# Hour or minute was tagged with this owner
			$rv{$k} += $sbw->{$k};
			}
		elsif ($k =~ /^(hour|min)_(in|out|inp|outp)_(\d+)/ &&
		       !$sbw->{$1.'_owner_'.$3} &&
		       $canservers{$id}) {
			# Not tagged with any owner, but system belongs
			# to this owner currently
			$rv{$k} += $sbw->{$k};
			}
		elsif ($k =~ /^old_(min|hour)/ &&
		       (!$rv{$k} || $sbw->{$k} < $rv{$k})) {
			# Oldest hour or minute - include in response
			$rv{$k} = $sbw->{$k};
			}
		elsif ($k =~ /^new_(min|hour)/ &&
		       (!$rv{$k} || $sbw->{$k} > $rv{$k})) {
			# Newest hour or minute - include in response
			$rv{$k} = $sbw->{$k};
			}
		}
	}
return \%rv;
}

# append_bandwidth(&server, &new-info, &delete-info, [force-rotation])
# Update counts for new bandwidth collection
sub append_bandwidth
{
my ($server, $info, $delinfo, $forcerotate) = @_;
if (!-d $bandwidth_dir) {
	&make_dir($bandwidth_dir, 0700);
	}

# Update latest bandwidth file with new data
my $oldinfo = { };
my $file = "$bandwidth_dir/$server->{'id'}";
&read_file($file, $oldinfo);
my $cache = $get_bandwidth_cache{$server->{'id'}};
foreach my $k (keys %$info) {
	if ($k =~ /^(min|hour)_(in|out)/) {
		# Increment time-based counter
		$oldinfo->{$k} += $info->{$k};
		}
	else {
		# Overwrite other value, like last time written
		$oldinfo->{$k} = $info->{$k};
		}
	if ($cache) {
		$cache->{$k} = $oldinfo->{$k};
		}
	}
foreach my $k (@$delinfo) {
	delete($oldinfo->{$k});
	}
$oldinfo->{'first_time'} ||= &compute_first_bandwidth_time($oldinfo);
&write_file($file, $oldinfo);

# If first event in file is older than rotation time, rename the file
if ($oldinfo->{'first_time'} &&
    (time() - $oldinfo->{'first_time'} > $historic_rotation_time ||
     $forcerotate)) {
	my $newfile = $file."-".$oldinfo->{'first_time'}."-".time();
	rename($file, $newfile);
	delete($get_bandwidth_cache_file{$file});
	$get_bandwidth_cache_file{$newfile} = 1;

	# Populate non-time-based counters in the new file, and hour/minute
	# counters from the most recent hour so that they can be properly
	# incremented
	my $newinfo = { };
	foreach my $k (keys %$info) {
		if ($k !~ /^(min|hour)_/) {
			# Stat like last_* for previous byte or packet counts
			$newinfo->{$k} = $info->{$k};
			}
		elsif ($k =~ /^hour_\S+_(\d+)$/ && $1 eq $info->{'new_hour'} ||
		       $k =~ /^min_\S+_(\d+)$/ && $1 eq $info->{'new_min'}) {
			# Most recent minute or hour stat
			$newinfo->{$k} = $info->{$k};
			}
		}
	&write_file($file, $newinfo);
	}
}

# compute_first_bandwidth_time(&bw-info)
# Returns the minimum time for a bandwidth stat
sub compute_first_bandwidth_time
{
my ($info) = @_;
my $min = undef;
foreach my $k (keys %$info) {
	if ($k =~ /^(hour|min)_in_(\d+)/ && ($2 < $min || !defined($min))) {
		$min = $2;
		}
	}
return $min;
}

# delete_bandwidth(&server)
# Remove all bandwidth counts for some server
sub delete_bandwidth
{
foreach my $f (glob("$bandwidth_dir/$_[0]->{'id'}-*"),
	       "$bandwidth_dir/$_[0]->{'id'}") {
	&unlink_file($f);
	}
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
if ($config{'bw_period'} eq 'day') {
	# Start on at midnight
	$rv = $day;
	$rv -= $ago*24*60*60;
	}
elsif ($config{'bw_period'} eq 'week') {
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
	$rv = $day - $ago*$config{'bw_days'}*24*60*60;
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
	if ($config{'bw_period'} eq 'day') {
		# 1 day after start
		$rv = $start + 24*60*60 - 1;
		}
	elsif ($config{'bw_period'} eq 'week') {
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
my $job = &find_cron_script($bandwidth_cron_cmd);
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
	&setup_cron_script($job);
	}
elsif ($job && !$config{'bw_enabled'}) {
	# Delete the job
	&delete_cron_script($job);
	}
}


1;

