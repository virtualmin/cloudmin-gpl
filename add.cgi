#!/usr/local/bin/perl
# Add some existing server

require './server-manager-lib.pl';
&ReadParse();
&can_add_server_error($in{'type'});
&error_setup($text{'add_err'});
@servers = &list_managed_servers();
$server = { 'manager' => $in{'type'},
	    'id' => &server_id(), };

# Validate inputs, starting with hostname
$server->{'ip'} = $server->{'ip_addresses'} = &to_ipaddress($in{'host'});
my $rfunc = "type_".$server->{'manager'}."_requires_resolution";
if (!defined(&$rfunc) || &$rfunc($server)) {
	$server->{'ip'} || &error($text{'add_ehost'});
	}
$server->{'host'} = $in{'host'};
$server->{'desc'} = $in{'desc'};
if (&can_action($server, "groups")) {
	&parse_groups_form($server, \%in);
	}

# Check for hostname clash
($clash) = grep { $_->{'host'} eq $in{'host'} } @servers;
$clash && &error($text{'add_eclash'});

# Validate owner resource limits
$limits = &get_owner_limits();
if ($limits) {
	# Validate IPs limit, assuming new system will have exactly 1
	$incr = scalar(split(/\s+/, $server->{'ip_addresses'})) || 1;
	if ($limits->{'max_ips'}) {
		if ($limits->{'ips'} + $incr > $limits->{'max_ips'}) {
			&error(&text('create_epulimit',
			       $limits->{'max_ips'},
			       $limits->{'ips'}));
			}
		}
	}

# SSH login (if there is one)
$err = &parse_ssh_login_form(\%in, $server);
&error($err) if ($err);

# Webmin login
$err = &parse_webmin_login_form(\%in, $server);
&error($err) if ($err);
$server->{'novirt'} = !$in{'canvirt'};

# Check for IP and port clash
foreach $clash (@servers) {
	foreach $ip (split(/\s+/, $clash->{'ip_addresses'})) {
		$ip eq $server->{'ip'} &&
		  $clash->{'ssl_port'} == $server->{'ssh_port'} &&
		    &error(&text('add_eipclash', $clash->{'host'}, $ip));
		}
	}

# Parse type-specific inputs
$pfunc = "type_".$in{'type'}."_add_parse";
if (defined(&$pfunc)) {
	&$pfunc($server, \%in);
	}

&ui_print_unbuffered_header(undef, $text{'add_title'}, "");
&obtain_lock_server($server);

if (!$no_ssh && !$server->{'ssh_nologin'}) {
	# Make sure the SSH login is valid
	print $text{'add_sshing'},"<br>\n";
	&clear_ssh_host_key($server);
	($status, $msg) = &check_server_ssh_login($server);
	if ($status) {
		print "<b>",&text('add_essh',
			  &nice_error_status($status), $msg),"</b><p>\n";
		goto END;
		}
	else {
		print $text{'add_sshok'},"<p>\n";
		}
	}

# And the Webmin login
if ($server->{'user'}) {
	print $text{'add_webmining'},"<br>\n";
	($status, $msg, $os, $realos) = &check_server_webmin_login($server);
	if ($status) {
		print "<b>",&text('add_ewebmin',
				&nice_error_status($status), $msg),"</b><p>\n";
		goto END;
		}
	else {
		print $text{'add_webminok'},"<p>\n";
		}
	$server->{'type'} = &os_to_server_type($os, $realos);
	}
else {
	$server->{'type'} ||= 'unknown';
	}

# If this is a system owner, add it to his list
if ($access{'owner'}) {
	$access{'servers'} = join(' ', split(/\s+/, $access{'servers'}),
				       $server->{'id'});
	&save_module_acl(\%access);
	}

# Get status one more time, and save the server object
print $text{'add_statusing'},"<br>\n";
&complete_managed_server($server);
&save_managed_server($server);
&check_server_status($server);
if ($server->{'type'} eq 'unknown' || !$server->{'type'}) {
	my $guess = &guess_os_type($server);
	if ($guess) {
		$server->{'type'} = $guess;
		&check_server_status($server, 0, 1);
		}
	}
&save_managed_server($server);
print &text('add_statusok', &describe_status($server, 1)),"<p>\n";

# Enable Webmin status collection
if ($server->{'status'} eq 'novirt') {
	print $text{'add_collecting'},"<br>\n";
	$err = &enable_webmin_status_collection($server);
	if ($err) {
		print &text('add_ecollect', $err),"<p>\n";
		}
	else {
		print $text{'create_done'},"<p>\n";
		}
	}

# If the server has Virtualmin, do a config check
if ($server->{'status'} eq 'virt') {
	print $text{'add_vchecking'},"<br>\n";
	&check_virtualmin_config($server);
	if ($server->{'virtualmin_checked'}) {
		print $text{'add_vcheckok'},"<p>\n";
		}
	else {
		print &text('add_vcheckerr',
			    $server->{'virtualmin_checked'}),"<p>\n";
		}
	&save_managed_server($server);
	}

if (defined(&theme_select_server)) {
	&theme_select_server($server);
	}

END:
&release_lock_server($server);
&webmin_log("add", "server", $server->{'host'},
	    { 'type' => $server->{'manager'} });

&ui_print_footer("", $text{'index_return'});


