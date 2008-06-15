#!/usr/local/bin/perl
# Create a new virtual system of some type

require './server-manager-lib.pl';
&ReadParse();
&error_setup($text{'create_err'});
&can_create_server_error($in{'type'});
@servers = &list_managed_servers();
$server = { 'id' => time().$$,
	    'manager' => $in{'type'},
	    'status' => 'create',
	    'bw_limit' => $config{'bw_def'},
	    'created' => time(),
	  };

# Validate inputs, starting with hostname
if (defined($in{'host'})) {
	$in{'host'} =~ /^[a-z0-9\.\-\_]+$/ || &error($text{'create_ehost'});
	($clash) = grep { $_->{'host'} eq $in{'host'} } @servers;
	$clash && &error($text{'add_eclash'});
	$server->{'host'} = $in{'host'};
	}
$server->{'desc'} = $in{'desc'};

# SSH login
$sfunc = "type_".$in{'type'}."_no_ssh";
$no_ssh = defined(&$sfunc) && &$sfunc();
if (!$no_ssh) {
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
	}

# Webmin login
if ($in{'webmin_mode'} == 1) {
	# Same as SSH root
	$in{'auth_mode'} == 0 || &error($text{'add_emode1'});
	$server->{'user'} = $server->{'ssh_user'};
	$server->{'pass'} = $server->{'ssh_pass'};
	$server->{'ssh_pass_same'} = 1;
	}
elsif ($in{'webmin_mode'} == 2) {
	# Password specified for Webmin root
	$server->{'user'} = 'root';
	$in{'wpass'} =~ /\S/ || &error($text{'add_ewpass'});
	$server->{'pass'} = $in{'wpass'};
	}
if ($in{'webmin_mode'}) {
	$server->{'port'} = 10000;
	}
$server->{'novirt'} = !$in{'canvirt'};
$server->{'type'} = 'unknown';
$ifunc = "type_".$in{'type'}."_must_image";
if (defined(&$ifunc) && &$ifunc($server) && !$in{'image'}) {
	&error($text{'create_eimage'});
	}
$server->{'image'} = $in{'image'};
if ($in{'image'}) {
	$img = &get_server_image($in{'image'});
	}

# Parse type-specific inputs
$pfunc = "type_".$in{'type'}."_create_parse";
if (defined(&$pfunc)) {
	&$pfunc($server, \%in);
	}

# Check for hostname clash again, as the parse may have changed it
if ($server->{'host'}) {
	($clash) = grep { $_->{'host'} eq $server->{'host'} } @servers;
	$clash && &error($text{'add_eclash'});
	}

# Validate licence
($serial, $key) = &virtualmin_licence_parse("licence", \%in);
if (!$serial && $key) {
	&error($key);
	}
elsif (!$serial && !$key) {
	# None given .. but does the image need one?
	if ($in{'image'}) {
		$img->{'virtualmin'} eq 'pro' &&
			&error($text{'create_eimagevirt'});
		}
	$vfunc = "type_".$in{'type'}."_will_virtualmin";
	if (defined(&$vfunc) && &$vfunc($server)) {
		&error($text{'create_eimagevirt'});
		}
	}
&ui_print_unbuffered_header(undef, $text{'create_title'}, "");

# Run pre-creation script
if (!&run_system_script($server, 'before', 'create')) {
	goto END;
	}

if ($serial) {
	# Mark this key as in-use
	&start_installing_virtualmin_licence($serial, $key);
	}

# If there is an image file, copy to the server
if ($in{'image'}) {
	print &text('create_copying', &nice_size($img->{'size'}));
	($imageok, $imagetemp) = &transfer_image_files($server, 1);
	print "<br>\n";
	if ($imageok == 0) {
		print &text('create_ecopy', $imagetemp),"<p>\n";
		goto END;
		}
	elsif ($imageok == 2) {
		$server->{'imagetemp'} = $imagetemp;
		$server->{'imagelocal'} = 1;
		print $text{'create_nocopy'},"<p>\n";
		}
	else {
		$server->{'imagetemp'} = $imagetemp;
		$server->{'imagelocal'} = 0;
		print $text{'create_done'},"<p>\n";
		}
	}

# Call the server type's creation function, then wait for it to be come ready
$tfunc = "type_".$in{'type'}."_desc";
print &text('create_creating', &$tfunc()),"<br>\n";
$cfunc = "type_".$in{'type'}."_create";
$err = &$cfunc($server, $serial, $key);
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
			if ($imageok == 1) {
				&cleanup_image_files($server, $imagetemp);
				}
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
if ($imageok == 1) {
	&cleanup_image_files($server, $imagetemp);
	}
&save_managed_server($server);

# Remove old SSH keys for this system
&remove_server_ssh_keys($server);

# Call any post-creation function
$dfunc = "type_".$in{'type'}."_create_post";
if (defined(&$dfunc)) {
	&$dfunc($server, $serial, $key);
	}

if (!$no_ssh) {
	# Wait at most 120 seconds for SSH to come up (indicating that booting
	# is done), if need be
	$bfunc = "type_".$in{'type'}."_needs_boot";
	if (defined(&$bfunc) && &$bfunc($server)) {
		# Check in a loop until SSH is available
		print $text{'create_sshing'};
		$sshcount = 0;
		while(1) {
			($sshstatus, $ssherr, $webmindir, $webminport,
			 $webminssl) = &check_server_ssh_login($server);
			if ($sshstatus == 0) {
				print "<br>\n";
				if ($webmindir) {
					print &text('create_sshdone2',
						    "<tt>$webmindir</tt>");
					}
				else {
					print $text{'create_sshdone'};
					}
				print "<p>\n";
				last;
				}
			elsif ($sshcount > 120) {
				print "<br>\n";
				print &text('create_sshfailed', 120, $ssherr),"<p>\n";
				last;
				}
			else {
				print ".";
				}
			$sshcount++;
			sleep(1);
			}
		}
	}
if (!$webmindir) {
	# Just check once to get Webmin root, if any
	($sshstatus, $ssherr, $webmindir, $webminport, $webminssl) =
		&check_server_ssh_login($server);
	}

# Check if the server has Webmin (it may have been part of the install image)
if ($webmindir) {
	# Yes, it was setup as part of the server creation .. go with its
	# port and SSL settings
	$server->{'port'} = $webminport;
	$server->{'ssl'} = $webminssl;

	# Forcibly set the password
	$server->{'user'} ||= 'root';
	$server->{'pass'} ||= $server->{'ssh_pass'};
	$server->{'pass'} ||= &generate_random_password();
	print $text{'create_passing'},"<br>\n";
	$perr = &set_server_webmin_password($server, $webmindir, "root",
					    $server->{'pass'});
	if ($perr) {
		print &text('create_passfailed', $perr),"<p>\n";
		}
	else {
		print $text{'create_passdone'},"<p>\n";
		}

	# Start Webmin in case it hasn't been
	&execute_command_on_server($server,
		"/etc/webmin/start >/dev/null 2>&1 </dev/null &");
	}
elsif ($in{'webmin_mode'}) {
	# Need to install Webmin
	local ($src, $type, $err) = &get_install_webmin_source($server);
	if (!$err) {
		print &text('create_webmining', $src),"<br>\n";
		($out, $err, $webmindir) =
			&install_webmin_server($server, $src, $type, 1);
		if ($err) {
			print "<pre>$out</pre>";
			$server->{'user'} = undef;	# No webmin
			$server->{'pass'} = undef;
			print &text('save_webminfailed', $err),"<p>\n";
			}
		else {
			print $text{'save_webmindone'},"<p>\n";
			}
		}
	}

# If we do have Webmin, wait for it to start
if ($webmindir) {
	print $text{'create_webminstarting'},"<br>\n";
	$err = &wait_webmin_server($server, 60);
	if (!$err) {
		print $text{'create_webminstarted'},"<p>\n";
		}
	else {
		print &text('create_webminnostart', 60, $err),"<p>\n";
		}
	}

# Call any really final post-creation function
$dfunc = "type_".$in{'type'}."_create_ready";
if (defined(&$dfunc)) {
	&$dfunc($server, $serial, $key);
	}

# Re-check and save the status
print $text{'add_statusing'},"<br>\n";
&save_managed_server($server);
&check_server_status($server, 1);
&save_managed_server($server);
print &text('add_statusok', &describe_status($server, 1)),"<p>\n";

if ($serial) {
	# Key is no longer in progress
	&stop_installing_virtualmin_licence($serial, $key);
	}

# If the server has Virtualmin, update all Virtualmin packages
$info = &get_server_collected($server);
if ($server->{'status'} eq 'virt' && $in{'update'}) {
	&update_virtualmin_packages($server);
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
			    $server->{'virtualmin_error'}),"<p>\n";
		}
	&save_managed_server($server);
	}

# Enable at boot time, if possible
$bfunc = "type_".$in{'type'}."_set_atboot";
if (defined(&$bfunc)) {
	print $text{'create_atbooting'},"<br>\n";
	&$bfunc($server, 1);
	print $text{'create_done'},"<p>\n";
	}

# Create console user
$cfunc = "type_".$in{'type'}."_supports_console_login";
if (defined(&$cfunc)) {
	print $text{'create_consoleuser'},"<p>\n";
	$err = &create_console_user($server);
	if ($err) {
		print &text('create_ecreate', $err),"<p>\n";
		}
	else {
		print $text{'create_done'},"<p>\n";
		}
	}

# Run post-creation script
&run_system_script($server, 'after', 'create');

if (defined(&theme_select_server)) {
	&theme_select_server($server);
	}

END:

# Do this again, in case we goto'd to END
if ($serial) {
	&stop_installing_virtualmin_licence($serial, $key);
	}

&ui_print_footer("", $text{'index_return'});


