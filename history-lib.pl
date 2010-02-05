# Functions for managing historic data

# Colors for graphs, ripped from Gnuplot
@historic_graph_colors = (
	"#ff0000",  "#00c000",  "#0080ff",  "#c000ff",  "#00eeee",  "#c04000",  
	"#eeee00",  "#2020c0",  "#ffc020",  "#008040",  "#a080ff",  "#804000",  
	"#ff80ff",  "#00c060",  "#00c0c0",  "#006080",  "#c06080",  "#008000",  
	"#40ff80",  "#306080",  "#806000",  "#404040",  "#408000",  "#000080",  
	"#806010",  "#806060",  "#806080",  "#0000c0",  "#0000ff",  "#006000",  
	"#e3b0c0",  "#40c080",  "#60a0c0",  "#60c000",  "#60c0a0",  "#800000",  
	"#800080",  "#602080",  "#606060",  "#202020",  "#204040",  "#204080",  
	"#608020",  "#608060",  "#608080",  "#808040",  "#208020",  "#808080",  
	"#a0a0a0",  "#a0d0e0",  "#c02020",  "#008080",  "#c06000",  "#80c0e0",  
	"#c060c0",  "#c08000",  "#c08060",  "#ff4000",  "#ff4040",  "#80c0ff",  
	"#ff8060",  "#ff8080",  "#c0a000",  "#c0c0c0",  "#c0ffc0",  "#ff0000",  
	"#ff00ff",  "#ff80a0",  "#c0c0a0",  "#ff6060",  "#00ff00",  "#ff8000",  
	"#ffa000",  "#80e0e0",  "#a0e0e0",  "#a0ff20",  "#c00000",  "#c000c0",  
	"#a02020",  "#a020ff",  "#802000",  "#802020",  "#804020",  "#804080",  
	"#8060c0",  "#8060ff",  "#808000",  "#c0c000",  "#ff8040",  "#ffa040",  
	"#ffa060",  "#ffa070",  "#ffc0c0",  "#ffff00",  "#ffff80",  "#ffffc0"   
	);

@history_periods = (
	[ 'year', 365*24*60*60 ],
	[ 'month', 31*24*60*60 ],
	[ 'week', 7*24*60*60 ],
	[ 'day', 24*60*60 ],
	[ 'hour', 60*60 ],
	);

# add_historic_collected_info(&info, time, &server)
# Log some historic data for a Cloudmin-monitored system
sub add_historic_collected_info
{
my ($info, $time, $server) = @_;

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
                       ($info->{'mem'}->[0]-$info->{'mem'}->[1])*1024,
                       $info->{'mem'}->[0]*1024 ]);
	push(@stats, [ "memfree", $info->{'mem'}->[1]*1024 ]);
        if ($info->{'mem'}->[2]) {
                push(@stats, [ "swapused",
                              ($info->{'mem'}->[2]-$info->{'mem'}->[3])*1024,
                              $info->{'mem'}->[2]*1024 ]);
                push(@stats, [ "swapfree", $info->{'mem'}->[2]*1024 ]);
                }
        }
# Add disk usage
if ($info->{'disk_total'}) {
        push(@stats, [ "diskused",
                       $info->{'disk_total'}-$info->{'disk_free'},
                       $info->{'disk_total'} ]);
        push(@stats, [ "diskfree", $info->{'disk_free'} ]);
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
# Add up/down status
if ($server->{'status'} eq 'down') {
	push(@stats, [ "up", 0 ]);
	}
elsif ($server->{'status'} eq 'nossh' ||
       $server->{'status'} eq 'noping') {
	push(@stats, [ "up", 0.5 ]);
	}
else {
	push(@stats, [ "up", 1 ]);
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

1;

