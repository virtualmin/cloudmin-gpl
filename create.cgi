#!/usr/local/bin/perl
# Create a new virtual system of some type

require './server-manager-lib.pl';
&ReadParse();
&error_setup($text{'create_err'});
&can_create_server_error($in{'type'});
$server = { 'id' => &server_id(),
	    'manager' => $in{'type'},
	    'status' => 'create',
	    'bw_limit' => $config{'bw_def'},
	    'created' => time(),
	    'directory' => $in{'directory'},
	  };

# Prevent concurrent creation that would exceed limits
&obtain_lock_user(undef, 1);
@servers = &list_managed_servers();

# Validate inputs, starting with hostname
if (defined($in{'host'})) {
	$in{'host'} =~ /^[a-z0-9\.\-]+$/ || &error($text{'create_ehost'});
	($clash) = grep { $_->{'host'} eq $in{'host'} } @servers;
	$clash && &error($text{'add_eclash'});
	$server->{'host'} = $in{'host'};
	}
if (defined($in{'unixhost'}) && !$in{'unixhost_def'}) {
	$in{'unixhost'} =~ /^[a-z0-9\.\-]+$/ ||
		&error($text{'create_eunixhost'});
	$server->{'unix_hostname'} = $in{'unixhost'};
	}
$server->{'desc'} = $in{'desc'};
if (&can_action($server, "groups")) {
	&parse_groups_form($server, \%in);
	}

# SSH login
$sfunc = "type_".$in{'type'}."_no_ssh";
$no_ssh = defined(&$sfunc) && &$sfunc();
if (!$no_ssh) {
	$server->{'ssh_user'} = 'root';
	if ($in{'auth_mode'} == 0) {
		# Via password
		$in{'upass'} || &error($text{'add_eupass'});
		$server->{'ssh_pass'} = $in{'upass'};
		}
	elsif ($in{'auth_mode'} == 1) {
		# Via key
		$in{'key'} || &error($text{'add_ekey'});
		$server->{'key'} = $in{'key'};
		}
	elsif ($in{'auth_mode'} == 2) {
		# No SSH login needed
		$server->{'ssh_nologin'} = 1;
		}
	$server->{'ssh_protocol'} = 2;	# Nobody uses 1 anymore!
	$server->{'ssh_port'} = $config{'ssh_port'};
	}

# Assume webmin login is same as root
$server->{'user'} = $server->{'ssh_user'};
$server->{'pass'} = $server->{'ssh_pass'};
$server->{'ssh_pass_same'} = 1;
$server->{'port'} = 10000;
$server->{'novirt'} = !$in{'canvirt'};

$server->{'type'} = 'unknown';
$ifunc = "type_".$in{'type'}."_must_image";
if (defined(&$ifunc) && &$ifunc($server) && !$in{'image'}) {
	&error($text{'create_eimage'});
	}
$server->{'image'} = $in{'image'};
if ($in{'image'}) {
	$img = &get_server_image($in{'image'});
	$img || &error($text{'create_eimagewrong'});
	&can_image($img) || &error($text{'create_eimagecannot'});
	if ($img->{'type'}) {
		$server->{'type'} = $img->{'type'};
		}
	}

# Validate owner
&foreign_require("acl", "acl-lib.pl");
if ($in{'omode'} == 2) {
	$in{'newowner'} =~ /^[a-z0-9\.\-\_\@]+$/i ||
                &error($text{'owner_ename'});
	($clash) = grep { $_->{'name'} eq $in{'newowner'} } &acl::list_users();
	$clash && &error($text{'owner_eclash'});
	$in{'newownerpass'} =~ /\S/ || &error($text{'owner_epass'});
	$in{'newownerpass'} =~ /:/ && &error($text{'owner_epass'});
	}

# Validate plan
if ($in{'omode'} == 2 && &supports_plans()) {
	$in{'newownerplan'} || &error($text{'create_eplan'});
	$plan = &get_plan($in{'newownerplan'});
	$plan || &error($text{'create_eplan2'});
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

# Validate owner resource limits
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
			&error(&text('create_eipslimit',
			       $limits->{'max_ips'},
			       $limits->{'ips'}));
			}
		}
	}

# Save bandwidth limit
if (defined($in{'bw_def'}) && $config{'bw_enabled'} &&
    &can_action($server, "bw")) {
	if (!$in{'bw_def'}) {
		$in{'bw'} =~ /^[1-9]\d*$/ || &error($text{'limits_ebw'});
		$server->{'bw_limit'} = $in{'bw'}*$in{'bw_units'};
		}
	}

# Validate disk image directory
if ($server->{'directory'}) {
	$err = &validate_directory($server);
	$err && &usage(&text('create_edirectory', $err));
	}

&ui_print_unbuffered_header(&server_in($server), $text{'create_title'}, "");

# Run pre-creation script
if (!&run_system_script($server, 'before', 'create')) {
	goto END;
	}

&obtain_lock_server($server);

if ($serial) {
	# Mark this key as in-use
	&start_installing_virtualmin_licence($serial, $key);
	}

# If there is an image file, copy to the server
$vhost = &get_parent_server($server);
if ($in{'image'}) {
	$copyserver = &get_transfer_image_dest($server);
	print &text('create_copying', &nice_size($img->{'size'}),
				      $copyserver->{'host'});
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
	$dot_count = 0;
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
			print "\n" if (++$dot_count % 80 == 0);
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

if ($access{'owner'}) {
	# Adding to this user
	$owner = &get_system_owner($base_remote_user);
	}
elsif ($in{'omode'} == 1) {
	# Add to another owner
	$owner = &get_system_owner($in{'owner'});
	}
elsif ($in{'omode'} == 2) {
	# Create an owner for the system
	$owner = { 'name' => $in{'newowner'},
		   'pass' => &acl::encrypt_password($in{'newownerpass'}),
		   'real' => 'Owner of '.$server->{'host'},
		   'acl' => { 'email' => 'root@'.$server->{'host'},
			      'actions' => join(" ", @actions),
			      'plainpass' => $in{'newownerpass'}, },
		 };
	if ($in{'newownerplan'}) {
		$plan = &get_plan($in{'newownerplan'});
		if ($plan) {
			$owner->{'acl'}->{'actions_def'} = 1;
			&apply_plan_to_owner($plan, $owner);
			$owner->{'acl'}->{'plan'} = $in{'newownerplan'};
			}
		}
	&save_system_owner($owner);
	}
if ($owner) {
	&grant_to_system_owner($owner, $server);
	}

# Remove old SSH keys for this system
&clear_ssh_host_key($server);
if ($vhost) {
	&clear_remote_ssh_host_key($server, $vhost);
	}

# Call any post-creation function
$dfunc = "type_".$in{'type'}."_create_post";
if (defined(&$dfunc)) {
	&$dfunc($server, $serial, $key);
	}

if (!$no_ssh && !$server->{'ssh_nologin'}) {
	# Wait at most 120 seconds for SSH to come up (indicating that booting
	# is done), if need be
	$bfunc = "type_".$in{'type'}."_needs_boot";
	if (defined(&$bfunc) && &$bfunc($server)) {
		# Check in a loop until SSH is available
		print $text{'create_sshing'};
		$sshstart = time();
		$dot_count = 0;
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
			elsif (time() - $sshstart > 120) {
				print "<br>\n";
				print &text('create_sshfailed', 120, $ssherr),"<p>\n";
				last;
				}
			else {
				print ".";
				print "\n" if (++$dot_count % 80 == 0);
				}
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
	if (!$server->{'pass'}) {
		$server->{'pass'} = &generate_random_password();
		$server->{'ssh_pass_same'} = 0;
		}
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
else {
	# No webmin, so clear user and pass fields
	delete($server->{'user'});
	delete($server->{'pass'});
	}

# If we have Webmin, try to open its firewall port
if ($webmindir) {
	&open_webmin_firewall_port_and_print(
		$server, $server->{'port'}, $webmindir);
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
if (!$server->{'type'} || $server->{'type'} eq 'unknown') {
	$server->{'type'} = &guess_os_type($server);
	if ($server->{'type'}) {
		&check_server_status($server);
		}
	}
&save_managed_server($server);
print &text('add_statusok', &describe_status($server, 1)),"<p>\n";

if ($vhost) {
	# Re-check and save the host status
	print &text('add_statusing2', $vhost->{'host'}),"<br>\n";
	&obtain_lock_server($vhost);
	&check_server_status($vhost);
	&save_managed_server($vhost);
	&release_lock_server($vhost);
	print &text('add_statusok', &describe_status($vhost, 1)),"<p>\n";
	}

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

# If the system has Virtualmin, update any domains on the old default IP
if ($server->{'status'} eq 'virt') {
	@doms = &get_server_domains($server);
	if (@doms) {
		&$first_print($text{'create_domips'});
		$err = &update_virtualmin_ips($server);
		if ($err) {
			&$second_print(&text('create_domipsfailed', $err));
			}
		else {
			&$second_print($text{'create_done'});
			}
		}
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

&release_lock_user();

&ui_print_footer("", $text{'index_return'});


