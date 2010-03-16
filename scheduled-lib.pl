# Functions for managing scheduled changes

# get_scheduled_change(&server, type, id)
# Returns the hash ref for a scheduled change of some type, or undef
sub get_scheduled_change
{
my ($server, $type, $id) = @_;
my $idfile = $id;
$idfile =~ s/^\/+//;
$idfile =~ s/\//_/g;
my $file = "$scheduled_changes_dir/$server->{'id'}-$type-$idfile";
my %rv;
&read_file_cached($file, \%rv) || return undef;
return \%rv;
}

# save_scheduled_change(&server, type, id, [&change])
# Creates, updates or deletes a scheduled change
sub save_scheduled_change
{
my ($server, $type, $id, $sched) = @_;
my $idfile = $id;
$idfile =~ s/^\/+//;
$idfile =~ s/\//_/g;
my $file = "$scheduled_changes_dir/$server->{'id'}-$type-$idfile";
if (!-d $scheduled_changes_dir) {
	&make_dir($scheduled_changes_dir, 0700);
	}
if ($sched) {
	# Create or update
	$sched->{'id'} = $id;
	$sched->{'type'} = $type;
	$sched->{'server'} = $server->{'id'};
	&lock_file($file);
	&write_file($file, $sched);
	&unlock_file($file);
	}
else {
	# Delete
	&unlink_logged($file);
	}
}

# list_scheduled_changes()
# Returns a list of all known scheduled changes
sub list_scheduled_changes
{
my @rv;
opendir(SCHEDS, $scheduled_changes_dir);
foreach my $f (readdir(SCHEDS)) {
	if ($f =~ /^(\d+)\-([^\-]+)-(\S+)$/) {
		my %sched;
		if (&read_file_cached("$scheduled_changes_dir/$f", \%sched)) {
			push(@rv, \%sched);
			}
		}
	}
closedir(SCHEDS);
return @rv;
}

# run_scheduled_changes([&only-servers])
# Finds any scheduled changes due to happen, runs them, sends email notifcation
# and deletes them
sub run_scheduled_changes
{
my ($onlyservers) = @_;
my %onlymap;
if ($onlyservers) {
	%onlymap = map { $_->{'id'}, $_ } @$onlyservers;
	}
my $now = time();
my $done = 0;
foreach my $sched (&list_scheduled_changes()) {
	next if ($sched->{'time'} > $now);
	my $sfunc = "run_".$sched->{'type'}."_scheduled_change";
	my $server = &get_managed_server($sched->{'server'});
	my $owner;
	if ($sched->{'owner'}) {
		$owner = &get_system_owner($sched->{'owner'});
		}
	next if ($onlyservers && (!$server || !$onlymap{$server->{'id'}}));
	if ($server) {
		&obtain_lock_server($server);
		}

	# Execute the change
	my ($err, $out);
	if (!$server) {
		# System no longer exists
		$err = &text('schange_eserver',
			     $sched->{'type'}, $sched->{'server'});
		}
	elsif (!defined(&$sfunc)) {
		# Function does not exist!
		$err = &text('schange_efunc',
			     $sched->{'type'}, $server->{'host'});
		}
	elsif ($sched->{'owner'} && !$owner) {
		# Owner no longer exists
		$err = &text('schange_eownername',
			     $owner->{'name'});
		}
	elsif ($server && $owner &&
	       !&can_owner_action($owner, $server, $sched->{'action'})) {
		# Owner cannot manage this system
		$err = &text('schange_eowner',
			     $sched->{'type'}, $owner->{'name'},
			     $server->{'host'});
		}
	else {
		# All OK, call the function
		($err, $out) = &$sfunc($server, $sched, $owner);
		}
	if ($server) {
		&save_managed_server($server);
		&release_lock_server($server);
		}

	# Send email to the appropriate people
	my $msg = &text('schange_msg_'.$sched->{'type'},
			$server ? $server->{'host'} : "Unknown system")."\n\n".
		  join("", map { "    ".$_."\n" } split(/\n/, $out))."\n";
	if ($err) {
		$msg .= &text('schange_failed', $err)."\n\n";
		}
	else {
		$msg .= $text{'schange_allok'}."\n\n";
		}
	my @to;
	push(@to, $config{'bw_email'}) if ($config{'bw_email'});
	if ($owner) {
		push(@to, $owner->{'acl'}->{'email'});
		}
	&mailboxes::send_text_mail(
		&get_global_from_address($server),
		join(", ", @to),
		undef,
		&text('schange_subject', $server->{'host'} || "Unknown system"),
		$msg);

	# Delete it
	&save_scheduled_change($server || { 'id' => $sched->{'server'} },
			       $sched->{'type'}, $sched->{'id'}, undef);
	$done++;
	}
return $done;
}

# run_disk_scheduled_change(&server, &sched, [&owner])
# Execute a change to a disk on a system. Returns an error message (if any)
# and the output from the change.
sub run_disk_scheduled_change
{
my ($server, $sched, $owner) = @_;
my $vhost = &get_parent_server($server);

# Get the disk
my $dfunc = "type_".$server->{'manager'}."_list_disks";
my $disks = &$dfunc($server);
ref($disks) || return ( &text('disks_eget', $disks), undef );
my ($disk) = grep { $_->{'real'} eq $sched->{'real'} } @$disks;
$disk || return ( &text('schange_edisk', $sched->{'real'}), undef );

# Check the size increment against limits
my $incr = $sched->{'size'} - $disk->{'size'};
if ($owner) {
	my $limits = &get_owner_limits($owner);
	if ($limits && $limits->{'max_disk'} &&
	    $limits->{'disk'} + $incr > $limits->{'max_disk'}) {
		return ( &text('disk_elimit',
			       &nice_size($limits->{'max_disk'}),
			       &nice_size($limits->{'disk'})), undef );
		}
	}
my $hostfree = &host_free_disk($vhost, $server->{'manager'}, $server);
if ($hostfree && $incr > $hostfree) {
	return ( &text('disk_ehostlimit', &nice_size($hostfree)), undef );
	}

# Shut down the system if running
my $out;
my $was_up;
if ($server->{'status'} ne 'down') {
	$out .= $text{'schange_shutting'}."\n";
	my $err = &shutdown_server($server);
	if ($err) {
		$out .= &text('smove_shutfailed', $err)."\n\n";
		return ( $err, $out );
		}
	else {
		$out .= $text{'create_done'}."\n\n";
		}
	$was_up = 1;
	}

# Expand the disk
$out .= &text('schange_disksize', $disk->{'virt'},
	      &nice_size($disk->{'size'}), &nice_size($sched->{'size'}))."\n";
my $olddisk = { %$disk };
$disk->{'size'} = $sched->{'size'};
my $cfunc = "type_".$server->{'manager'}."_modify_disk";
my $err = &$cfunc($server, $disk, $olddisk);
if ($err) {
	$out .= &text('smove_diskfailed', $err)."\n\n";
	return ( $err, $out );
	}
else {
	$out .= $text{'create_done'}."\n\n";
	}

# Start up again if down before
if ($was_up) {
	$out .= $text{'schange_starting'}."\n";
	my $err = &startup_server($server);
	if ($err) {
		$out .= &text('smove_startfailed', $err)."\n\n";
		return ( $err, $out );
		}
	else {
		$out .= $text{'create_done'}."\n\n";
		}
	}

return ( undef, $out );
}

1;

