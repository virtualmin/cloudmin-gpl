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
# ttl - TTL for DNS record, in seconds
# dnscount - Number of systems to create A records for
# servers - IDs of servers to include
# groups - Names of groups of servers to include
# iplist - IPs of servers to include
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

# delete_roundrobin_dns(&roundrobin)
# Deletes a DNS roundrobin's DNS record. Returns an error message on failure.
sub delete_roundrobin_dns
{
my ($rr) = @_;
my ($ok, $msg) = &set_bind_dns_addresses($rr->{'name'}.".".$rr->{'dom'}.".",
					 $rr->{'dom'}, [ ], [ ]);
return $ok ? undef : $msg;
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
elsif ($rr->{'scalegroups'}) {
	# In some auto-scaling groups
	foreach my $id (split(/\s+/, $rr->{'scalegroups'})) {
		push(@rv, grep { $_->{'scalegroup'} eq $id } @$allservers);
		}
	}
elsif ($rr->{'iplist'}) {
	# With some IPs
	foreach my $ip (split(/\s+/, $rr->{'iplist'})) {
		push(@rv, &make_server_from_ip($ip, $allservers));
		}
	}
# Filter out dupes
my %done;
return grep { !$done{$_->{'id'}}++ } @rv;
}

# make_server_from_ip(ip, &all-servers)
# If some system has the given IP, return it. Otherwise return a system with
# an 'alive' status only.
sub make_server_from_ip
{
my ($ip, $allservers) = @_;
foreach my $s (@$allservers) {
	return $s if ($s->{'ip'} eq $ip);
	foreach my $i (split(/\s+/, $s->{'ip_addresses'})) {
		return $s if ($i eq $ip);
		}
	}
return { 'id' => $ip,
	 'host' => $ip,
	 'ip' => $ip,
	 'ip_addresses' => $ip,
	 'ssh_nologin' => 1,
	 'status' => 'alive',
	 'fake' => 1 };
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
	my $st = $astatus->{$aid};
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
	# Work out status for fake systems
	if ($s->{'fake'}) {
		$s->{'status'} = &ping_server_host($s->{'ip'}) ? 'alive'
							       : 'down';
		}

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
			local $SIG{'CHLD'} = sub { die "timeout" };
			my $ip = &get_server_ip($s);
			&open_socket($ip, $p, TESTSOCK, \$err);
			close(TESTSOCK);
			};
		alarm(0);
		if ($@) {
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
	my @iplist = split(/\s+/, $rr->{'iplist'});
	foreach my $s (@inc) {
		my $ip = $s->{'external_ip'} || &get_server_ip($s);
		if (@iplist && !$s->{'fake'}) {
			# If using an specific list of IP addresses and this
			# managed system has an IP in the list, use that instead
			# of the primary IP.
			foreach my $sip (&get_server_ip($s)) {
				if (&indexof($sip, @iplist) >= 0) {
					$ip = $sip;
					}
				}
			}
		if (!$done{$ip}++) {
			push(@ips, $ip);
			push(@cmts, $s->{'host'});
			}
		}
	if ($rr->{'dnscount'} && @inc > $rr->{'dnscount'}) {
		# Limit to first N IPs
		@ips = @ips[0 .. $rr->{'dnscount'}-1];
		@cmts = @cmts[0 .. $rr->{'dnscount'}-1];
		$rr->{'dnsover'} =
			join(" ", map { $_->{'id'} }
			     @inc[$rr->{'dnscount'} .. $#inc]);
		}
	($ok, $msg) = &set_bind_dns_addresses(
	    $rr->{'name'}.".".$rr->{'dom'}.".", $rr->{'dom'}, \@ips, \@cmts,
	    $rr->{'ttl'});
	}
else {
	$ok = 0;
	$msg = "No usable systems found - leaving DNS record un-changed";
	}

# Update proxy balancer, if any
if (@inc && $rr->{'bhost'} ne '') {
	my $bserver = &get_managed_server($rr->{'bhost'});
	if (!$bserver) {
		$ok = 0;
		$msg = "Proxy balancer system was not found";
		}
	else {
		# Work out URLs
		my $sfx = $rr->{'burl'} =~ /\/$/ ? "/" : "";
		my $port = $rr->{'bport'} == 80 ? "" : ":".$rr->{'bport'};
		my @urls = map { "http://".$_->{'host'}.$port.$sfx } @inc;

		# Get existing proxy, if possible
		my ($err, $out) = &call_virtualmin_api($bserver, "list-proxies",
			[ [ "domain", $rr->{'bdomain'} ],
			  [ "multiline" ] ]);
		my @lines = split(/\r?\n/, $out);
		my $idx = &indexof($rr->{'burl'}, @lines);
		my $same = 0;
		my @oldurls;
		my $existing = 0;
		if ($idx >= 0) {
			$existing = 1;
			for(my $i=$idx+1; $i<@lines &&
					  $lines[$i] !~ /^\//; $i++) {
				if ($lines[$i] =~ /URL:\s+(\S+)/) {
					push(@oldurls, $1);
					}
				}
			if (scalar(@oldurls) == scalar(@urls) &&
			    join(" ", @oldurls) eq join(" ", @urls)) {
				$same = 1;
				}
			}

		if (!$same) {
			# Delete existing proxy .. failure doesn't matter
			my ($err, $out) = &call_virtualmin_api(
				$bserver, "delete-proxy",
				[ [ "domain", $rr->{'bdomain'} ],
				  [ "path", $rr->{'burl'} ] ]);

			# Create a new one
			my ($err, $out) = &call_virtualmin_api(
				$bserver, "create-proxy",
				[ [ "domain", $rr->{'bdomain'} ],
				  [ "path", $rr->{'burl'} ],
				  map { [ "url", $_ ] } @urls ]);
			if ($err) {
				$ok = 0;
				$msg = "Proxy balancer update failed on ".
				       "$bserver->{'host'} in ".
				       "$rr->{'bdomain'} : $err";
				}
			}
		}
	}

# Record list of systems to include
$rr->{'include'} = join(" ", map { $_->{'id'} } @inc);

# Record rejection reasons
$rr->{'whynot'} = join("\t", map { join(",", @$_) } @whynot);

# Record failure reason
if (!$ok) {
	$msg =~ s/\r|\n/ /g;
	$rr->{'msg'} = $msg;
	}
else {
	delete($rr->{'msg'});
	}

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
my @errs;
foreach my $rr (@$roundrobins) {
	my ($ok, $msg) = &evaluate_roundrobin($rr, $servers);
	my @inc = split(/\s+/, $rr->{'include'});
	if (@inc < $rr->{'min'} || !$ok) {
		# Time to email?
		my $sincelast = $now - $rr->{'lastemail'};
		if ($sincelast > $rr->{'interval'}) {
			&send_roundrobin_email($rr, $ok, $msg);
			$rr->{'lastemail'} = $now;
			}
		}
	$rr->{'lastcheck'} = $now;
	&save_roundrobin($rr);
	push(@errs, [ $rr, $msg ]) if (!$ok);
	}
return @errs;
}

# send_roundrobin_email(&rr, updated-ok, error-message)
# Send email when a roundrobin's systems are too few 
sub send_roundrobin_email
{
my ($rr, $ok, $emsg) = @_;
&foreign_require("mailboxes", "mailboxes-lib.pl");
my @rrservers = &get_roundrobin_servers($rr, \@allservers);

# Work out who to notify
my @emails;
if ($config{'bw_email'} && $rr->{'master'}) {
	# Master admin
	push(@emails, $config{'bw_email'});
	}
if ($alert->{'email'}) {
	# Other addresses
	push(@emails, split(/[ ,]+/, $alert->{'email'}));
	}

# Construct email message about status
my $fmt = "%-25.25s %-15.15s %-35.35s\n";
my @inc = split(/\s+/, $rr->{'include'});
my @whynot = map { [ split(",", $_, 3) ] } split(/\s+/, $rr->{'whynot'});
my $msg;
if ($ok) {
	# Start email about system failures
	$msg = &text('remail_desc',
		     $rr->{'name'}.".".$rr->{'dom'},
		     scalar(@inc), $rr->{'min'});
	$msg = join("\n", &mailboxes::wrap_lines($msg, 75))."\n";
	$msg .= "\n";
	$msg .= $text{'rmail_whynot'}."\n";
	}
else {
	# Start email about update errors
	$msg = &text('remail_desc2',
		     $rr->{'name'}.".".$rr->{'dom'}, $emsg);
	$msg = join("\n", &mailboxes::wrap_lines($msg, 75))."\n";
	$msg .= "\n";
	$msg .= $text{'rmail_whynot2'}."\n";
	}
$msg .= "\n";
my $from;
if (@whynot) {
	$msg .= sprintf $fmt, $text{'roundrobin_host'},
			      $text{'roundrobin_ip'},
			      $text{'remail_reason'};
	$msg .= sprintf $fmt, ("-" x 25), ("-" x 15), ("-" x 35);
	foreach my $w (@whynot) {
		my ($s) = grep { $_->{'id'} eq $w->[0] } @rrservers;
		$s ||= &get_managed_server($w->[0]);
		next if (!$s);
		my $ip = &get_server_ip($s);
		$from ||= &get_global_from_address($s);
		my ($r, $m) = ($w->[1], $w->[2]);
		if ($r eq 'status') {
			$m = &describe_status({ 'status' => $m });
			}
		elsif ($r eq 'alert') {
			my @alerts = grep { $_ } map { &get_alert($_) }
					  split(",", $m);
			$m = &describe_alert_rules($alerts[0]);
			}
		$msg .= sprintf $fmt, $s->{'host'}, $ip,
				      &text('remail_status_'.$r, $m);
		}
	}
else {
	$msg .= $text{'remail_empty'}."\n";
	}
if (!$ok) {
	foreach my $i (@inc) {
		my ($s) = grep { $_->{'id'} eq $i } @rrservers;
		$s ||= &get_managed_server($i);
		next if (!$s);
		my $ip = &get_server_ip($s);
		$from ||= &get_global_from_address($s);
		$msg .= sprintf $fmt, $s->{'host'}, $ip,
				      &text('remail_status_ok');
		}
	}
$from ||= &get_global_from_address();

# Send the email
my $email = join(", ", @emails);
my $subject = &text('remail_subject', $rr->{'name'}.".".$rr->{'dom'},
				      scalar(@inc));
&mailboxes::send_text_mail($from, $email, undef, $subject, $msg);
}

# describe_roundrobin_status(&roundrobin)
# Returns a string describing systems included in the roundrobin
sub describe_roundrobin_status
{
my ($rr) = @_;
my @inc = split(/\s+/, $rr->{'include'});
my @whynot = split(/\s+/, $rr->{'whynot'});
my $rv;
if (@whynot) {
	$rv = "<font color=red>".
	      &text('roundrobins_stbad', scalar(@inc), scalar(@whynot)).
	      "</font>";
	}
elsif (@inc) {
	$rv = &text('roundrobins_stok', scalar(@inc));
	}
else {
	$rv = $text{'roundrobins_stnot'};
	}
if ($rr->{'msg'}) {
	$rv .= " (<font color=red>".
               &text('roundrobins_fail', $rr->{'msg'})."</font>)";
	}
return $rv;
}

1;

