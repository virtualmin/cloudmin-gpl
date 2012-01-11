#!/usr/local/bin/perl
# Actually create a new system image

require './server-manager-lib.pl';
&ReadParse();
&error_setup($text{'clone_err'});
$server = &get_managed_server($in{'id'});
$server || &error($text{'mkimage_egone'});
&can_create_server_error($server->{'manager'});

# Check if clonable
$dfunc = "type_".$server->{'manager'}."_desc";
$desc = &$dfunc();
$cfunc = "type_".$server->{'manager'}."_can_clone";
defined(&$cfunc) || &error(&text('clone_ecan', $desc));
&$cfunc($server) || &error($text{'clone_ecan2'});

# Validate inputs
$in{'host'} =~ /^[a-z0-9\.\-]+$/ || &error($text{'clone_ehost'});
if (!$in{'ips_def'} && &can_action($server, 'ips')) {
	if (defined($in{'ips'})) {
		$ips = [ split(/\s+/, $in{'ips'}) ];
		}
	else {
		$ips = [ ];
		for(my $i=0; defined($in{"ip_$i"}); $i++) {
			$in{"ip_$i"} =~ /\S/ ||
				&error(&text('clone_eiprow', $i+1));
			push(@$ips, $in{"ip_$i"});
			}
		}
	foreach $ip (@$ips) {
		&check_ipaddress($ip) ||
			&error(&text('clone_eipcheck', $ip));
		}
	}
if (!$in{'ips6_def'} && &can_action($server, 'ips')) {
	if (defined($in{'ips6'})) {
		$ips6 = [ split(/\s+/, $in{'ips6'}) ];
		}
	elsif (defined($in{'ip6_0'})) {
		$ips6 = [ ];
		for(my $i=0; defined($in{"ip6_$i"}); $i++) {
			$in{"ip6_$i"} =~ /\S/ ||
				&error(&text('clone_eip6row', $i+1));
			push(@$ips6, $in{"ip6_$i"});
			}
		}
	if ($ips6) {
		foreach $ip6 (@$ips6) {
			&check_ip6address($ip6) ||
				&error(&text('clone_eipcheck6', $ip6));
			}
		}
	}
if ($in{'dest'}) {
	$dest = &get_managed_server($in{'dest'});
	}

# Validate owner resource limits
$limits = &get_owner_limits();
if ($limits) {
	# Validate disk limit
	$dsfunc = "type_".$server->{'manager'}."_get_disk_size";
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
	$mfunc = "type_".$server->{'manager'}."_get_memory_size";
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
	$cfunc = "type_".$server->{'manager'}."_get_cpu_size";
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

&ui_print_unbuffered_header(&server_in($server), $text{'clone_title'}, "");
&obtain_lock_server($server);

&$first_print(&text('clone_doing', $desc, $server->{'host'}, $in{'host'}));
&$indent_print();
($newserver, $err) = &clone_system($server, $in{'host'}, $in{'desc'}, $ips,
				   $in{'live'}, $dest, $ips6, $in{'directory'});
&$outdent_print();
&release_lock_server($server);
if ($newserver && $err) {
	&$second_print(&text('clone_partial', $newserver->{'host'}, $err));
	}
elsif ($newserver && !$err) {
	&$second_print(&text('clone_done', $newserver->{'host'}));
	}
elsif (!$newserver && $err) {
	&$second_print(&text('clone_failed', $err));
	}

&release_lock_server($server);
if ($newserver) {
	&webmin_log("clone", "server", $server->{'host'},
		    'cmd' => $newserver->{'host'});
	if (defined(&theme_select_server)) {
		&theme_select_server($newserver);
		}
	}
&ui_print_footer("edit_serv.cgi?id=$in{'id'}", $text{'edit_return'});

