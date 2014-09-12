# Functions for managing historic data

# add_historic_collected_info(&info, time, &server, [&only-stats])
# Log some historic data for a Cloudmin-monitored system
sub add_historic_collected_info
{
my ($info, $time, $server, $only) = @_;

# Add disk usage, CPU and memory to historic stats, if we got them
if (!-d $historic_info_dir) {
        &make_dir($historic_info_dir, 0700);
        }
if (!-d "$historic_info_dir/$server->{'id'}") {
	&make_dir("$historic_info_dir/$server->{'id'}", 0700);
	}
my @stats;

# Add CPU load
if ($info->{'load'}) {
	push(@stats, [ "load", $info->{'load'}->[0] ]);
	push(@stats, [ "load5", $info->{'load'}->[1] ]);
	push(@stats, [ "load15", $info->{'load'}->[2] ]);
	}

# Add memory usage
if ($info->{'mem'}) {
        push(@stats, [ "memused",
                       ($info->{'mem'}->[0]-$info->{'mem'}->[1])*1024 ]);
	push(@stats, [ "memtotal",
                       $info->{'mem'}->[0]*1024 ]);
	push(@stats, [ "memfree", $info->{'mem'}->[1]*1024 ]);
	push(@stats, [ "memratio", ($info->{'mem'}->[0]-$info->{'mem'}->[1]) /
				   $info->{'mem'}->[0] ]);
        if ($info->{'mem'}->[2]) {
                push(@stats, [ "swapused",
                              ($info->{'mem'}->[2]-$info->{'mem'}->[3])*1024 ]);
		push(@stats, [ "swaptotal",
                               $info->{'mem'}->[2]*1024 ]);
                push(@stats, [ "swapfree", $info->{'mem'}->[2]*1024 ]);
		push(@stats, [ "swapratio",
			       ($info->{'mem'}->[2]-$info->{'mem'}->[3]) /
			       $info->{'mem'}->[2] ]);
                }
        if ($info->{'mem'}->[4] ne '') {
		push(@stats, [ "memcached", $info->{'mem'}->[4]*1024 ]);
		}
        if ($info->{'mem'}->[5] ne '') {
		push(@stats, [ "memburst", $info->{'mem'}->[5]*1024 ]);
		}
        }

# Add memory usage for hosting
foreach my $manager (&is_parent_server($server)) {
	if ($server->{$manager.'_mem_free'}) {
		push(@stats, [ "hostmemused",$server->{$manager.'_mem_total'} -
					     $server->{$manager.'_mem_free'} ]);
		push(@stats, [ "hostmemfree",$server->{$manager.'_mem_free'} ]);
		last;
		}
	}

# Add disk usage
if ($info->{'disk_total'}) {
        push(@stats, [ "diskused",
                       $info->{'disk_total'}-$info->{'disk_free'},
                       $info->{'disk_total'} ]);
        push(@stats, [ "diskfree", $info->{'disk_free'} ]);
	push(@stats, [ "diskratio",
		       ($info->{'disk_total'}-$info->{'disk_free'}) /
		       $info->{'disk_total'} ]);
        }

# Add root FS usage
if ($info->{'disk_list'}) {
	my ($root) = grep { $_->{'fs'} eq '/' } @{$info->{'disk_list'}};
	if ($root) {
		push(@stats, [ "rootdiskused",
			       $root->{'total'} - $root->{'free'},
			       $root->{'total'} ]);
		push(@stats, [ "rootdiskfree", $root->{'free'} ]);
		}
	}

# Add disk usage for hosting
foreach my $manager (&is_parent_server($server)) {
	my ($free, $total) = &host_free_disk($server, $manager);
	if ($total) {
		push(@stats, [ "hostdiskused", $total - $free ]);
		push(@stats, [ "hostdiskfree", $free ]);
		last;
		}
	}

# Add virtualmin domains
if ($info->{'fcount'}) {
	push(@stats, [ "doms", int($info->{'fcount'}->{'doms'}) ]);
	push(@stats, [ "users", int($info->{'fcount'}->{'users'}) ]);
	push(@stats, [ "aliases", int($info->{'fcount'}->{'aliases'}) ]);
	}

# Add Virtualmin disk quotas
if ($info->{'quota'}) {
	my $qlimit = 0;
	my $qused = 0;
	foreach my $q (@{$info->{'quota'}}) {
		$qlimit += $q->[2];
		$qused += $q->[1]+$q->[3];
		}
	push(@stats, [ "quotalimit", $qlimit ]);
	push(@stats, [ "quotaused", $qused ]);
	}

# Add system temperatures
foreach my $tt ("drive", "cpu") {
	if ($info->{$tt.'temps'}) {
		my ($temptotal, $tempcount);
		foreach my $t (@{$info->{$tt.'temps'}}) {
			$temptotal += $t->{'temp'};
			$tempcount++;
			}
		if ($temptotal) {
			push(@stats, [ $tt."temp", $temptotal / $tempcount ]);
			}
		}
	}

# Add IO blocks
if ($info->{'io'}) {
	push(@stats, [ "bin", $info->{'io'}->[0] ]);
	push(@stats, [ "bout", $info->{'io'}->[1] ]);
	}

# Add CPU user and IO time
if ($info->{'cpu'}) {
	push(@stats, [ "cpuuser", $info->{'cpu'}->[0] ]);
	push(@stats, [ "cpukernel", $info->{'cpu'}->[1] ]);
	push(@stats, [ "cpuidle", $info->{'cpu'}->[2] ]);
	push(@stats, [ "cpuio", $info->{'cpu'}->[3] ]);
	}

# Add up/down status
if ($server->{'status'} eq 'down') {
	push(@stats, [ "up", 0 ]);
	push(@stats, [ "down", 1 ]);
	}
elsif ($server->{'status'} eq 'nossh' ||
       $server->{'status'} eq 'noping') {
	push(@stats, [ "up", 0.5 ]);
	push(@stats, [ "down", 0.5 ]);
	}
else {
	push(@stats, [ "up", 1 ]);
	push(@stats, [ "down", 0 ]);
	}

# Add network traffic in and out in bytes / second, taken from the last minute
# sample (unless more than 1 hour old)
if ($config{'bw_enabled'} &&
    $server->{'status'} ne 'down' && $server->{'status'} ne 'nohost') {
	my $bwinfo = &get_bandwidth($server, time()-3600, undef);
	if ($bwinfo->{'new_min'} &&
	    $time - $bwinfo->{'new_min'} < 3600) {
		push(@stats, [ "bwin",
			int($bwinfo->{'min_in_'.$bwinfo->{'new_min'}} / 60) ]);
		push(@stats, [ "bwout",
			int($bwinfo->{'min_out_'.$bwinfo->{'new_min'}} / 60) ]);
		}
	}

# Limit to selected stats, if requested
if ($only) {
	@stats = grep { $only->{$_->[0]} } @stats;
	}

# Save historic stats
foreach my $stat (@stats) {
	open(HISTORY, ">>$historic_info_dir/$server->{'id'}/$stat->[0]");
        print HISTORY $time," ",$stat->[1],"\n";
        close(HISTORY);
	}

# If current file is now too old, rotate it
foreach my $stat (@stats) {
	my $statfile = "$historic_info_dir/$server->{'id'}/$stat->[0]";
	open(HISTORY, $statfile);
	my $first = <HISTORY>;
	close(HISTORY);
	my ($sfirsttime, undef) = split(" ", $first);
	if ($time - $sfirsttime > $historic_rotation_time) {
		rename($statfile, $statfile.".".$sfirsttime."-".$time);
		}
	}

# Delete old history files
&cleanup_old_history_files("$historic_info_dir/$server->{'id'}",
			   ".*-.*");
}

# list_historic_collected_info(stat, &server, [start], [end])
# Returns an array of times and values for some stat and server, within a given
# time period
sub list_historic_collected_info
{
my ($stat, $server, $start, $end) = @_;
my @rv;
my $serverdir = "$historic_info_dir/$server->{'id'}";
opendir(SERVERDIR, $serverdir);
my @files = grep { $_ eq $stat ||
		   substr($_, 0, length($stat)+1) eq $stat."." }
		 readdir(SERVERDIR);
closedir(SERVERDIR);
my $now = time();
@files = sort { my $ta = $a =~ /\-(\d+)$/ ? $1 : $now;
	        my $tb = $b  =~ /\-(\d+)$/ ? $1 : $now;
	 	$ta <=> $tb } @files;
foreach my $f (@files) {
	my $readfile = 0;
	if ($f eq $stat) {
		# Always read latest file
		$readfile = 1;
		}
	elsif ($f =~ /^\Q$stat\E\.(\d+)\-(\d+)$/) {
		# Maybe read this file, if in range
		if ($1 >= $start && ($1 <= $end || !defined($end)) ||
		    $2 >= $start && ($2 <= $end || !defined($end))) {
			$readfile = 1;
			}
		}
	if ($readfile) {
		open(HISTORY, "$serverdir/$f");
		while(<HISTORY>) {
			chop;
			my ($time, $value) = split(" ", $_);
			if ((!defined($start) || $time >= $start) &&
			    (!defined($end) || $time <= $end)) {
				push(@rv, [ $time, $value ]);
				}
			if (defined($end) && $time > $end) {
				last;   # Past the end point
				}
			}
		close(HISTORY);
		}
	}
return @rv;
}

# get_historic_first_last(stat, &servers)
# Returns the Unix time for the oldest and newest historic data point for
# a list of servers, taking the max if there is more than one server
sub get_historic_first_last
{
my ($stat, $servers) = @_;
my ($firsttime, $lasttime);
foreach my $s (@$servers) {
	# Check rotated files, which have the start and end in their filenames
	my $serverdir = "$historic_info_dir/$s->{'id'}";
	opendir(SERVERDIR, $serverdir);
	foreach my $f (readdir(SERVERDIR)) {
		if ($f =~ /^\Q$stat\E\.(\d+)\-(\d+)$/) {
			my ($sfirsttime, $slasttime) = ($1, $2);
			$firsttime = $sfirsttime if (!defined($firsttime) ||
						     $sfirsttime < $firsttime);
			$lasttime = $slasttime if (!defined($lasttime) ||
						   $slasttime > $lasttime);
			}
		}
	closedir(SERVERDIr);

	# Check the latest file
	open(HISTORY, "$serverdir/$stat") || next;
	my $first = <HISTORY>;
	if (!$first) {
		close(HISTORY);
		next;
		}
	chop($first);
	my ($sfirsttime, undef) = split(" ", $first);
	seek(HISTORY, 2, -256) || seek(HISTORY, 0, 0);
	while(<HISTORY>) {
		$last = $_;
		}
	close(HISTORY);
	chop($last);
	my ($slasttime, undef) = split(" ", $last);
	$firsttime = $sfirsttime if (!defined($firsttime) ||
				     $sfirsttime < $firsttime);
	$lasttime = $slasttime if (!defined($lasttime) ||
				   $slasttime > $lasttime);
	}
return ($firsttime, $lasttime);
}

# list_historic_stats(&servers)
# Returns a list of variables on which we have stats for some or all servers
sub list_historic_stats
{
my ($servers) = @_;
my @rv;
my %done;
foreach my $s (@$servers) {
	opendir(HISTDIR, "$historic_info_dir/$s->{'id'}");
	foreach my $f (readdir(HISTDIR)) {
		if ($f =~ /^[a-z]+[0-9]*$/ && $f ne "maxes" &&
		    !$done{$f}++) {
			push(@rv, $f);
			}
		}
	closedir(HISTDIR);
	}
return @rv;
}

# get_historic_maxes(&sever)
# Returns a hash reference from stats to the max possible values ever seen for
# some server.
sub get_historic_maxes
{
my ($server) = @_;
my %maxpossible;
&read_file("$historic_info_dir/$server->{'id'}/maxes", \%maxpossible);
return \%maxpossible;
}

# make_value_nice(stat, value)
# Converts a value of some stat type into a more human-friendly format.
# In an array context returns units too.
sub make_value_nice
{
my ($stat, $v) = @_;
my $u;
my $fmt = &historic_stat_info($stat);
if ($fmt) {
	$v /= $fmt->{'scale'} if ($fmt->{'scale'});
	$u = $fmt->{'units'};
	}
if ($v ne '0' && $v ne int($v)) {
	# Two decimal places only
	$v = sprintf("%.2f", $v);
	}
return wantarray ? ($v, $u) : $v;
}

# cleanup_old_history_files(dir, [pattern])
# Delete files in some directory (history or bandwidth) older than the
# configured cleanup age
sub cleanup_old_history_files
{
my ($dir, $pattern) = @_;
my $age = $config{'cleanup_age'};
return 0 if (!$age);
my $cutoff = time() - $age*86400;
my $rv = 0;
opendir(DIR, $dir) || return 0;
my @files = readdir(DIR);
closedir(DIR);
foreach my $f (@files) {
	next if ($f eq "." || $f eq "..");
	my $path = "$dir/$f";
	if (-d $path) {
		$rv += &cleanup_old_history_files($path);
		}
	else {
		my @st = stat($path);
		if (@st && $st[9] < $cutoff &&
		    (!$pattern || $f =~ /$pattern/)) {
			&unlink_file($path);
			$rv++;
			}
		}
	}
return $rv;
}

1;

