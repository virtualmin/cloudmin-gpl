#!/usr/local/bin/perl
# Create a new virtual system of some type

require './server-manager-lib.pl';
&ReadParse();
&error_setup($text{'add_err'});
@servers = &list_managed_servers();
$server = { 'manager' => $in{'type'} };

# Validate inputs, starting with hostname
if (!$in{'host_def'}) {
	$in{'host'} =~ /^[a-z0-9\.\-\_]+$/ || &error($text{'create_ehost'});
	($clash) = grep { $_->{'host'} eq $in{'host'} } @servers;
	$clash && &error($text{'add_eclash'});
	$server->{'host'} = $in{'host'};
	}
$server->{'desc'} = $in{'desc'};

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
$server->{'ssh_protocol'} = 2;	# Nobody uses 1 anymore!

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
$server->{'ssl'} = $in{'ssl'};		# XXX test later
$server->{'port'} = 10000;		# Assume default

# Parse type-specific inputs
$pfunc = "type_".$in{'type'}."_create_parse";
if (defined(&$pfunc)) {
	&$pfunc($server, \%in);
	}

&ui_print_header(undef, $text{'create_title'}, "");

# Call the server type's creation function. This may take some time..
# XXX

# Verify that we can connect via SSH
# XXX
# XXX set root password

# Check if the server has Webmin.
# XXX

# If it has, then cool .. set the password and update the server object
# XXX

# If not, install if requested
# XXX

# Re-check and save the status
# XXX

&ui_print_footer("", $text{'index_return'});


