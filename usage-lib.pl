# Functions for collecting virtual system run-time usage

# get_server_usage(&server)
# Returns a list of usage samples for a system, each of which is a hash ref
# with the following keys :
#   start - Unix time the sample begins
#   end - Unix time it ends
#   up - Set to 1 if running
#   mem - Bytes of memory allocated during the sample
#   disk - Bytes of disk allocated (typically as seen on host system)
#   space - Bytes of disk used (as seen on host system)
#   cores - CPU cores allocated
#   cpu - Average percentage of CPU used
# Each represents the time some system was known to be running or down with
# a given memory and CPU allocation (if available)
sub get_server_usage
{
my ($server) = @_;
my @rv;
open(USAGE, "$usage_data_dir/$server->{'id'}");
while(<USAGE>) {
	s/\r|\n//g;
	my %u = map { split(/=/, $_) } split(/\s+/, $_);
	push(@rv, \%u);
	}
close(USAGE);
return @rv;
}

# save_server_usage(&server, &usages)
# Write out all usage data for some system
sub save_server_usage
{
my ($server, $usages) = @_;
if (!-d $usage_data_dir) {
	&make_dir($usage_data_dir, 0700);
	}
&open_tempfile(USAGE, ">$usage_data_dir/$server->{'id'}");
foreach my $usage (@$usages) {
	&print_tempfile(USAGE, &usage_line($usage),"\n");
	}
&close_tempfile(USAGE);
}

# append_server_usage(&server, &usage)
# Append one usage sample for a system to its data file
sub append_server_usage
{
my ($server, $usage) = @_;
if (!-d $usage_data_dir) {
	&make_dir($usage_data_dir, 0700);
	}
&open_tempfile(USAGE, ">>$usage_data_dir/$server->{'id'}");
&print_tempfile(USAGE, &usage_line($usage),"\n");
&close_tempfile(USAGE);
}

# usage_line(&usage)
# Convert a usage sample into a line of text
sub usage_line
{
my ($usage) = @_;
return join(" ", map { $_."=".$usage->{$_} }
	     &unique("start", "end", "up", sort { $a cmp $b } keys %$usage));
}

# update_server_usage(&server, &usage)
# Replace the last usage sample line with the one given
sub update_server_usage
{
my ($server, $usage) = @_;
my $pos = &find_last_usage_pos($server);
if ($pos >= 0) {
	open(USAGE, "+<$usage_data_dir/$server->{'id'}");
	seek(USAGE, $pos, 0);
	truncate(USAGE, $pos);
	print USAGE &usage_line($usage),"\n";
	close(USAGE);
	}
else {
	&append_server_usage($server, $usage);
	}
}

# last_server_usage(&server)
# Returns the last usage sample for some server
sub last_server_usage
{
my ($server) = @_;
my $pos = &find_last_usage_pos($server);
return undef if ($pos < 0);
open(USAGE, "$usage_data_dir/$server->{'id'}");
seek(USAGE, $pos, 0);
my $line = <USAGE>;
close(USAGE);
$line =~ s/\r|\n//g;
my %u = map { split(/=/, $_) } split(/\s+/, $line);
return \%u;
}

# find_last_usage_pos(&server)
# Returns the byte offset of the last line of usage data, or -1 if none
sub find_last_usage_pos
{
my ($server) = @_;
my $file = "$usage_data_dir/$server->{'id'}";
my @st = stat($file);
return -1 if (!@st || $st[7] == 0);
open(USAGE, $file);
if ($st[7] > 1024) {
	seek(USAGE, -1024, 2);
	}
my @lines = <USAGE>;
close(USAGE);
return $st[7] - length($lines[$#lines]);
}

# refresh_server_usage(&server, [time])
# Checks the current state of some server, and adds or updates a usage entry
# for it.
sub refresh_server_usage
{
my ($server, $now) = @_;
$now ||= time();
my $usage = &last_server_usage($server);
my $info;

# Get current status and usage
my $up = $server->{'status'} ne 'down' &&
         $server->{'status'} ne 'nohost' ? 1 : 0;
my ($mem, $cpu, $cores, $load, $loadtime, $disk, $space);
if ($up) {
	# Get memory allocated to system, or physcially installed
	my $mfunc = "type_".$server->{'manager'}."_get_memory";
	if (defined(&$mfunc)) {
		$mem = &$mfunc($server);
		}
	if (!$mem) {
		# Get from collected info
		$info ||= &get_server_collected($server);
		if ($info->{'mem'} && $info->{'mem'}->[0]) {
			$mem = $info->{'mem'}->[0] * 1024;
			}
		}

	# Get percentage of CPU allocated
	my $cfunc = "type_".$server->{'manager'}."_get_cpu";
	if (defined(&$cfunc)) {
		($cpu) = &$cfunc($server);
		$cpu ||= 100;
		}

	# Get actual CPU usage
	my $sfunc = "type_".$server->{'manager'}."_get_cpu_load";
	if (defined(&$sfunc)) {
		($load, $loadtime) = &$sfunc($server);
		}
	if (!defined($load)) {
		# Get from collected info instead
		$info ||= &get_server_collected($server);
		if ($info->{'load'} && $info->{'load'}->[0] ne '') {
			$load = int($info->{'load'}->[0]*100);
			if ($usage) {
				# Assume the load is over the time period
				# since the last usage sample
				$loadtime = $now - $usage->{'end'};
				}
			}
		}

	# Get disk size
	my $dfunc = "type_".$server->{'manager'}."_get_disk_size";
	if (defined(&$dfunc)) {
		$disk = &$dfunc($server);
		}

	# Get disk usage, rounded to the MB to avoid small changes
	my $sfunc = "type_".$server->{'manager'}."_get_disk_space";
	if (defined(&$sfunc)) {
		$space = &$sfunc($server);
		$space = int($space / (1024*1024)) * (1024*1024);
		}
	}

my $extend = 0;
if ($usage && $usage->{'up'} && $up) {
	# Can just extend current sample, if memory and CPU are same
	if ($cores == $usage->{'cores'} &&
	    $cpu == $usage->{'cpu'} &&
	    ($load == $usage->{'load'} || $loadtime) &&
	    $mem == $usage->{'mem'} &&
	    $disk == $usage->{'disk'} &&
	    $space == $usage->{'space'}) {
		$extend = 1;
		}
	}
elsif ($usage && !$usage->{'up'} && !$up) {
	# Was down, still down .. can extend
	$extend = 1;
	}
if ($extend && $up && $usage && $usage->{'start'} < $now-3600) {
	# If last sample was more than 1 hour long, start a new one
	$extend = 0;
	}
if ($extend) {
	# Update last sample
	$usage->{'end'} = $now;
	if (defined($load)) {
		# Re-compute the CPU load for this period
		$usage->{'load'} = ($usage->{'load'} * $usage->{'loadtime'} +
				    $load * $loadtime) / 
				   ($usage->{'loadtime'} + $loadtime);
		$usage->{'loadtime'} += $loadtime;
		}
	&update_server_usage($server, $usage);
	}
else {
	# Create a new one
	my $newusage = { 'up' => $up,
			 'start' => $usage ? $usage->{'end'} : $now,
			 'end' => $now };
	$newusage->{'mem'} = $mem if (defined($mem));
	$newusage->{'disk'} = $disk if (defined($disk));
	$newusage->{'space'} = $space if (defined($space));
	$newusage->{'cpu'} = $cpu if (defined($cpu));
	$newusage->{'cores'} = $cores if (defined($cores));
	if (defined($load)) {
		$newusage->{'load'} = $load;
		$newusage->{'loadtime'} = $loadtime;
		}
	&append_server_usage($server, $newusage);
	}
}

# nice_hour_mins_secs(unixtime)
# Convert a number of seconds into an HH hours, MM minutes, SS seconds format
sub nice_hour_mins_secs
{
my ($time) = @_;
my $days = int($time / (24*60*60));
my $hours = int($time / (60*60)) % 24;
my $mins = sprintf("%2.2d", int($time / 60) % 60);
my $secs = sprintf("%2.2d", int($time) % 60);
if ($days) {
	return &text('nicetime_days', $days, $hours, $mins, $secs);
	}
elsif ($days || $hours) {
	return &text('nicetime_hours', $hours, $mins, $secs);
	}
else {
	return &text('nicetime_mins', $mins, $secs);
	}
}

# sum_usage_over_period(&usage, start, end, what)
# For usage samples over some period, returns the sum of the what parameter
# times the length of samples.
sub sum_usage_over_period
{
my ($usage, $start, $end, $what) = @_;
my $rv = 0;
foreach my $u (@$usage) {
	next if ($u->{'start'} > $end);
	next if ($u->{'end'} < $start);
	my $len = $u->{'end'} - $u->{'start'};
	if ($u->{'start'} < $start) {
		# Sample starts before start time .. cut off that piece
		$len -= ($start - $u->{'start'});
		}
	if ($u->{'end'} > $end) {
		# Sample starts after end time .. cut off that piece
		$len -= ($u->{'end'} - $end);
		}
	$rv += $u->{$what} * $len;
	}
return $rv;
}

# usage_period_start_end(&usage, [ago])
# Returns start and end times for usage display. The start will be start of
# the current accounting period or the oldest sample, whichever is newer
sub usage_period_start_end
{
my ($usage, $ago) = @_;
my $start = &bandwidth_period_start($ago);
my $end = $ago ? &bandwidth_period_start($ago-1) : time();
my $len = scalar(@$usage);
if ($len && $start < $usage->[0]->{'start'}) {
	# Cannot be older than first sample
	$start = $usage->[0]->{'start'};
	}
if ($len && $end > $usage->[$len-1]->{'end'}) {
	$end = $usage->[$len-1]->{'end'};
	}
return ($start, $end);
}

1;

