#!/usr/local/bin/perl
# Fetch bandwidth counts for all managed systems

package server_manager;
$main::no_acl_check++;
require './server-manager-lib.pl';
&exit_if_cloudmin_replica();
&foreign_require("mailboxes", "mailboxes-lib.pl");

# Parse command line for hosts
if (@ARGV == 0) {
	$all = 1;	# If called with no args, assume all systems
	}
while(@ARGV > 0) {
	my $a = shift(@ARGV);
	if ($a eq "--all-hosts") { $all = 1; }
	elsif ($a eq "--host") { push(@hosts, shift(@ARGV)); }
	elsif ($a eq "--group") { push(@groups, shift(@ARGV)); }
	elsif ($a eq "--os") { push(@types, shift(@ARGV)); }
	elsif ($a eq "--type") { push(@managers, shift(@ARGV)); }
        elsif ($a eq "--owner") { push(@owners, shift(@ARGV)); }
        elsif ($a eq "--host-on") { push(@hostons, shift(@ARGV)); }
        elsif ($a eq "--status") { push(@statuses, shift(@ARGV)); }
	else {
		&usage();
		}
	}

# Work out who to check
@servers = &find_managed_servers($all, \@hosts, \@groups, \@managers, \@types, \@owners, \@statuses, \@hostons);
@servers = sort { $a->{'host'} cmp $b->{'host'} } @servers;
@servers || &usage("No systems specified");

# Prevent concurrent runs
$pid = &test_lock($bandwidth_dir);
if ($pid) {
	print STDERR "$0 is already running with PID $pid\n";
	exit(0);
	}
&lock_file($bandwidth_dir);

# Skip any currently locked
@unlocked_servers = ( );
foreach my $server (@servers) {
	if (!&test_lock_server($server)) {
		push(@unlocked_servers, $server);
		}
	}
@servers = @unlocked_servers;

# For each system, get it's current counts, compare to old counts, then up
# the total for this hour
foreach $s (@servers) {
	next if ($s->{'status'} eq 'nohost' ||
		 $s->{'status'} eq 'down');
	my $bwinfo = &get_bandwidth($s);
	$now = time();
	($in, $out, $inp, $outp) = &get_server_traffic($s);
	next if (!defined($in));

	# Work out diffs
	$in_diff = $in - $bwinfo->{'last_in'};
	$out_diff = $out - $bwinfo->{'last_out'};
	$inp_diff = $inp - $bwinfo->{'last_inp'};
	$outp_diff = $outp - $bwinfo->{'last_outp'};
	$in_diff = 0 if ($in_diff < 0);
	$out_diff = 0 if ($out_diff < 0);
	$inp_diff = 0 if ($inp_diff < 0);
	$outp_diff = 0 if ($outp_diff < 0);

	# Save new lasts
	$bwinfo->{'last_in'} = $in;
	$bwinfo->{'last_out'} = $out;
	$bwinfo->{'last_inp'} = $inp;
	$bwinfo->{'last_outp'} = $outp;

	# Spread over period between last poll and now
	if ($bwinfo->{'last_time'}) {
		# By hour
		$hours = ($now - $bwinfo->{'last_time'}) / 3600.0;
		$hours = 1 if ($hours < 1);
		for(my $h=$bwinfo->{'last_time'}; $h<$now; $h+=3600) {
			$hh = int($h/3600) * 3600;
			$bwinfo->{'hour_in_'.$hh} += $in_diff / $hours;
			$bwinfo->{'hour_out_'.$hh} += $out_diff / $hours;
			$bwinfo->{'hour_inp_'.$hh} += $inp_diff / $hours;
			$bwinfo->{'hour_outp_'.$hh} += $outp_diff / $hours;
			}
		$bwinfo->{'new_hour'} = $hh;
		$bwinfo->{'old_hour'} ||= int($bwinfo->{'last_time'}/3600)*3600;

		# By minute
		$mins = ($now - $bwinfo->{'last_time'}) / 60.0;
		$mins = 1 if ($mins < 1);
		for(my $m=$bwinfo->{'last_time'}; $m<$now; $m+=60) {
			$mm = int($m/60) * 60;
			$bwinfo->{'min_in_'.$mm} += $in_diff / $mins;
			$bwinfo->{'min_out_'.$mm} += $out_diff / $mins;
			$bwinfo->{'min_inp_'.$mm} += $inp_diff / $mins;
			$bwinfo->{'min_outp_'.$mm} += $outp_diff / $mins;
			}
		$bwinfo->{'old_min'} ||= int($bwinfo->{'last_time'}/60)*60;
		$bwinfo->{'new_min'} = $mm;

		# Get rid of per-minute stats more than 1 week old
		$weekago = $now - 7*24*60*60;
		$weekago = int($weekago/60) * 60;
		if ($bwinfo->{'old_min'} < $weekago) {
			for(my $mm=$bwinfo->{'old_min'}; $mm<$weekago; $mm+=60){
				delete($bwinfo->{'min_in_'.$mm});
				delete($bwinfo->{'min_out_'.$mm});
				delete($bwinfo->{'min_inp_'.$mm});
				delete($bwinfo->{'min_outp_'.$mm});
				}
			$bwinfo->{'old_min'} = $weekago;
			}
		}
	$bwinfo->{'last_time'} = $now;

	# Write out
	&save_bandwidth($s, $bwinfo);
	}

# For each server, sum up usage over the relevant accounting period, and
# send email or disable if needed
$start = &bandwidth_period_start();
$now = time();
foreach $s (@servers) {
	&obtain_lock_server($s);
	my $bwinfo = &get_bandwidth($s);
	next if (!$bwinfo->{'last_time'});	# Only do if bandwidth is
						# supported by system type

	# Sum up usage over the period, by day
	$s->{'bw_usage_in'} = $s->{'bw_usage_out'} =
	    $s->{'bw_usage_inp'} = $s->{'bw_usage_outp'} = 0;
	for($hh=$start; $hh<$now; $hh+=3600) {
		$s->{'bw_usage_in'} += $bwinfo->{'hour_in_'.$hh};
		$s->{'bw_usage_out'} += $bwinfo->{'hour_out_'.$hh};
		$s->{'bw_usage_inp'} += $bwinfo->{'hour_inp_'.$hh};
		$s->{'bw_usage_outp'} += $bwinfo->{'hour_outp_'.$hh};
		}
	$s->{'bw_usage'} = ($config{'bw_dir_in'} ? $s->{'bw_usage_in'} : 0) +
			   ($config{'bw_dir_out'} ? $s->{'bw_usage_out'} : 0);

	# If over, send email and perhaps shutdown the system
	if ($s->{'bw_limit'} && $s->{'bw_usage'} > $s->{'bw_limit'}) {
		# Send email
		my @to;
		push(@to, $config{'bw_email'}) if ($config{'bw_email'});
		if ($config{'bw_owner'}) {
			push(@to, map { $_->{'acl'}->{'email'} }
				      &get_server_owners($s));
			}
		$etime = $now - $s->{'bw_notify'} > $config{'bw_notify'}*60*60;
		if (@to && $etime) {
			my $msg = &get_bandwidth_message();
			my %hash = %$s;
			$hash{'bw_period'} = $config{'bw_period'};
			$hash{'bw_days'} = $config{'bw_days'};
			foreach $n ('bw_limit', 'bw_usage',
				    'bw_usage_in', 'bw_usage_out') {
				$hash{$n} = &nice_size($hash{$n});
				}
			$hash{'bw_over'} = &nice_size($s->{'bw_usage'} -
						      $s->{'bw_limit'});
			$msg = &substitute_template($msg, \%hash);
			&mailboxes::send_text_mail(
				&get_global_from_address($server),
				join(", ", @to),
				undef,
				&text('bw_subject', $s->{'host'}),
				$msg);
			$s->{'bw_notify'} = $now;
			}

		# Perhaps shutdown
		$sfunc = "type_".$s->{'manager'}."_no_shutdown";
		if ($config{'bw_disable'} &&
		    $s->{'status'} ne 'down' && $s->{'status'} ne 'nohost' &&
		    (!defined(&$sfunc) || !&$sfunc($s))) {
			$err = &shutdown_server($s);
			if ($err) {
				print STDERR "Failed to shut down $s->{'host'} for exceeding bandwidth limit : $err\n";
				}
			$s->{'shutdown_reason'} = 'bw';
			}
		}

	# If under limit and the system was shutdown due to exceeding it,
	# start up again
	if ($s->{'bw_limit'} && $s->{'bw_usage'} <= $s->{'bw_limit'}) {
		# XXX
		}

	&save_managed_server($s);
	&release_lock_server($s);
	}

# For each system owner with a plan limit, sum up his usage
if (&supports_plans()) {
	foreach $o (&list_system_owners()) {
		$limits = &get_owner_limits($o->{'name'});
		next if (!$limits || !$limits->{'max_bw'});
		my @os = sort { $b->{'bw_usage'} cmp $a->{'bw_usage'} }
				 &get_owner_servers($o);

		# If over limit, send email
		if ($limits && $limits->{'max_bw'} &&
		    $limits->{'bw'} > $limits->{'max_bw'}) {
			my @to;
			push(@to, $config{'bw_email'}) if ($config{'bw_email'});
			push(@to, $o->{'email'}) if ($o->{'email'});
			$etime = $now - $o->{'acl'}->{'bw_notify'} >
				 $config{'bw_notify'}*60*60;
			if (@to && $etime) {
				my $msg = &get_owner_bandwidth_message();
				my $hosts = join(" ",
					map { $_->{'host'} } @os);
				my %hash = (
					'name', $o->{'name'},
					'real', $o->{'real'},
					'hosts', $hosts,
					'worst', $os[0]->{'host'},
					'bw_limit',
					   &nice_size($limits->{'max_bw'}),
					'bw_usage',
					   &nice_size($limits->{'bw'}),
					'email', $o->{'acl'}->{'email'},
					'bw_period', $config{'bw_period'},
					'bw_days', $config{'bw_days'},
					);
				$plan = &get_plan($o->{'acl'}->{'plan'});
				$hash{'plan'} = $plan->{'desc'};
				$msg = &substitute_template($msg, \%hash);
				&mailboxes::send_text_mail(
					&get_global_from_address($server),
					join(", ", @to),
					undef,
					&text('bw_subject2', $o->{'name'}),
					$msg);
				$o->{'acl'}->{'bw_notify'} = $now;
				&save_system_owner($o, $o);
				}
			}
		}
	}

&unlock_file($bandwidth_dir);

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Check for and sum up bandwidth use on managed systems.\n";
print "\n";
print "cloudmin bandwidth [--all-hosts] | [--host name]*\n";
print "                   [--group name]*\n";
my $types = join("|", @server_management_types);
print "                   [--type $types]*\n";
print "                   [--os oscode]*\n";
print "                   [--owner name]*\n";
print "                   [--status status-code|\"up\"|\"wm\"|\"bad\"]\n";
print "                   [--host-on name]\n";
exit(1);
}

