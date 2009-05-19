#!/usr/local/bin/perl
# Actually change a system's password

require './server-manager-lib.pl';
&ReadParse();
&error_setup($text{'pass_err'});
($server) = grep { $_->{'id'} == $in{'id'} } &list_managed_servers();
$server || &error($text{'edit_egone'});
&can_action_error($server, "pass");

# Validate inputs
$in{'ssh_pass_def'} || $in{'ssh_pass'} =~ /\S/ ||
	&error($text{'pass_essh_pass'});
!defined($in{'webmin_pass_def'}) || $in{'webmin_pass_def'} != 0 ||
   $in{'webmin_pass'} =~ /\S/ || 
	&error($text{'pass_ewebmin_pass'});
if ($in{'webmin_pass_def'} == 2 &&
    !$server->{'ssh_pass'} && $in{'ssh_pass_def'}) {
	&error($text{'pass_enosame'});
	}

# Actually make the changes
&ui_print_unbuffered_header(&server_in($server), $text{'pass_title'}, "");
&obtain_lock_server($server);

# Change SSH password, by updating /etc/shadow
if (!$in{'ssh_pass_def'}) {
	$done++;
	&$first_print($text{'pass_sshing'});
	$err = &set_shadow_root_password($server, $in{'ssh_pass'});
	if ($err) {
		&$second_print(&text('pass_essh', $err));
		goto DONE;
		}
	else {
		&$second_print($text{'create_done'});
		$server->{'ssh_pass'} = $in{'ssh_pass'};
		if ($server->{'ssh_pass_same'}) {
			$server->{'pass'} = $in{'ssh_pass'};
			}
		delete($server->{'key'});
		&save_managed_server($server);
		}
	}

# Change Webmin password, or force to sync with Unix
if (defined($in{'webmin_pass_def'}) && $in{'webmin_pass_def'} == 0) {
	# Set specific password
	&$first_print($text{'pass_webmining'});
	($sshstatus, $ssherr, $wroot, $wport, $wssl) =
		&check_server_ssh_login($server);
	$err = &set_server_webmin_password($server, $wroot,
					   'root', $in{'webmin_pass'});
	if ($err) {
		&$second_print(&text('pass_ewebmin', $err));
		goto DONE;
		}
	else {
		&$second_print($text{'create_done'});
		$server->{'pass'} = $in{'webmin_pass'};
		$server->{'ssh_pass_same'} = 0;
		}
	$done++;
	}
elsif ($in{'webmin_pass_def'} == 2) {
	# Same as Unix
	$done++;
	&$first_print($text{'pass_sameing'});
	$err = &set_server_webmin_password_crypt($server, 'root', 'x');
	if ($err) {
		&$second_print(&text('pass_esame', $err));
		goto DONE;
		}
	else {
		&$second_print($text{'create_done'});
		$server->{'pass'} = $server->{'ssh_pass'};
		$server->{'ssh_pass_same'} = 1;
		}
	}

if ($done) {
	# Refresh status
	&$first_print($text{'pass_refreshing'});
	&check_server_status($server, 0, 1);
	&save_managed_server($server);
	&$second_print($text{'create_done'});

	if (defined(&theme_post_save_server)) {
		&theme_post_save_server($server);
		}
	}
else {
	print "<b>$text{'pass_none'}</b><p>\n";
	}

DONE:
&release_lock_server($server);
&ui_print_footer("edit_serv.cgi?id=$in{'id'}", $text{'edit_return'});

