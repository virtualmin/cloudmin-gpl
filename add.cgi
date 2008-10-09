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
gethostbyname($in{'host'}) || &error($text{'add_ehost'});
($clash) = grep { $_->{'host'} eq $in{'host'} } @servers;
$clash && &error($text{'add_eclash'});
$server->{'host'} = $in{'host'};
$server->{'desc'} = $in{'desc'};

# SSH login (if there is one)
$sfunc = "type_".$in{'type'}."_no_ssh";
$no_ssh = defined(&$sfunc) && &$sfunc();
if (!$no_ssh) {
	$in{'uuser'} =~ /^[a-z0-9\.\-\_]+$/i || &error($text{'add_euuser'});
	$server->{'ssh_user'} = $in{'uuser'};
	if (!$in{'uport_def'}) {
		$in{'uport'} =~ /^\d+$/ && $in{'uport'} > 0 &&
		    $in{'uport'} < 65536 || error($text{'add_euport'});
		$server->{'ssh_port'} = $in{'uport'};
		}
	if ($in{'auth_mode'} == 0) {
		# Via password
		$in{'upass'} || &error($text{'add_eupass'});
		$server->{'ssh_pass'} = $in{'upass'};
		}
	elsif ($in{'auth_mode'} == 1) {
		# Via SSH key
		$in{'key'} || &error($text{'add_ekey'});
		$server->{'key'} = $in{'key'};
		}
	elsif ($in{'auth_mode'} == 2) {
		# No SSH login should be tried
		$server->{'ssh_nologin'} = 1;
		}
	$server->{'ssh_protocol'} = $in{'protocol'};
	}

# Webmin login
$err = &parse_webmin_login_form(\%in, $server);
&error($err) if ($err);
$server->{'novirt'} = !$in{'canvirt'};

# Parse type-specific inputs
$pfunc = "type_".$in{'type'}."_add_parse";
if (defined(&$pfunc)) {
	&$pfunc($server, \%in);
	}

&ui_print_unbuffered_header(undef, $text{'add_title'}, "");

if (!$no_ssh && !$server->{'ssh_nologin'}) {
	# Make sure the SSH login is valid
	print $text{'add_sshing'},"<br>\n";
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

# Get status one more time, and save the server object
print $text{'add_statusing'},"<br>\n";
&save_managed_server($server);
&check_server_status($server);
&save_managed_server($server);
print &text('add_statusok', &describe_status($server, 1)),"<p>\n";

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

# Enable package management
if ($config{'packages_def'}) {
	print $text{'create_packages'},"<br>\n";
	$err = &save_server_cluster_software($server, 1);
	if ($err) {
		print &text('create_epackages', $err),"<p>\n";
		}
	else {
		print $text{'create_done'},"<p>\n";
		}
	}

if (defined(&theme_select_server)) {
	&theme_select_server($server);
	}

END:
&ui_print_footer("", $text{'index_return'});


