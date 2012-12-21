#!/usr/local/bin/perl
# Update resource limits for some system

require './server-manager-lib.pl';
&error_setup($text{'limits_err'});
&error_if_cloudmin_replica();

# Get the server
&ReadParse();
$server = &get_managed_server($in{'id'});
$server || &error($text{'edit_egone'});
&can_action_error($server, "limits");
$t = $server->{'manager'};
$limits = &get_owner_limits();
$vhost = &get_parent_server($server);

# Validate inputs
if (defined($in{'memory'})) {
	$in{'memory_def'} || $in{'memory'} =~ /^\d+$/ ||
		&error($text{'limits_ememory'});
	}
if (defined($in{'cpu'})) {
	$in{'cpu_def'} || $in{'cpu'} =~ /^\d+$/ && $in{'cpu'} > 0 ||
		&error($text{'limits_ecpu'});
	}
if (defined($in{'weight'})) {
	$in{'weight'} =~ /^\d+$/ && $in{'weight'} > 0 ||
		&error($text{'limits_eweight'});
	}
if (defined($in{'disk'})) {
	$in{'disk_def'} || $in{'disk'} =~ /^\d+$/ ||
		&error($text{'limits_edisk'});
	}
if (defined($in{'rate'})) {
	$in{'rate_def'} || $in{'rate'} =~ /^\d+$/ ||
		&error($text{'limits_erate'});
	}
if (defined($in{'bw'})) {
	$in{'bw_def'} || $in{'bw'} =~ /^[1-9]\d*$/ ||
		&error($text{'limits_ebw'});
	}
if (defined($in{'ioclass'})) {
	$ifunc = "type_".$t."_get_ioclass";
	$oldioclass = &$ifunc($server);
	$in{'ioclass'} =~ /^[0-7]$/ ||
		&error($text{'limits_eioclass'});
	$in{'ioclass'} >= $access{'ioclass'} ||
	    $in{'ioclass'} == $oldioclass ||
		&error(&text('create_ekvmioclassmax', $access{'ioclass'}));
	}

# Apply them, telling the user
&ui_print_unbuffered_header(&server_in($server), $text{'limits_title'}, "");
&obtain_lock_server($server);

# Make sure status is up to date
&check_server_status($server, 0, 1);

# Update memory
if (defined($in{'memory'}) || defined($in{'memory_def'})) {
	$m = $in{'memory_def'} ? 0 : $in{'memory'}*$in{'memory_units'};
	&$first_print(&text('limits_setting', $m ? &nice_size($m)
						 : $text{'edit_lunlimit'}));
	$gfunc = "type_".$t."_get_memory";
	$oldm = &$gfunc($server);
	if ($m == $oldm) {
		# No need to change
		&$second_print($text{'limits_already'});
		}
	else {
		# Check limits
		$incr = $m - $oldm;
		$memfree = &host_free_memory($vhost, $server->{'manager'});
		$checkmem = (($server->{'status'} ne 'down' &&
			     $server->{'status'} ne 'host') ||
			     $vhost->{'floor_mem_down'}) &&
			    !$vhost->{$server->{'manager'}.'_overmemory'};
		if ($limits && $limits->{'max_ram'} &&
		    $limits->{'ram'} + $incr > $limits->{'max_ram'}) {
			# Over RAM limit
			&$second_print(&text('limits_eramlimit',
				&nice_size($limits->{'max_ram'}),
				&nice_size($limits->{'ram'})));
			}
		elsif ($incr > $memfree && $incr > 0 && $checkmem) {
			# Over host limit
			&$second_print(&text('limits_ehostramlimit',
					&nice_size($incr),
					&nice_size($memfree)));
			}
		elsif ($limits && $limits->{'max_ram'} && !$m) {
			# Set to unlimited but not allowed
			&$second_print(&text('limits_eramlimit2',
				&nice_size($limits->{'max_ram'})));
			}
		else {
			# Call set function and check
			$mfunc = "type_".$t."_save_memory";
			$err = &$mfunc($server, $m);
			if ($err) {
				&$second_print(&text('limits_failed', $err));
				}
			else {
				&$second_print($text{'create_done'});
				$cfunc = "type_".$t."_can_memory";
				$reboot++ if (&$cfunc($server) == 2);
				}
			}
		}
	}

# Update guaranteed memory
if (defined($in{'gmemory'}) || defined($in{'gmemory_def'})) {
	$gm = $in{'gmemory_def'} ? $m :
		$in{'gmemory'}*$in{'gmemory_units'};
	&$first_print(&text('limits_settingg', $gm ? &nice_size($gm) :
						$text{'edit_lunlimit'}));
	$gfunc = "type_".$t."_get_guaranteed_memory";
	$rgfunc = "type_".$t."_get_memory";
	$oldm = &$gfunc($server);
	$rm = &$rgfunc($server);
	if ($gm == $oldm) {
		# No need to change
		&$second_print($text{'limits_already'});
		}
	else {
		# Check limits
		$incr = $gm - $oldm;
		$memfree = &host_free_memory($vhost, $server->{'manager'}, 1);
		$checkmem = ($server->{'status'} ne 'down' &&
			     $server->{'status'} ne 'host') ||
			    $vhost->{'floor_mem_down'};
		if (!$gm) {
			# Set to unlimited but not allowed
			&$second_print($text{'limits_eramlimit3'});
			}
		elsif ($rm && $gm > $rm) {
			# Cannot be more that regular memory limit
			&$second_print(&text('limits_eramlimit4',
					     &nice_size($rm)));
			}
		elsif ($incr > $memfree && $incr > 0 && $checkmem) {
			# Over host limit
			&$second_print(&text('limits_ehostgramlimit',
					&nice_size($incr),
					&nice_size($memfree)));
			}
		else {
			# Call set function and check
			$mfunc = "type_".$t."_save_guaranteed_memory";
			$err = &$mfunc($server, $gm);
			if ($err) {
				&$second_print(&text('limits_failed', $err));
				}
			else {
				&$second_print($text{'create_done'});
				$cfunc = "type_".$t."_can_guaranteed_memory";
				$reboot++ if (&$cfunc($server) == 2);
				}
			}
		}
	}

# Update CPU and weight
if (defined($in{'cpu'}) || defined($in{'weight'}) || defined($in{'cpu_def'})) {
	$cpudesc = $in{'cpu_def'} ? $text{'edit_lunlimit'} : $in{'cpu'}."%";
	if (defined($in{'weight'})) {
		&$first_print(&text('limits_settingcpu',
				    $cpudesc, $in{'weight'}));
		}
	else {
		&$first_print(&text('limits_settingcpu2', $cpudesc));
		}
	$gfunc = "type_".$t."_get_cpu";
	($oldc, $oldw) = &$gfunc($server);
	if ($oldc == ($in{'cpu_def'} ? 0 : $in{'cpu'}) &&
	    $oldw == $in{'weight'}) {
		# No need to change
		&$second_print($text{'limits_already'});
		}
	else {
		# Check CPU limit
		$c = !defined($in{'cpu_def'}) ? undef :
		     $in{'cpu_def'} ? 0 : $in{'cpu'};
	        $w = !defined($in{'weight'}) ? undef : $in{'weight'};
		$incr = $c - $oldc;
		if ($limits && $limits->{'max_cpu'} &&
		    $limits->{'cpu'} + $incr > $limits->{'max_cpu'} &&
		    defined($c)) {
			# Over CPU limit
			&$second_print(&text('limits_ecpulimit',
				$limits->{'max_cpu'}, $limits->{'cpu'}));
			}
		elsif ($limits && $limits->{'max_cpu'} && !$c &&
		       defined($c)) {
			# Set to unlimited but not allowed
			&$second_print(&text('limits_ecpulimit2',
				$limits->{'max_cpu'}));
			}
		else {
			# Call set function and check
			$cfunc = "type_".$t."_save_cpu";
			$err = &$cfunc($server, $c, $w);
			if ($err) {
				&$second_print(&text('limits_failed', $err));
				}
			else {
				&$second_print($text{'create_done'});
				$cfunc = "type_".$t."_can_cpu";
				$reboot++ if (&$cfunc($server) == 2 ||
					      &$cfunc($server) == 4);
				}
			}
		}
	}

# Update disk space
if (defined($in{'disk'}) || defined($in{'disk_def'})) {
	$d = $in{'disk_def'} ? 0 : $in{'disk'}*$in{'disk_units'};
	&$first_print(&text('limits_settingdisk', $d ? &nice_size($d)
						 : $text{'edit_lunlimit'}));
	$gfunc = "type_".$t."_get_disk";
	$oldd = &$gfunc($server);
	if ($d == $oldd) {
		# No need to change
		&$second_print($text{'limits_already'});
		}
	else {
		# Check limits
		$incr = $d - $oldd;
		$diskfree = &host_free_disk($vhost, $server->{'manager'},
					    $server);
		$checkdisk = !$vhost->{$server->{'manager'}.'_overdisk'};
		if ($limits && $limits->{'max_disk'} &&
		    $limits->{'disk'} + $incr > $limits->{'max_disk'}) {
			# Over disk limit
			&$second_print(&text('limits_edisklimit',
				&nice_size($limits->{'max_disk'}),
				&nice_size($limits->{'disk'})));
			}
		elsif ($limits && $limits->{'max_disk'} && !$d) {
			# Set to unlimited but not allowed
			&$second_print(&text('limits_edisklimit2',
				&nice_size($limits->{'max_disk'})));
			}
		elsif ($disk && $incr > 0 && $incr > $diskfree && $checkdisk) {
			# Over disk limit for host
			&$second_print(&text('limits_ediskhostlimit',
				       &nice_size($incr),
				       &nice_size($diskfree)));
			}
		else {
			# Call set function and check
			$dfunc = "type_".$t."_save_disk";
			$err = &$dfunc($server, $d);
			if ($err) {
				&$second_print(&text('limits_failed', $err));
				}
			else {
				&$second_print($text{'create_done'});
				$cfunc = "type_".$t."_can_disk";
				$reboot++ if (&$cfunc($server) == 2);
				}
			}
		}
	}

# Update IO class
if (defined($in{'ioclass'}) && &can_action($server, "ioclass")) {
	$c = $in{'ioclass'};
	&$first_print(&text('limits_settingioclass', $c));
	$gfunc = "type_".$t."_get_ioclass";
	$oldc = &$gfunc($server);
	if ($c == $oldc) {
		# No need to change
		&$second_print($text{'limits_already'});
		}
	else {
		# Call set function and check
		$ifunc = "type_".$t."_save_ioclass";
		$err = &$ifunc($server, $c);
		if ($err) {
			&$second_print(&text('limits_failed', $err));
			}
		else {
			&$second_print($text{'create_done'});
			$cfunc = "type_".$t."_can_ioclass";
			$reboot++ if (&$cfunc($server) == 2);
			}
		}
	}

# Bandwidth limit
if (defined($in{'bw'}) && &can_action($server, "bw")) {
	$bw = $in{'bw_def'} ? '' : $in{'bw'}*$in{'bw_units'};
	&$first_print(&text($in{'bw_def'} ? 'limits_settingbwu' :
				'limits_settingbw', &nice_size($bw)));
	if ($server->{'bw_limit'} != $bw) {
		$server->{'bw_limit'} = $bw;
		&$second_print($text{'create_done'});
		}
	else {
		# No need to change
		&$second_print($text{'limits_already'});
		}
	}

# Update network rate
if (defined($in{'rate'}) || defined($in{'rate_def'})) {
	$d = $in{'rate_def'} ? 0 : $in{'rate'}*$in{'rate_units'};
	&$first_print(&text('limits_settingrate', $d ? &nice_size($d)
						 : $text{'edit_lunlimit'}));
	$gfunc = "type_".$t."_get_network_rate";
	$oldd = &$gfunc($server);
	if ($d == $oldd) {
		# No need to change
		&$second_print($text{'limits_already'});
		}
	else {
		# Call set function and check
		$dfunc = "type_".$t."_save_network_rate";
		$err = &$dfunc($server, $d);
		if ($err) {
			&$second_print(&text('limits_failed', $err));
			}
		else {
			&$second_print($text{'create_done'});
			$cfunc = "type_".$t."_can_network_rate";
			$reboot++ if (&$cfunc($server) == 2);
			}
		}
	}

# Update allowed IPs
$cfunc = "type_".$t."_can_firewall";
if (defined(&$cfunc) && &$cfunc($server) && &can_action($server, "ifaces")) {
	&$first_print($in{'firewall_mode'} ? $text{'limits_settingfw1'}
					   : $text{'limits_settingfw2'});
	if ($in{'firewall_mode'} == 0) {
		@ips = ( );
		}
	elsif ($in{'firewall_mode'} == 1) {
		@ips = ( '*' );
		}
	else {
		@ips = split(/\s+/, $in{'firewall'});
		foreach $ip (@ips) {
			&check_ipaddress($ip) || &check_ip6address($ip) ||
				&error(&text('limits_efirewall', $ip));
			}
		}
	$sfunc = "type_".$t."_save_firewall";
	my $err = &$sfunc($server, \@ips);
	if ($err) {
		&$second_print(&text('limits_failed', $err));
		}
	else {
		&$second_print($text{'create_done'});
		}
	}

# Refresh status, in case it got changed
&$first_print($text{'save_refreshing'});
&check_server_status($server, 0, 1);
&save_managed_server($server);
&release_lock_server($server);
&$second_print(&text('save_refreshdone2',
		     &describe_status($server, 1, 1)));

if (defined(&theme_post_save_server)) {
	&theme_post_save_server($server);
	}

&webmin_log("limits", "server", $server->{'host'});

# Offer to reboot if needed
if ($reboot && $server->{'status'} ne 'down') {
	print &ui_form_start("save_serv.cgi");
	print &ui_hidden("id", $in{'id'});
	print &ui_hidden("reboot", 1);
	print &ui_hidden("confirm", 1);
	print &ui_hidden("updown", 1);
	print "<b>$text{'limits_needreboot'}</b><p>\n";
	print &ui_form_end([ [ undef, $text{'limits_reboot'} ] ]);
	}

&ui_print_footer("edit_serv.cgi?id=$in{'id'}", $text{'edit_return'},
		 "", $text{'index_return'});


