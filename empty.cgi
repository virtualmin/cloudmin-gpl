#!/usr/local/bin/perl
# Create a new virtual system of some type, initially empty and with a
# CD attached

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
$efunc = "type_".$in{'type'}."_can_create_empty";
$empty = &$efunc();

# Validate inputs, starting with hostname
if (defined($in{'host'})) {
	$in{'host'} =~ /^[a-z0-9\.\-]+$/ || &error($text{'create_ehost'});
	($clash) = grep { $_->{'host'} eq $in{'host'} } @servers;
	$clash && &error($text{'add_eclash'});
	$server->{'host'} = $in{'host'};
	}
$server->{'desc'} = $in{'desc'};

# Disable logins
$server->{'ssh_user'} = 'root';
$server->{'ssh_nologin'} = 1;
$server->{'ssh_protocol'} = 2;
$server->{'no_webmin_login'} = 1;
$server->{'port'} = 10000;
$server->{'type'} = 'unknown';

# Validate CD image
if ($empty != 2) {
	if ($in{'cdmode'} == 0) {
		# Cloudmin image
		$in{'image'} || &error($text{'create_eimage'});
		$img = &get_server_image($in{'image'});
		$img || &error($text{'create_eimagewrong'});
		&can_image($img) || &error($text{'create_eimagecannot'});
		$img->{'format'} eq 'cd' || &error($text{'create_eimagecd'});
		$server->{'image'} = $in{'image'};
		$server->{'type'} = $img->{'type'};
		}
	else {
		# Regular file
		&can_action_error(undef, "global");
		$in{'file'} =~ /^\/\S+$/ || &error($text{'create_eimagefile'});
		$server->{'imagefile'} = $in{'file'};
		}
	}

# Parse type-specific inputs
$pfunc = "type_".$in{'type'}."_create_parse";
if (defined(&$pfunc)) {
	&$pfunc($server, \%in, 1);
	}

# Check for hostname clash again, as the parse may have changed it
if ($server->{'host'}) {
	($clash) = grep { $_->{'host'} eq $server->{'host'} } @servers;
	$clash && &error($text{'add_eclash'});
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

&ui_print_unbuffered_header(undef, $text{'create_title'}, "");
&obtain_lock_server($server);

# Run pre-creation script
if (!&run_system_script($server, 'before', 'create')) {
	goto END;
	}

# If using a CD image, copy it to the server
if ($img) {
	$vhost = &get_parent_server($server);
	print &text('create_copyingcd', &nice_size($img->{'size'}),
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
$err = &$cfunc($server, undef, undef, 0, 1);
if ($err) {
	print &text('create_ecreate', $err),"<p>\n";
	goto END;
	}
$dfunc = "type_".$in{'type'}."_create_done";
if (defined(&$dfunc)) {
	print $text{'create_created'},"<p>\n";
	print $text{'create_waiting'};
	while(1) {
		$err = &$dfunc($server, 1);
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

if ($access{'owner'}) {
	# Adding to this user
	$owner = &get_system_owner($base_remote_user);
	}
elsif ($in{'owner'}) {
	# Add to another owner
	$owner = &get_system_owner($in{'owner'});
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
	&$dfunc($server, undef, undef, 0, 1);
	}

# Call any really final post-creation function
$dfunc = "type_".$in{'type'}."_create_ready";
if (defined(&$dfunc)) {
	&$dfunc($server, undef, undef, 0, 1);
	}

# Re-check and save the status
print $text{'add_statusing'},"<br>\n";
&save_managed_server($server);
&check_server_status($server, 1);
&save_managed_server($server);
print &text('add_statusok', &describe_status($server, 1)),"<p>\n";

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
&release_lock_server($server);
&webmin_log("empty", "server", $server->{'host'},
	    { 'type' => $server->{'manager'} });

&ui_print_footer("", $text{'index_return'});


