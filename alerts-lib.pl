# Functions for creating multi-system alerts

# list_alerts()
# Returns an array of all alerts, each of which is a hash ref with the keys :
# id - Unique ID number
# all - Set to 1 if applying to all servers
# servers - List of server IDs to apply to
# groups - List of group names to apply to
# owners - List of owners whose systems to apply to
# managers - List of system types to apply to
# rules - Array ref of rule hash refs, each of which contains
#	name - Variable to match on, like load, mem, space
#	value - Cutoff value for alerting
#	over/under - Match if variable is over or under the value
#	for - Optional period is seconds that this must be true for
#	count - Optional number of systems that this must be true for
# and/or - Set to 1 depending on whether one or all of the rules must match
# desc - Optional message for this alert
# master - Send email to master admin
# owner - Send email to system owner
# email - Send email to this address
# interval - Period in seconds between sending alert emails
sub list_alerts
{
my @rv;
opendir(DIR, $alerts_dir);
foreach my $f (readdir(DIR)) {
	next if ($f =~ /^\./);
	my %alert;
	&read_file_cached("$alerts_dir/$f", \%alert) || next;
	my @rules;
	for(my $i=0; defined($alert{"rule_$i"}); $i++) {
		push(@rules, { map { split(/=/, $_) }
			       split(/\s+/, $alert{"rule_$i"}) });
		delete($alert{"rule_$i"});
		}
	$alert{'rules'} = \@rules;
	push(@rv, \%alert);
	}
return sort { $a->{'id'} <=> $b->{'id'} } @rv;
}

# get_alert(id)
# Returns just the alert with some ID
sub get_alert
{
my ($id) = @_;
my ($alert) = grep { $_->{'id'} eq $id } &list_alerts();
return $alert;
}

# save_alert(&alert)
# Create or update an alert
sub save_alert
{
my ($alert) = @_;
if (!-d $alerts_dir) {
	&lock_file($alerts_dir);
	&make_dir($alerts_dir, 0700);
	&unlock_file($alerts_dir);
	}
$alert->{'id'} ||= &server_id();
my $file = $alerts_dir."/".$alert->{'id'};
&lock_file($file);
my %asave = %$alert;
delete($asave{'rules'});
my $i = 0;
foreach my $r (@{$alert->{'rules'}}) {
	$asave{'rule_'.$i} = join(" ", map { $_."=".$r->{$_} } keys %$r);
	$i++;
	}
&write_file($file, \%asave);
&unlock_file($file);
}

# delete_alert(&alert)
# Delete one multi-system alert, and its status
sub delete_alert
{
my ($alert) = @_;
my $file = $alerts_dir."/".$alert->{'id'};
&lock_file($file);
&unlink_file($file);
&unlock_file($file);
&lock_file($alert_status_file);
my $statuses = &get_alert_statuses();
delete($statuses->{$alert->{'id'}});
&save_alert_statuses($statuses);
&unlock_file($alert_status_file);
}

# evaluate_alert(&alert, &servers, [when])
# Checks if an alert is active, and if so returns a hash ref with details of
# how it matched and a message. Returns undef if no servers were found.
sub evaluate_alert
{
my ($alert, $allservers) = @_;
$when ||= time();
my @servers = &get_alert_servers($alert, $allservers);
if ($alert->{'uponly'}) {
	@servers = grep { &can_ssh_status($_) } @servers;
	}
return undef if (!@servers);

# See which rules match
my @firing;
foreach my $r (@{$alert->{'rules'}}) {
	my $start = $when - $r->{'for'};
	my (@fservers, @fvalues);
	my $rvalue =
		$r->{'value'} =~ /^([0-9\.]+)\s*KB?/i ? $1*1024 :
		$r->{'value'} =~ /^([0-9\.]+)\s*MB?/i ? $1*1024*1024 :
		$r->{'value'} =~ /^([0-9\.]+)\s*GB?/i ? $1*1024*1024*1024 :
		$r->{'value'} =~ /^([0-9\.]+)\s*TB?/i ? $1*1024*1024*1024*1024 :
						        $r->{'value'};
	foreach my $s (@servers) {
		my @info = &list_historic_collected_info($r->{'name'}, $s,
							 $start, $when);
		my $icount = 0;
		foreach my $i (@info) {
			if ($r->{'over'} && $i->[1] > $rvalue ||
			    !$r->{'over'} && $i->[1] < $rvalue) {
				$icount++;
				}
			}
		if (scalar(@info) && $icount == scalar(@info)) {
			# All values matched for time range
			push(@fservers, $s);
			push(@fvalues, $info[$#info]->[1]);
			}
		}
	if (@fservers >= $r->{'count'}) {
		push(@firing, { 'name' => $r->{'name'},
			        'servers' => \@fservers,
				'values' => \@fvalues });
		}
	}

# Create and return status object
my $st = { };
$st->{'firing'} =
	$alert->{'or'} && scalar(@firing) > 0 ||
	$alert->{'and'} && scalar(@firing) == scalar(@{$alert->{'rules'}});
my (@stnames, @stvalues);
foreach my $f (@firing) {
	for(my $i=0; $i<@{$f->{'servers'}}; $i++) {
		push(@stnames, $f->{'name'});
		push(@stvalues, $f->{'servers'}->[$i]->{'id'}.":".
				$f->{'values'}->[$i]);
		}
	}
$st->{'names'} = join(",", @stnames);
$st->{'values'} = join(",", @stvalues);

return $st;
}

# evaluate_all_alerts([&only-servers], [&only-alerts], [no-email])
# Check all alerts and send email if any are firing. Also update current
# alert status file.
sub evaluate_all_alerts
{
my ($servers, $alerts, $noemail) = @_;
$servers ||= [ &list_managed_servers() ];
$alerts ||= [ &list_alerts() ];
&lock_file($alert_status_file);
my $statuses = &get_alert_statuses();
my $now = time();
foreach my $alert (@$alerts) {
	my $oldst = $statuses->{$alert->{'id'}};
	my $st = &evaluate_alert($alert, $servers);
	next if (!$st);
	$statuses->{$alert->{'id'}} = $st;
	if ($st->{'firing'} && !$noemail) {
		# Send email if not silenced, and if time since last email is
		# greater than notification interval
		my $sincelast = $now - $alert->{'lastemail'};
		$st->{'start'} = $oldst->{'start'} || $now;
		if (!$alert->{'silenced'} &&
		    $sincelast > $alert->{'interval'}) {
			&send_alert_email($alert, $st);
			$alert->{'lastemail'} = $now;
			&save_alert($alert);
			}
		}
	}
&save_alert_statuses($statuses);
&unlock_file($alert_status_file);
}

# send_alert_email(&alert, &status)
# Send email about some alert firing to all relevant users
sub send_alert_email
{
my ($alert, $st) = @_;
&foreign_require("mailboxes", "mailboxes-lib.pl");

# Find systems and values in the alert
my @names = split(/,/, $st->{'names'});
my @idvalues = split(/,/, $st->{'values'});
my @problems;
for(my $i=0; $i<@names; $i++) {
	my $name = $names[$i];
	my ($id, $value) = split(/:/, $idvalues[$i]);
	my $s = &get_managed_server($id);
	next if (!$s);
	my ($r) = grep { $_->{'name'} eq $name } @{$alert->{'rules'}};
	next if (!$r);
	push(@problems, [ $s, $name, $value, $r->{'value'}, $st->{'start'} ]);
	}

# Work out who to notify
my @emails;
if ($config{'bw_email'} && $alert->{'master'}) {
	# Master admin
	push(@emails, [ $config{'bw_email'}, \@problems, 1 ]);
	}
if ($alert->{'owner'}) {
	# Email owners, but only about their own systems
	my @allowners = map { &get_server_owners($_->[0]) } @problems;
	my %doneowners;
	foreach my $owner (@allowners) {
		next if ($doneowners{$owner->{'name'}}++);
		next if (!$owner->{'acl'}->{'email'});
		my %owned = map { $_, 1 }
				split(/\s+/, $owner->{'acl'}->{'servers'});
		my @ownerproblems = grep { $owner{$_->[0]->{'id'}} } @problems;
		push(@emails, [ $owner->{'acl'}->{'email'},
				\@ownerproblems, 0 ]);
		}
	}
if ($alert->{'email'}) {
	# Other addresses
	push(@emails, map { [ $_, \@problems, 1 ] }
			  split(/[ ,]+/, $alert->{'email'}));
	}

# For each email, construct the message based on its problems and send it
foreach my $ep (@emails) {
	my ($email, $problems) = @$ep;
	next if (!@$problems);
	my @servers = map { $_->[0] } @$problems;

	my $subject = $alert->{'desc'};
	if (!$subject) {
		# Construct subject based on alert
		my $pfx = "aemail_subject";
		if (@servers > 1) {
			$subject = &text($pfx.'1', scalar(@servers));
			}
		else {
			$subject = &text($pfx.'2', $servers[0]->{'host'});
			}
		if (@$problems == 1) {
			$subject .= " : ".$text{'history_stat_'.
						$problems->[0]->[1]};
			}
		}

	# Create message body listing systems, names, limits and values
	my $fmt = "%-25.25s %-20.20s %-6.6s %-6.6s %-17.17s\n";
	my $msg;
	$msg .= "\n";
	$msg .= $text{'aemail_desc'}."\n";
	$msg .= "\n";
	$msg .= sprintf $fmt, $text{'alerts_server'},
				$text{'alerts_stat'},
				$text{'aemail_cutoff'},
				$text{'aemail_value'},
				$text{'aemail_started'};
	$msg .= sprintf $fmt, ("-"  x 25), ("-" x 20), ("-" x 6),
			      ("-" x 6), ("-" x 17);
	foreach my $p (@$problems) {
		$msg .= sprintf $fmt,
			$p->[0]->{'host'},
			$text{'history_stat_'.$p->[1]} || $p->[1],
			$p->[3],
			$p->[3] =~ /(K|M|G|T)B?$/ ? &nice_size($p->[2])
						  : $p->[2],
			&make_date($p->[4]);
		}

	# Add link to Virtualmin's alerts page, except for owners
	my $url = &get_server_manager_url()."/$module_name/list_alerts.cgi";
	$msg .= "\n";
	$msg .= $text{'aemail_link'}."\n";
	$msg .= $url."\n";

	&mailboxes::send_text_mail(
		&get_global_from_address($problems->[0]),
		$email,
		undef,
		$subject,
		$msg);
	}
}

# get_alert_servers(&alert, &allservers)
# Returns the list of systems that some alert triggers on
sub get_alert_servers
{
my ($alert, $allservers) = @_;
my @rv;
if ($alert->{'all'}) {
	# Monitoring everyone
	@rv = @$allservers;
	}
elsif ($alert->{'servers'}) {
	# Get just ones we want
	foreach my $id (split(/\s+/, $alert->{'servers'})) {
		my ($s) = grep { $_->{'id'} eq $id } @$allservers;
		push(@rv, $s) if ($s);
		}
	}
elsif ($alert->{'groups'}) {
	# Just members of some groups
	my %want = map { $_, 1 } split(/\s+/, $alert->{'groups'});
	foreach my $s (@$allservers) {
		my ($ing) = grep { $want{$_} } split(/\t+/, $s->{'group'});
		push(@rv, $s) if ($ing);
		}
	}
elsif ($alert->{'owners'}) {
	# Owned by some users
	foreach my $o (split(/\s+/, $alert->{'owners'})) {
		my $owner = &get_system_owner($o);
		if ($owner) {
			my %owned = map { $_, 1 }
				split(/\s+/, $owner->{'acl'}->{'servers'});
			push(@rv, grep { $owned{$_->{'id'}} } @$allservers);
			}
		}
	}
elsif ($alert->{'managers'}) {
	# Of some virtual type
	foreach my $t (split(/\s+/, $alert->{'managers'})) {
		push(@rv, grep { $_->{'manager'} eq $t } @$allservers);
		}
	}
# Filter out dupes
my %done;
return grep { !$done{$_->{'id'}}++ } @rv;
}

# get_alert_statuses()
# Returns a hash ref from alert IDs to their current statuses, each of which
# is a hash ref with the keys :
# firing - Set to 1 if triggered, 0 if not
# start - Time it started firing
# names - Comma-separated list of triggering variables
# values - Comma-separated list of triggering serverid:value for those variables
sub get_alert_statuses
{
my %stfile;
&read_file_cached($alert_status_file, \%stfile);
my $rv = { };
foreach my $id (keys %stfile) {
	my %st = map { split(/=/, $_, 2) } split(/\s+/, $stfile{$id});
	$rv->{$id} = \%st;
	}
return $rv;
}

# save_alert_statuses(&statuses)
# Updates the file containing current alert statuses
sub save_alert_statuses
{
my ($rv) = @_;
my %stfile;
foreach my $id (keys %$rv) {
	my $st = $rv->{$id};
	$stfile{$id} = join(" ", map { $_."=".$st->{$_} } keys %$st);
	}
&write_file($alert_status_file, \%stfile);
}

# list_for_units()
# Returns a list of array refs containing unit codes and strings
sub list_for_units
{
return map { [ $_, $text{'alert_unit'.$_} ] } ('s', 'm', 'h', 'd');
}

# split_for_units(secs)
# Converts a number of seconds into a units code and number, like 3600
# into 'h' and 1
sub split_for_units
{
my ($s) = @_;
my @rv;
if ($s < 60) {
	@rv = ('s', $s);
	}
elsif ($s < 60*60) {
	@rv = ('m', $s/60.0);
	}
elsif ($s < 24*60*60) {
	@rv = ('h', $s/(60*60.0));
	}
else {
	@rv = ('d', $s/(24*60*60.0));
	}
$rv[1] = sprintf("%.2f", $rv[1]);
$rv[1] =~ s/\.00$//;
return @rv;
}

# join_for_units(units, number)
# Converts a units code and number into a count in seconds
sub join_for_units
{
my ($u, $n) = @_;
if ($u eq 'm') {
	$n *= 60;
	}
elsif ($u eq 'h') {
	$n *= 60*60;
	}
elsif ($u eq 'd') {
	$n *= 24*60*60;
	}
return int($n);
}

# describe_alert_servers(&alert)
# Returns a text string describing the systems checked in some alert
sub describe_alert_servers
{
my ($alert) = @_;
if ($alert->{'all'}) {
	# All systems
	return $text{'alertdesc_all'};
	}
elsif ($alert->{'servers'}) {
	# Listed systems
	my @users = map { &get_managed_server($_) }
			split(/\s+/, $alert->{'servers'});
	return @users > 4 ? &text('alertdesc_many', scalar(@users))
			  : &text('alertdesc_servers',
				  join(" ", map { "<tt>$_->{'host'}</tt>" }
					        @users));
	}
elsif ($alert->{'groups'}) {
	# Members of groups
	return &text('alertdesc_groups', "<tt>$alert->{'groups'}</tt>");
	}
elsif ($alert->{'owners'}) {
	# Systems with owners
	return &text('alertdesc_owners', "<tt>$alert->{'owners'}</tt>");
	}
elsif ($alert->{'managers'}) {
	# Systems of types
	return &text('alertdesc_types',
		     join(", ", map { $text{$_.'_typedesc'} } 
				    split(/\s+/, $alert->{'managers'})));
	}
else {
	return "???";
	}
}

# describe_alert_rules(&alert)
# Returns a text string describing the rule(s) that trigger an alert
sub describe_alert_rules
{
my ($alert) = @_;
my @descs;
foreach my $r (@{$alert->{'rules'}}) {
	my ($forunit, $for) = &split_for_units($r->{'for'});
	my $desc = &text($r->{'over'} ? 'alert_rdescover'
				      : 'alert_rdescunder',
			$text{'history_stat_'.$r->{'name'}},
			$r->{'value'},
			$for.$forunit);
	if ($r->{'count'} > 1) {
		$desc .= " ".&text('alert_cdesc', $r->{'count'});
		}
	push(@descs, $desc);
	}
return join(", ".($alert->{'and'} ? $text{'alert_rand'}
				  : $text{'alert_ror'})." ", @descs);
}

# describe_alert_status(&alert, &status)
# Returns a string describing the firing status for some alert
sub describe_alert_status
{
my ($alert, $st) = @_;
if (!$st) {
	return $text{'alert_stnone'};
	}
my @ids = map { ($id) = split(/:/, $_); $id } split(/,/, $st->{'values'});
if ($st->{'firing'}) {
	# Triggering now
	if (@ids > 1) {
		$msg = &text('alert_stfiring2', scalar(@ids));
		}
	else {
		my $s = &get_managed_server($ids[0]);
		$msg = &text('alert_stfiring', $s->{'host'});
		}
	$msg = "<font color=#ff0000>$msg</font>";
	}
else {
	# Still OK
	if (@ids == 0) {
		$msg = $text{'alert_stquiet'};
		}
	elsif (@ids > 1) {
		$msg = &text('alert_stbelow2', scalar(@ids));
		}
	else {
		my $s = &get_managed_server($ids[0]);
		$msg = &text('alert_stbelow', $s->{'host'});
		}
	$msg = "<font color=#00aa00>$msg</font>";
	}
if ($alert->{'silenced'}) {
	$msg .= " ".$text{'alert_stsilenced'};
	}
return $msg;
}

1;

