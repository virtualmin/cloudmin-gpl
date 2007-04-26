#!/usr/local/bin/perl
# Create a new virtual system of some type

require './server-manager-lib.pl';
&ReadParse();
&error_setup($text{'create_err'});
@servers = &list_managed_servers();
$server = { 'manager' => $in{'type'} };

# Validate inputs, starting with hostname
if (defined($in{'host'})) {
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
$server->{'ssl'} = 1;			# XXX test later
$server->{'port'} = 10000;		# Assume default
$server->{'novirt'} = !$in{'canvirt'};

# Parse type-specific inputs
$pfunc = "type_".$in{'type'}."_create_parse";
if (defined(&$pfunc)) {
	&$pfunc($server, \%in);
	}

&ui_print_unbuffered_header(undef, $text{'create_title'}, "");

# Call the server type's creation function, then wait for it to be come ready
$tfunc = "type_".$in{'type'}."_desc";
print &text('create_creating', &$tfunc()),"<br>\n";
$cfunc = "type_".$in{'type'}."_create";
$err = &$cfunc($server);
if ($err) {
	print &text('create_ecreate', $err),"<p>\n";
	goto END;
	}
$dfunc = "type_".$in{'type'}."_create_done";
if (defined(&$dfunc)) {
	print $text{'create_created'},"<p>\n";
	print $text{'create_waiting'};
	while(1) {
		$err = &$dfunc($server);
		if ($err eq "OK") {
			print "<br>\n";
			last;
			}
		elsif ($err) {
			print &text('create_ewait', $err),"<p>\n";
			goto END;
			}
		else {
			print ".";
			}
		sleep(1);
		}
	print $text{'create_waited'},"<p>\n";
	}
else {
	print $text{'create_created2'},"<p>\n";
	}

# Wait at most 60 seconds for SSH to come up (indicating that booting is done)
print $text{'create_sshing'};
$sshcount = 0;
while(1) {
	($sshstatus, $ssherr) = &check_server_ssh_login($server);
	if ($sshstatus == 0) {
		print "<br>\n";
		print $text{'create_sshdone'},"<p>\n";
		last;
		}
	elsif ($sshcount > 60) {
		print "<br>\n";
		print &text('create_sshfailed', 60, $ssherr),"<p>\n";
		last;
		}
	else {
		print ".";
		}
	$sshcount++;
	sleep(1);
	}

# Verify that we can connect via SSH
# XXX this may need to wait a while for SSH to come up
# XXX
# XXX set root password, if requested (not for EC2)

# Check if the server has Webmin.
# XXX

# If it has, then cool .. set the password and update the server object
# XXX

# If not, install if requested
# XXX

# Re-check and save the status
print $text{'add_statusing'},"<br>\n";
&save_managed_server($server);
&check_server_status($server);
&save_managed_server($server);
print $text{'add_statusok'},"<p>\n";

END:
&ui_print_footer("", $text{'index_return'});


