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
return @rv;
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
# Delete one multi-system alert
sub delete_alert
{
my ($alert) = @_;
my $file = $alerts_dir."/".$alert->{'id'};
&lock_file($file);
&unlink_file($file);
&unlock_file($file);
}

# evaluate_alert(&alert, [when])
# Checks if an alert is active, and if so returns a hash ref with details of
# how it matched and a message.
sub evaluate_alert
{
my ($alert, $when) = @_;
# XXX
}

# evaluate_all_alerts(&servers)
# Check all alerts and send email if any are firing. Also update current
# alert status file.
sub evaluate_all_alerts
{
my ($servers) = @_;
}

# get_alert_statuses()
# Returns a hash ref from alert IDs to their current statuses, each of which
# is a hash ref.
sub get_alert_statuses
{
# XXX
# alert_status_file
}

# save_alert_statuses(&statuses)
# Updates the file containing current alert statuses
sub save_alert_status
{
# XXX
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
					        @servers));
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

1;

