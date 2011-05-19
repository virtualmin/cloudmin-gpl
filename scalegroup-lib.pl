# Functions for managing auto-scaling groups

# list_scalegroups()
# Returns a list of all configured auto-scaling groups
sub list_scalegroups
{
my @rv;
opendir(RR, $scalegroups_dir);
foreach my $f (readdir(RR)) {
	next if ($f =~ /^\./ || $f =~ /\.lock/);
	my $rr = &get_scalegroup($f);
	if ($rr) {
		push(@rv, $rr);
		}
	}
close(RR);
return sort { $a->{'id'} <=> $b->{'id'} } @rv;
}

# get_scalegroup(id)
# Returns the hash ref for a single auto-scaling group. Keys are :
# id - A unique ID
# desc - Human-readable description for this scalegroup
# clone - ID of virtual system to clone
# host - Hostname pattern, including ${NUM}
# conds - Array ref of rule hash refs, each of which contains
#	name - Variable to match on, like load, mem, space
#	value - Cutoff value for scaling
#	over/under - Match if variable is over or under the value
#	for - Optional period is seconds that this must be true for
#	count - Optional number of systems that this must be true for
# downconds - Same as conds, but for downscaling
# rate - Period in seconds between changing group size
# min - Minimum systems in the group
# max - Maximum systems in the group
# master - Send email to master when group changes
# email - Send email to this address when group changes
# interval - Period in seconds between sending emails
sub get_scalegroup
{
my ($id) = @_;
my %rr;
&read_file_cached("$scalegroups_dir/$id", \%rr) || return undef;
$rr{'id'} = $id;
foreach my $sect ("conds", "downconds") {
	my @conds;
	for(my $i=0; defined($rr{$sect.'_'.$i}); $i++) {
		push(@conds, { map { split(/=/, $_) }
			       split(/\s+/, $rr{$sect.'_'.$i}) });
		delete($rr{$sect.'_'.$i});
		}
	$rr{$sect} = \@conds;
	}
return \%rr;
}

# save_scalegroup(&scalegroup)
# Create or update an auto-scaling group
sub save_scalegroup
{
my ($rr) = @_;
if (!-r $scalegroups_dir) {
	&lock_file($scalegroups_dir);
	&make_dir($scalegroups_dir, 0700);
	&unlock_file($scalegroups_dir);
	}
$rr->{'id'} ||= &server_id();
my $file = "$scalegroups_dir/$rr->{'id'}";
&lock_file($file);
my %rsave = %$rr;
foreach my $sect ("conds", "downconds") {
	delete($rsave{$sect});
	my $i = 0;
	foreach my $r (@{$rr->{$sect}}) {
		$rsave{$sect.'_'.$i} =
			join(" ", map { $_."=".$r->{$_} } keys %$r);
		$i++;
		}
	}
&write_file($file, \%rsave);
&unlock_file($file);
}

# delete_scalegroup(&scalegroup)
# Deletes an auto-scaling group (but not the systems)
sub delete_scalegroup
{
my ($scalegroup) = @_;
my @ingroup = &get_scalegroup_systems($scalegroup);
&obtain_lock_server(\@ingroup);
foreach my $s (@ingroup) {
	delete($s->{'scalegroup'});
	&save_managed_server($s);
	}
&release_lock_server(\@ingroup);
my $file = "$scalegroups_dir/$scalegroup->{'id'}";
&lock_file($file);
&unlink_file($file);
&unlock_file($file);
}

# get_scalegroup_systems(&scalegroup)
# Returns a list of virtual systems created by some scaling group
sub get_scalegroup_systems
{
my ($scalegroup) = @_;
return &get_managed_server_by("scalegroup", $scalegroup->{'id'});
}

# describe_scalegroup_status(&group)
# Return number of systems currently in the group
sub describe_scalegroup_status
{
my ($scalegroup) = @_;
my @ingroup = &get_scalegroup_systems($scalegroup);
if (!@ingroup) {
	return $text{'scalegroups_empty'};
	}
my @users = map { $_->{'host'} } @ingroup;
if (@users > 3) {
	@users = ( @users[0..2], "..." );
	}
return &text('scalegroups_users', join(", ", @users));
}

# describe_scalegroup_system_status(&scalegroup, &server, &upst, &downst)
# Returns text describing if a system is due to be scaled up or down
sub describe_scalegroup_system_status
{
my ($scalegroup, $server, $upst, $downst) = @_;
foreach my $st ($upst, $downst) {
	my @names = split(/,/, $st->{'names'});
	my @values = map { [ split(/:/, $_, 2) ] }
			 split(/,/, $st->{'values'});
	my @periods = map { [ split(/:/, $_, 2) ] }
			  split(/,/, $st->{'periods'});
	for(my $i=0; $i<@names; $i++) {
		if ($values[$i]->[0] eq $server->{'id'}) {
			# Found trigger for this system
			my $msg = $st eq $upst ? 'scalegroup_willup'
					       : 'scalegroup_willdown';
			$msg .= 'soon' if ($st->{'soon'});
			my $stat = $text{'history_stat_'.$names[$i]};
			my $hgraph = "history.cgi?id=$server->{'id'}&".
				     "stat=$names[$i]&".
				     "search=$server->{'host'}&period=3600";
			my $rv = &text($msg, "<a href='$hgraph'>$stat</a>",
					     $values[$i]->[1],
					     &nice_period($periods[$i]->[1]));
			if ($st->{'soon'}) {
				$rv = "<font color=orange>$rv</font>";
				}
			else {
				$rv = "<font color=red>$rv</font>";
				}
			return $rv;
			}
		}
	}
return $text{'scalegroup_nochange'};
}

# evaluate_all_scalegroups()
# Perform background evaluation of all auto-scaling groups, and send email
# when something was done.
sub evaluate_all_scalegroups
{
my $now = time();
&foreign_require("mailboxes");
&push_all_print();
&set_all_capture_text_print();
foreach my $scalegroup (&list_scalegroups()) {
	next if (!$scalegroup->{'enabled'});
	next if (&test_lock_scalegroup($scalegroup));
	&obtain_lock_scalegroup($scalegroup);
	$capture_print = undef;
	my $rv = &evaluate_scalegroup($scalegroup);
	my $subject;
	my $msg;
	if ($rv->{'action'} ne 'ok' &&
	    $scalegroup->{'notify_'.$rv->{'action'}}) {
		my $smsg = 'scaleemail_subject_'.$rv->{'action'};
		$smsg .= '_error' if ($rv->{'error'});
		my $why = &describe_scalegroup_eval($rv->{'why'});
		if ($rv->{'action'} eq 'inc' && !$rv->{'error'}) {
			# Has been scaled up
			$msg = &text('scaleemail_body_inc',
				     $rv->{'server'}->{'host'},
				     $scalegroup->{'host'}, $why);
			}
		elsif ($rv->{'action'} eq 'inc' && $rv->{'error'}) {
			# Scale up failed
			$msg = &text('scaleemail_body_inc_error',
				     $scalegroup->{'host'},
				     $rv->{'error'}, $why);
			}
		elsif ($rv->{'action'} eq 'dec' && !$rv->{'error'}) {
			# Has been scaled down
			$msg = &text('scaleemail_body_dec',
				     $rv->{'server'}->{'host'},
				     $scalegroup->{'host'}, $why);
			}
		elsif ($rv->{'action'} eq 'dec' && $rv->{'error'}) {
			# Scale down failed
			$msg = &text('scaleemail_body_dec_error',
				     $scalegroup->{'host'},
				     $rv->{'error'}, $why);
			}
		elsif ($rv->{'action'} eq 'over') {
			# Cannot be scaled up
			$msg = &text('scaleemail_body_over',
				     $scalegroup->{'host'},
				     $scalegroup->{'max'}, $why);
			}
		$msg = join("\n", &mailboxes::wrap_lines($msg, 75));
		$msg .= "\n";
		$msg .= "\n".$capture_print."\n";
		$subject = &text($smsg, $scalegroup->{'host'});
		}
	if ($subject) {
		# Send email
		my @emails;
		push(@emails, $config{'bw_email'}) if ($scalegroup->{'master'});
		push(@emails, split(/\s+/, $scalegroup->{'email'}));
		my $sincelast = $now - $scalegroup->{'lastemail'};
		if ($sincelast > $scalegroup->{'interval'}) {
			&mailboxes::send_text_mail(
				&get_global_from_address(),
				join(", ", @emails),
				undef,
				$subject,
				$msg,
				);
			$scalegroup->{'lastemail'} = $now;
			&save_scalegroup($scalegroup);
			}
		}
	&release_lock_scalegroup($scalegroup);
	}
&pop_all_print();
}

# evaluate_scalegroup(&scalegroup, [&all-servers])
# Check if an auto-scaling group needs more or fewer systems, and create or 
# delete then if needed. Returns a hash ref with details of what was done.
# May print output when creating or deleting.
sub evaluate_scalegroup
{
my ($scalegroup, $allservers) = @_;
$allservers ||= [ &list_managed_servers() ];
my @ingroup = &get_scalegroup_systems($scalegroup);

# Evaluate scale-up and down conditions to see if any are firing
my $upst = &evaluate_scalegroup_conditions(
		$scalegroup, \@ingroup, "conds");
my $downst = &evaluate_scalegroup_conditions(
		$scalegroup, \@ingroup, "downconds");

if ($upst->{'firing'} && !$upst->{'soon'}) {
	# Need another sytem
	if (@ingroup < $scalegroup->{'max'}) {
		# Create it
		my ($err, $newserver);
		if ($scalegroup->{'enabled'}) {
			($err, $newserver) =
				&create_scalegroup_system($scalegroup);
			}
		if ($newserver) {
			&obtain_lock_server($newserver);
			$newserver->{'scalegroup_reason'} =
				'scaleup '.$upst->{'names'};
			&save_managed_server($newserver);
			&release_lock_server($newserver);
			}
		return { 'action' => 'inc',
			 'error' => $err,
			 'server' => $newserver,
			 'enabled' => $scalegroup->{'enabled'},
			 'why' => $upst };
		}
	else {
		# Group is full, cannot create
		return { 'action' => 'over',
			 'why' => $upst };
		}
	}
elsif ($downst->{'firing'} && !$downst->{'soon'}) {
	# Need less systems
	if (@ingroup > $scalegroup->{'min'}) {
		# Delete one
		my ($err, $server);
		if ($scalegroup->{'enabled'}) {
			($err, $server) =
				&delete_scalegroup_system($scalegroup);
			}
		return { 'action' => 'dec',
			 'enabled' => $scalegroup->{'enabled'},
			 'error' => $err,
			 'why' => $downst };
		}
	else {
		# System count is low enough, so do nothing
		return { 'action' => 'ok',
			 'why' => $downst };
		}
	}

return { 'action' => 'ok' };
}

# create_scalegroup_system(&scalegroup)
# Create a new virtual system based on specifications in a scaling group,
# by cloning a source system. Returns an error message on failure.
sub create_scalegroup_system
{
my ($scalegroup) = @_;

# Pick a new hostname
&$first_print($text{'scaleup_pickname'});
my $newhost;
my $num = 0;
my @allservers = &list_managed_servers();
while(1) {
	$newhost = &substitute_template($scalegroup->{'host'},
					{ 'num' => $num });
	my ($clash) = grep { $_->{'host'} =~ /\Q$newhost\E/i }
			   @allservers;
	last if (!$clash);
	$num++;
	}
&$second_print(&text('scaleup_pickedhost', $newhost));

my $newserver;
if ($scalegroup->{'manager'} eq 'ec2') {
	# Creating an EC2 instance from an AMI
	$newserver = { 'id' => &server_id(),
		       'manager' => $scalegroup->{'manager'},
		       'type' => 'unknown',
		       'status' => 'create',
		       'bw_limit' => $config{'bw_def'},
		       'created' => time(),
		       'desc' => $scalegroup->{'desc'}." system ".$num,
		       'unix_hostname' => $newhost,
		       'ssh_user' => 'root',
		       'key' => $scalegroup->{'ec2_key'},
		       'ssh_protocol' => 2,
		       'ec2' => $scalegroup->{'ec2_account'},
		       'ec2_azone' => $scalegroup->{'ec2_azone'},
		       'ec2_image' => $scalegroup->{'ec2_image'},
		       'ec2_size' => $scalegroup->{'ec2_size'},
		     };

	# Call create function
	my $tfunc = "type_ec2_desc";
	&$first_print(&text('create_creating', &$tfunc()));
	my $cfunc = "type_ec2_create";
	my $err = &$cfunc($newserver);
	if ($err) {
		return &text('create_ecreate', $err);
		}
	&$second_print($text{'create_created'});

	# Wait for completion
	&$first_print($text{'create_waiting'});
	my $dfunc = "type_ec2_create_done";
	while(1) {
		my $err = &$dfunc($newserver);
		if ($err eq "OK") {
			last;
			}
		elsif ($err) {
			return &text('create_ewait', $err);
			}
		sleep(1);
		}
	&$second_print($text{'create_waited'});
	&complete_managed_server($newserver);
	&save_managed_server($newserver);

	# Remove old SSH keys for this system
	&clear_ssh_host_key($newserver);

	# Wait for SSH
	&$first_print($text{'create_sshing'});
	my $ok = &wait_for_ssh($newserver, 120);
	my ($sshstatus, $ssherr, $webmindir, $webminport, $webminssl) =
		&check_server_ssh_login($newserver);
	if ($ok) {
		&$second_print($text{'create_sshdone'});
		}
	else {
		&$second_print(&text('create_sshfailed', 120, $ssherr));
		}

	# Check for Webmin, set root directory, user and pass
	if ($webmindir) {
		$newserver->{'user'} = "root";
		$newserver->{'pass'} ||= &generate_random_password();
		$newserver->{'port'} = $webminport;
		$newserver->{'ssl'} = $webminssl;
		&$first_print($text{'create_passing'});
		my $perr = &set_server_webmin_password(
			$newserver, $webmindir, "root", $newserver->{'pass'});
		if ($perr) {
			&$second_print(&text('create_passfailed', $perr));
			}
		else {
			&$second_print($text{'create_passdone'});
			}

		# Start Webmin in case it hasn't been
		&execute_command_on_server($newserver,
			"/etc/webmin/start >/dev/null 2>&1 </dev/null &");

		# Wait for Webmin to start
		&$first_print($text{'create_webminstarting'});
		my $err = &wait_webmin_server($newserver, 60);
		if (!$err) {
			&$second_print($text{'create_webminstarted'});
			}
		else {
			&$second_print(&text('create_webminnostart', 60, $err));
			}
		}

	# Call final post-creation ready function
	my $dfunc = "type_ec2_create_ready";
	&$dfunc($newserver);
	}
else {
	# Creating a regular virtual system by cloning
	my $srcserver = &get_managed_server($scalegroup->{'clone'});
	$srcserver || return $text{'scaleup_esource'};
	$srcserver->{'host'} eq 'nohost' && return $text{'scaleup_enohost'};
	my $srcvhost = &get_parent_server($srcserver);

	# Get resources neeeded
	my $dsfunc = "type_".$srcserver->{'manager'}."_get_disk_size";
	my $disk = defined(&$dsfunc) ? &$dsfunc($srcserver) : 0;
	my $mfunc = "type_".$newserver->{'manager'}."_get_memory_size";
	my $mem = defined(&$mfunc) ? &$mfunc($newserver) : undef;
	my $cfunc = "type_".$newserver->{'manager'}."_get_cpu_size";
	my $cpu = defined(&$cfunc) ? &$cfunc($newserver) : undef;

	# Find all possible host systems
	&$first_print($text{'scaleup_pickhost'});
	my @allvhosts = &list_available_host_servers(
				$scalegroup->{'manager'}, $mem, $disk);
	my @vhosts;
	if ($scalegroup->{'dest_hosts'} ne '') {
		# Only selected hosts
		my %vids = map { $_, 1 }
			split(/\s+/, $scalegroup->{'dest_hosts'});
		@vhosts = grep { $vids{$_->{'id'}} } @allvhosts;
		}
	elsif ($scalegroup->{'dest_location'}) {
		# All hosts in location group
		@vhosts = grep { $_->{'location'} eq
				 $scalegroup->{'dest_location'} } @allvhosts;
		}
	else {
		# All for type
		@vhosts = @allvhosts;
		}
	@vhosts || return $text{'scaleup_evhosts'};

	# Is remote cloning supported?
	my $rfunc = "type_".$srcserver->{'manager'}."_can_clone_remote";
	my $canremote = defined(&$rfunc) && &$rfunc();
	if ($canremote) {
		# Pick a host system based on memory / etc
		$vhost = &find_host_server_from_vhosts(
			$srcserver, \@vhosts, "mem", $srcserver->{'manager'});
		$vhost || return &text('scaleup_evresources',
				       &nice_size($mem), &nice_size($disk));
		}
	else {
		# Can only clone to same system
		my ($inlist) = grep { $_->{'id'} eq $srcvhost->{'id'} } @vhosts;
		$inlist || return &text('scaleup_elocalvhost',
				$srcvhost->{'host'}, $srcserver->{'host'});
		$vhost = $srcvhost;
		}
	&usable_host_system($vhost, $newserver->{'manager'}, $mem, $disk) ||
		return &text('scaleup_evhostresources', $vhost->{'host'},
			     &nice_size($mem), &nice_size($disk));
	&$second_print(&text('scaleup_pickedhost', $vhost->{'host'}));

	# Call the clone function
	&obtain_lock_server($srcserver);
	my $newdesc = $scalegroup->{'desc'}." system ".$num;
	my ($newserver, $err) = &clone_system($srcserver, $newhost, $newdesc,
					      undef, 0, $vhost);
	&release_lock_server($srcserver);
	return $err if ($err);
	}

# Set scalegroup parameter and re-save
&obtain_lock_server($newserver);
$newserver->{'scalegroup'} = $scalegroup->{'id'};
$newserver->{'scalegroup_index'} = $num;
&check_server_status($newserver, 0, 1);
&save_managed_server($newserver);

# Start up the clone if down
my ($ok, $err);
if ($newserver->{'status'} eq 'down') {
	&$first_print($text{'clone_starting2'});
	($ok, $err) = &startup_server($newserver);
	if (!$ok) {
		&$second_print(&text('smove_startfailed', $err));
		}
	else {
		&$second_print($text{'create_done'});
		}
	}

# Check status again
&$first_print($text{'clone_refreshing2'});
&check_server_status($newserver, 1);
if (!$newserver->{'type'} || $newserver->{'type'} eq 'unknown') {
        $newserver->{'type'} = &guess_os_type($newserver);
        if ($newserver->{'type'}) {
                &check_server_status($newserver);
                }
        }
&save_managed_server($newserver);
&$second_print(&text('save_refreshdone2',
	&describe_status($newserver, 1, 1)));
&release_lock_server($newserver);

# Find and eval roundrobins for this scalegroup
&evaluate_scalegroup_roundrobins($scalegroup);

return ( $err ? &text('scaleup_estart', $err) : undef, $newserver );
}

# delete_scalegroup_system(&server)
# Remove the highest-numbered system from an auto-scaling group
sub delete_scalegroup_system
{
my ($scalegroup) = @_;
&$first_print($text{'scaledown_pickserver'});
my @ingroup = &get_scalegroup_systems($scalegroup);
@ingroup = grep { $_->{'scalegroup_reason'} ne 'manual' } @ingroup;
@ingroup = sort { $a->{'scalegroup_index'} <=> $b->{'scalegroup_index'} }
		@ingroup;
if (@ingroup) {
	my $server = pop(@ingroup);
	&$second_print(&text('scaledown_pickedserver', $server->{'host'}));

	&obtain_lock_server($server);
	&$first_print(&text('scaledown_deleting', $server->{'host'}));
	&run_system_script($server, 'before', 'delete');
	my $dfunc = "type_".$server->{'manager'}."_delete";
	$err = &$dfunc($server);
	return (&text('scaledown_edelete', $server->{'host'}, $err), undef)
		if ($err);
	&clear_ssh_host_key($server);
	&delete_managed_server($server);
	&run_system_script($server, 'after', 'delete');
	&$second_print($text{'create_done'});
	&evaluate_scalegroup_roundrobins($scalegroup);
	&release_lock_server($server);
	return (undef, $server);
	}
else {
	return ($text{'scaledown_empty'}, undef);
	}
}

# evaluate_scalegroup_roundrobins(&scalegroup)
# Evaluate all roundrobins that refer to a scalegroup
sub evaluate_scalegroup_roundrobins
{
my ($scalegroup) = @_;
my @rrs;
foreach my $rr (&list_roundrobins()) {
	my @sc = split(/\s+/, $rr->{'scalegroups'});
	if (&indexof($scalegroup->{'id'}, @sc) >= 0) {
		push(@rrs, $rr);
		}
	}
if (@rrs) {
	&evaluate_all_roundrobins(undef, \@rrs);
	}
}

# obtain_lock_scalegroup(&scalegroup)
# Lock a scaling group for update or evaluation
sub obtain_lock_scalegroup
{
my ($scalegroup) = @_;
if ($main::got_lock_scalegroup{$scalegroup->{'id'}} == 0) {
	&lock_file($scalegroups_dir."/".$scalegroup->{'id'});
	}
$main::got_lock_scalegroup{$scalegroup->{'id'}}++;
}

# release_lock_scalegroup(&scalegroup)
# Give up the lock created by obtain_lock_scalegroup
sub release_lock_scalegroup
{
my ($scalegroup) = @_;
if ($main::got_lock_scalegroup{$scalegroup->{'id'}} == 1) {
	&unlock_file($scalegroups_dir."/".$scalegroup->{'id'});
	}
$main::got_lock_scalegroup{$scalegroup->{'id'}}--
	if ($main::got_lock_scalegroup{$scalegroup->{'id'}});
}

# test_lock_scalegroup(&scalegroup)
# Return 1 if some scaling group is already locked by another process
sub test_lock_scalegroup
{
my ($scalegroup) = @_;
if ($main::got_lock_scalegroup{$scalegroup->{'id'}} > 0) {
	# We have the lock
	return 0;
	}
return &test_lock($scalegroups_dir."/".$scalegroup->{'id'});
}

# describe_scalegroup_reason(&server)
# Returns text describing why a system was added to a scaling group
sub describe_scalegroup_reason
{
my ($s) = @_;
my $r = $s->{'scalegroup_reason'};
if (!$r) {
	return $text{'scalegroup_runknown'};
	}
elsif ($r =~ /^scaleup\s+(.*)/) {
	return &text('scalegroup_rup',
		     join(", ", map { $text{'history_stat_'.$_} }
				   split(/\s+/, $1)));
	}
else {
	return $text{'scalegroup_r'.$r};
	}
}

# evaluate_scalegroup_conditions(&scalegroup, &allservers,
# 				 [conds|downconds])
# Checks if a scalegroup should be scaled up or down, and returns
# a status object like evaluate_alert, but with the field 'soon' set
# if the alert condition hasn't triggered for long enough yet.
sub evaluate_scalegroup_conditions
{
my ($scalegroup, $allservers, $mode) = @_;
$allservers ||= [ &list_managed_servers() ];
my @ingroup = &get_scalegroup_systems($scalegroup);
my $fakealert = { 'servers' => join(" ", map { $_->{'id'} } @ingroup),
		  'rules' => $scalegroup->{$mode},
		  'and' => $scalegroup->{$mode.'_and'},
		  'or' => $scalegroup->{$mode.'_or'},
		};
my $rv = &evaluate_alert($fakealert, $allservers, undef, 0);
if (!$rv || !$rv->{'firing'}) {
	$rv = &evaluate_alert($fakealert, $allservers, undef, 1);
	$rv->{'soon'} = 1 if ($rv && $rv->{'firing'});
	}
return $rv;
}

# describe_scalegroup_eval(&status)
# Given a status from the 'why' field returned by evaluate_scalegroup, return
# human-readable text explaining why the action was taken.
sub describe_scalegroup_eval
{
my ($st) = @_;
my @names = split(/,/, $st->{'names'});
my @values = split(/,/, $st->{'values'});
my @why;
for(my $i=0; $i<@names; $i++) {
	my ($id, $v) = split(/:/, $values[$i], 2);
	my $s = &get_managed_server($id);
	next if (!$s);
	push(@why, &text('scaleeval_why',
			 $text{'history_stat_'.$names[$i]} ||
			   $names[$i],
			 $s->{'host'}, $v));
	}
return join(", ", @why);
}

1;

