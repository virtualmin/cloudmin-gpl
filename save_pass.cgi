#!/usr/local/bin/perl
# Actually change a system's password

require './server-manager-lib.pl';
&ReadParse();
&error_setup($text{'pass_err'});
&error_if_cloudmin_replica();
$server = &get_managed_server($in{'id'});
$server || &error($text{'edit_egone'});
&can_action_error($server, "pass");

# Validate inputs
if ($in{'ssh_pass_def'} == 0) {
	$in{'ssh_pass'} =~ /\S/ || &error($text{'pass_essh_pass'});
	}
elsif ($in{'ssh_pass_def'} == 2) {
	&can_action_error(undef, "sshkeys");
	@keys = &list_ssh_keys();
	($key) = grep { $_->{'id'} eq $in{'ssh_key'} } @keys;
	$key || &error($text{'pass_essh_key'});
	}
!defined($in{'webmin_pass_def'}) || $in{'webmin_pass_def'} != 0 ||
   $in{'webmin_pass'} =~ /\S/ || 
	&error($text{'pass_ewebmin_pass'});
if ($in{'webmin_pass_def'} == 2 &&
    !$server->{'ssh_pass'} && $in{'ssh_pass_def'}) {
	&error($text{'pass_enosame'});
	}

# Set VNC password
$cfunc = "type_".$server->{'manager'}."_can_graphical_password";
$vcan = defined(&$cfunc) && &$cfunc($server);
if ($vcan && !$in{'vnc_def'}) {
	$in{'vnc_pass'} =~ /^\S+$/ || &error($text{'pass_evnc'});
	$sfunc = "type_".$server->{'manager'}."_set_graphical_password";
	$err = &$sfunc($server, $in{'vnc_pass'});
	&error($err) if ($err);
	$need_reboot = 1 if ($vcan == 2);
	$done++;
	}

# Actually make the changes
&ui_print_unbuffered_header(&server_in($server), $text{'pass_title'}, "");
&obtain_lock_server($server);

if ($in{'ssh_pass_def'} == 0) {
	# Change SSH password, by updating /etc/shadow
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
elsif ($in{'ssh_pass_def'} == 2) {
	# Use SSH key
	$done++;
	&$first_print($text{'pass_sshkeying'});
	$server->{'key'} = $key->{'id'};
	$err = &create_authorized_key($server, 1);
	if ($err) {
		&$second_print(&text('pass_ewebmin', $err));
		goto DONE;
                }
	else {
		&$second_print($text{'pass_sshkeydone'});
		$server->{'ssh_pass_same'} = 0;
		delete($server->{'ssh_pass'});
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

	if ($need_reboot && $server->{'status'} ne 'down') {
		# Tell user that a reboot is needed
		print &ui_form_start("save_serv.cgi");
		print &ui_hidden("id", $in{'id'});
		print &ui_hidden("reboot", 1);
		print &ui_hidden("confirm", 1);
		print &ui_hidden("updown", 1);
		print "<b>$text{'pass_needreboot'}</b><p>\n";
		print &ui_form_end([ [ undef, $text{'limits_reboot'} ] ]);
		}

	if (defined(&theme_post_save_server)) {
		&theme_post_save_server($server);
		}
	}
else {
	print "<b>$text{'pass_none'}</b><p>\n";
	}

DONE:
&release_lock_server($server);
&webmin_log("pass", "server", $server->{'host'});
&ui_print_footer("edit_serv.cgi?id=$in{'id'}", $text{'edit_return'});

