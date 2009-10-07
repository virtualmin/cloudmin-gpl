#!/usr/local/bin/perl
# Create a new virtual system of some type

require './server-manager-lib.pl';
&ReadParse();
&error_setup($text{'create_err'});
&can_create_server_error($in{'type'});
@servers = &list_managed_servers();
$server = { 'id' => &server_id(),
	    'manager' => $in{'type'},
	    'status' => 'create',
	    'bw_limit' => $config{'bw_def'},
	    'created' => time(),
	  };

# Validate inputs, starting with hostname
if (defined($in{'host'})) {
	$in{'host'} =~ /^[a-z0-9\.\-]+$/ || &error($text{'create_ehost'});
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
if (&can_action(undef, "webmin")) {
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
	if ($img->{'type'}) {
		$server->{'type'} = $img->{'type'};
		}
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
if (&can_action(undef, "virtualmin")) {
	($serial, $key) = &virtualmin_licence_parse("licence", \%in);
	}
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

# Validate resource limits
$limits = &get_owner_limits();
if ($limits) {
	# Validate disk limit
	$dsfunc = "type_".$in{'type'}."_get_disk_size";
	$incr = defined(&$dsfunc) ? &$dsfunc($server) : undef;
	if ($incr && $limits->{'max_disk'}) {
		# May be over disk limit
		if ($limits->{'disk'} + $incr > $limits->{'max_disk'}) {
			&error(&text('create_edisklimit',
			       &nice_size($limits->{'max_disk'}),
			       &nice_size($limits->{'disk'})));
			}
		}
	elsif (!$incr && $limits->{'max_disk'}) {
		# System has no disk limits, but owner does
		&error(&text('create_edisklimit2',
		       &nice_size($limits->{'max_disk'})));
		}

	# Validate RAM limit
	$mfunc = "type_".$in{'type'}."_get_memory_size";
	$incr = defined(&$mfunc) ? &$mfunc($server) : undef;
	if ($incr && $limits->{'max_ram'}) {
		# May be over RAM limit
		if ($limits->{'ram'} + $incr > $limits->{'max_ram'}) {
			&error(&text('create_eramlimit',
			       &nice_size($limits->{'max_ram'}),
			       &nice_size($limits->{'ram'})));
			}
		}
	elsif (!$incr && $limits->{'max_ram'}) {
		# System has no RAM limits, but owner does
		&error(&text('create_eramlimit2',
		       &nice_size($limits->{'max_ram'})));
		}

	# Validate CPU limit
	$cfunc = "type_".$in{'type'}."_get_cpu_size";
	$incr = defined(&$cfunc) ? &$cfunc($server) : undef;
	if ($incr && $limits->{'max_cpu'}) {
		# May be over CPU limit
		if ($limits->{'cpu'} + $incr > $limits->{'max_cpu'}) {
			&error(&text('create_ecpulimit',
			       $limits->{'max_cpu'},
			       $limits->{'cpu'}));
			}
		}
	elsif (!$incr && $limits->{'max_cpu'}) {
		# System has no CPU limit, but owner does
		&error(&text('create_ecpulimit2',
		       $limits->{'max_cpu'}));
		}

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

&ui_print_unbuffered_header(undef, $text{'create_title'}, "");
&obtain_lock_server($server);

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
	$vhost = &get_parent_server($server);
	print &text('create_copying', &nice_size($img->{'size'}),
				      $vhost->{'host'});
	($imageok, $imagetemp) = &transfer_image_files($server, 1);
	print "<br>\n";
	if ($imageok == 0) {
		# Copy failed
		print &text('create_ecopy', $imagetemp),"<p>\n";
		goto END;
		}
	else {
		$server->{'imagetemp'} = $imagetemp;
		$server->{'imagelocal'} = ($imageok != 1);
		print $imageok == 1 ? $text{'create_done'} :
		      $imageok == 2 ? $text{'create_nocopy'} :
		      $imageok == 3 ? $text{'create_incache'} :
				      $text{'create_addcache'};
		print "<p>\n";
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
&complete_managed_server($server);
&save_managed_server($server);

# If this is a system owner, add it to his list
if ($access{'owner'}) {
	$access{'servers'} = join(' ', split(/\s+/, $access{'servers'}),
				       $server->{'id'});
	&save_module_acl(\%access);
	}
elsif ($in{'owner'}) {
	# Add to another owner
	$owner = &get_system_owner($in{'owner'});
	if ($owner) {
		$owner->{'acl'}->{'servers'} =
			join(' ', split(/\s+/, $owner->{'acl'}->{'servers'}),
				  $server->{'id'});
		&save_system_owner($owner, $owner);
		}
	}

# Remove old SSH keys for this system
&remove_server_ssh_keys($server);

# Call any post-creation function
$dfunc = "type_".$in{'type'}."_create_post";
if (defined(&$dfunc)) {
	&$dfunc($server, $serial, $key);
	}

if (!$no_ssh && !$server->{'no_sshlogin'}) {
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
	my ($src, $type, $err) = &get_install_webmin_source($server);
	if (!$err) {
		print &text('create_webmining',
			    $src =~ /:/ ? "<tt>$src</tt>" : uc($src)),"<br>\n";
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
	print $text{'create_consoleuser'},"<br>\n";
	$err = &create_console_user($server);
	if ($err) {
		print &text('create_ecreate', $err),"<p>\n";
		}
	else {
		print $text{'create_done'},"<p>\n";
		}
	&save_managed_server($server);
	}

# Enable package management
if ($config{'packages_def'} && ($server->{'status'} eq 'virt' ||
			        $server->{'status'} eq 'novirt')) {
	print $text{'create_packages'},"<br>\n";
	$err = &save_server_cluster_software($server, 1);
	if ($err) {
		print &text('create_epackages', $err),"<p>\n";
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
&release_lock_server($server);
&webmin_log("create", "server", $server->{'host'},
	    { 'type' => $server->{'manager'} });

&ui_print_footer("", $text{'index_return'});


