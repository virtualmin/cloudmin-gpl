#!/usr/local/bin/perl
# Add some existing server

require './server-manager-lib.pl';
&ReadParse();
&error_setup($text{'add_err'});
@servers = &list_managed_servers();
$server = { 'manager' => $in{'type'} };

# Validate inputs, starting with hostname
gethostbyname($in{'host'}) || &error($text{'add_ehost'});
($clash) = grep { $_->{'host'} eq $in{'host'} } @servers;
$clash && &error($text{'add_eclash'});
$server->{'host'} = $in{'host'};

# SSH login
$server->{'ssh_user'} = 'root';
if ($in{'auth_mode'} == 0) {
	$in{'upass'} || &error($text{'add_eupass'});
	$server->{'ssh_pass'} = $in{'upass'};
	}
elsif ($in{'auth_mode'} == 1) {
	$in{'key'} || &error($text{'add_ekey'});
	$server->{'key'} = $in{'key'};
	}

# Webmin login
if ($in{'webmin_mode'} == 1) {
	$in{'auth_mode'} == 0 || &error($text{'add_emode1'});
	$server->{'user'} = $server->{'ssh_user'};
	$server->{'pass'} = $server->{'ssh_pass'};
	$server->{'ssh_pass_same'} = 1;
	}
elsif ($in{'webmin_mode'} == 2) {
	$in{'wuser'} =~ /^\S+$/ || &error($text{'add_ewuser'});
	$server->{'user'} = $in{'wuser'};
	$in{'wpass'} =~ /\S/ || &error($text{'add_ewpass'});
	$server->{'pass'} = $in{'wpass'};
	}

# Parse type-specific inputs
$pfunc = "type_".$in{'type'}."_add_parse";
if (defined(&$pfunc)) {
	&$pfunc($server, \%in);
	}

# Make sure the SSH login is valid
($status, $msg) = &check_system_ssh_login($server);
$status && &error(&text('add_essh', $msg));

# And the Webmin login
if ($server->{'user'}) {
	($status, $msg, $os, $realos) = &check_system_webmin_login($server);
	$status && &error(&text('add_ewebmin', $msg));
	$server->{'type'} = &os_to_server_type($os, $realos);
	}

# Save the server object
&save_managed_server($server);
&redirect("");

