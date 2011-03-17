# Functions for configuring automatic DNS round-robin entries

# list_roundrobins()
# Returns a list of all configured DNS roundrobins
sub list_roundrobins
{
my @rv;
opendir(RR, $roundrobins_dir);
foreach my $f (readdir(RR)) {
	next if ($f =~ /^\./);
	my $rr = &get_roundrobin($f);
	if ($rr) {
		push(@rv, $rr);
		}
	}
close(RR);
return sort { $a->{'id'} <=> $b->{'id'} } @rv;
}

# get_roundrobin(id)
# Returns the hash ref for a single roundrobin DNS entry. Keys are :
# id - A unique ID
# desc - Human-readable description for this roundrobin
# dom - Domain name the record is in
# name - Record name within the domain
# servers - IDs of servers to include
# groups - Names of groups of servers to include
# status - List of acceptable status codes
# alerts - IDs of alerts that must not be firing
# ports - TCP ports that must be open
# url - URL on hosts that must respond with a 200
# min - Minimum hosts that should be in the roundrobin
# master - Send email to master if roundrobin is too small
# email - Send email to this address if too small
# interval - Period in seconds between sending alert emails
sub get_roundrobin
{
my ($id) = @_;
my %rr;
&read_file_cached("$roundrobins_dir/$id", \%rr) || return undef;
$rr{'id'} = $id;
return \%rr;
}

# save_roundrobin(&roundrobin)
# Create or update a DNS roundrobin entry
sub save_roundrobin
{
my ($rr) = @_;
if (!-r $roundrobins_dir) {
	&lock_file($roundrobins_dir);
	&make_dir($roundrobins_dir, 0700);
	&unlock_file($roundrobins_dir);
	}
$rr->{'id'} ||= &server_id();
my $file = "$roundrobins_dir/$rr->{'id'}";
&lock_file($file);
&write_file($file, $rr);
&unlock_file($file);
}

# delete_roundrobin(&roundrobin)
# Deletes a DNS roundrobin (but not the DNS record)
sub delete_roundrobin
{
my ($rr) = @_;
my $file = "$roundrobins_dir/$rr->{'id'}";
&lock_file($file);
&unlink_file($file);
&unlock_file($file);
}

# get_roundrobin_servers(&roundrobin, &all-servers)
# Returns a list of server objects that some roundrobin may include
sub get_roundrobin_servers
{
my ($rr, $allservers) = @_;
my @rv;
if ($rr->{'servers'}) {
	# Get just ones we want
	foreach my $id (split(/\s+/, $rr->{'servers'})) {
		my ($s) = grep { $_->{'id'} eq $id } @$allservers;
		push(@rv, $s) if ($s);
		}
	}
elsif ($rr->{'groups'}) {
	# Just members of some groups
	my %want = map { $_, 1 } split(/\s+/, $rr->{'groups'});
	foreach my $s (@$allservers) {
		my ($ing) = grep { $want{$_} } split(/\t+/, $s->{'group'});
		push(@rv, $s) if ($ing);
		}
	}
elsif ($rr->{'owners'}) {
	# Owned by some users
	foreach my $o (split(/\s+/, $rr->{'owners'})) {
		my $owner = &get_system_owner($o);
		if ($owner) {
			my %owned = map { $_, 1 }
				split(/\s+/, $owner->{'acl'}->{'servers'});
			push(@rv, grep { $owned{$_->{'id'}} } @$allservers);
			}
		}
	}
# Filter out dupes
my %done;
return grep { !$done{$_->{'id'}}++ } @rv;
}

# evaluate_roundrobin(&roundrobin, &servers)
# Update the DNS record for some roundrobin, and set the include field with
# server IDs that were used
sub evaluate_roundrobin
{
my ($rr, $allservers) = @_;
my @servers = &get_roundrobin_servers($rr, $allservers);
my @whynot;

# Acceptable statuses
my %selst = map { $_, 1 } split(/\s+/, $rr->{'status'});
my @ports = split(/\s+/, $rr->{'ports'});

# Get alerts to check, and their statuses and systems
my $astatus = &get_alert_statuses();
my %afiring;
foreach my $aid (split(/\s+/, $rr->{'alerts'})) {
	my $st = $astatus{$aid};
	if ($st && $st->{'firing'}) {
		# Alert is firing .. but for which systems?
		my $a = &get_alert($aid);
		foreach my $av (split(/,/, $st->{'values'})) {
			my ($avid, $avv) = split(/:/, $av);
			$afiring{$avid} ||= [ ];
			push(@{$afiring{$avid}}, $a);
			}
		}
	}

# Find usable servers
my @inc;
SERVER: foreach my $s (@servers) {
	# Check acceptable status
	if (!$selst{$s->{'status'}}) {
		push(@whynot, [ $s->{'id'}, 'status', $s->{'status'} ]);
		next;
		}

	# Filter by firing alerts
	my $firing = $afiring{$s->{'id'}};
	if (@$firing) {
		push(@whynot, [ $s->{'id'}, 'alert',
			join(",", map { $_->{'id'} } @$firing) ]);
		next;
		}

	# Filter by open ports
	foreach my $p (@ports) {
		alarm(5);
		my $err;
		eval {
			#local $SIG{'CHLD'} = die { "timeout" };
			#my $ip = &get_server_ip($s);
			#&open_socket($ip, $p, TESTSOCK, \$err);
			#close(TESTSOCK);
			};
		alarm(0);
		if ($@) {
			print STDERR $@,"\n";
			push(@whynot, [ $s->{'id'}, 'timeout', $p ]);
			next SERVER;
			}
		elsif ($err) {
			push(@whynot, [ $s->{'id'}, 'port', $p ]);
			next SERVER;
			}
		}

	# Filter by URL
	if ($rr->{'url'}) {
		my $url = &substitute_template($rr->{'url'}, $s);
		my ($host, $port, $page, $ssl) = &parse_http_url($url);
		if ($host && $page) {
			my ($err, $out);
			&http_download($host, $port, $page, \$out, \$err, $ssl,
				       undef, undef, 5, 0, 1);
			if ($err) {
				push(@whynot, [ $s->{'id'}, 'url', $url ]);
				next SERVER;
				}
			}
		}

	push(@inc, $s);
	}

# Find DNS record and update
my ($ok, $msg);
if (@inc) {
	my @ips;
	my @cmts;
	my %done;
	foreach my $s (@inc) {
		my $ip = &get_server_ip($s);
		if (!$done{$ip}++) {
			push(@ips, $ip);
			push(@cmts, $s->{'host'});
			}
		}
	($ok, $msg) = &set_bind_dns_addresses(
	    $rr->{'name'}.".".$rr->{'dom'}.".", $rr->{'dom'}, \@ips, \@cmts);
	}
else {
	$ok = 0;
	$msg = "No usable systems found - leaving DNS record un-changed";
	}

# Record list of systems to include
$rr->{'include'} = join(" ", map { $_->{'id'} } @inc);

# Record rejection reasons
$rr->{'whynot'} = join("\t", map { join(",", @$_) } @whynot);

# Return status code
return ($ok, $msg);
}

# evaluate_all_roundrobins([&only-servers], [&only-rrs], [no-email])
# Check all roundrobins, and send email if any have too few hosts.
sub evaluate_all_roundrobins
{
my ($servers, $roundrobins, $noemail) = @_;
$servers ||= [ &list_managed_servers() ];
$roundrobins ||= [ &list_roundrobins() ];
my $now = time();
foreach my $rr (@$roundrobins) {
	&evaluate_roundrobin($rr, $servers);
	my @inc = split(/\s+/, $rr->{'include'});
	if (@inc < $rr->{'min'}) {
		# Time to email?
		my $sincelast = $now - $rr->{'lastemail'};
		if ($sincelast > $rr->{'interval'}) {
			&send_roundrobin_email($rr);
			$rr->{'lastemail'} = $now;
			}
		}
	&save_roundrobin($rr);
	}
}

# send_roundrobin_email(&rr)
# Send email when a roundrobin's systems are too few 
sub send_roundrobin_email
{
my ($rr) = @_;
# XXX
}

# describe_roundrobin_status(&roundrobin)
# Returns a string describing systems included in the roundrobin
sub describe_roundrobin_status
{
my ($rr) = @_;
my @inc = split(/\s+/, $rr->{'include'});
my @whynot = split(/\s+/, $rr->{'whynot'});
if (@whynot) {
	return &text('roundrobins_stbad', scalar(@inc), scalar(@whynot));
	}
elsif (@inc) {
	return &text('roundrobins_stok', scalar(@inc));
	}
else {
	return $text{'roundrobins_stnot'};
	}
}

1;

