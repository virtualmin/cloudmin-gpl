#!/usr/local/bin/perl
# Update resource limits for some system

require './server-manager-lib.pl';
&error_setup($text{'limits_err'});

# Get the server
&ReadParse();
@servers = &list_managed_servers();
($server) = grep { $_->{'id'} == $in{'id'} } @servers;
$server || &error($text{'edit_egone'});
&can_action_error($server, "limits");
$t = $server->{'manager'};

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
	$in{'weight'} =~ /^\d+$/ || &error($text{'limits_eweight'});
	}
if (defined($in{'bw'})) {
	$in{'bw_def'} || $in{'bw'} =~ /^[1-9]\d*$/ ||
		&error($text{'limits_ebw'});
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
		# Call set function and check
		$cfunc = "type_".$t."_save_cpu";
		$err = &$cfunc($server,
			       !defined($in{'cpu'}) ? undef :
			       $in{'cpu_def'} ? 0 : $in{'cpu'},
			       !defined($in{'weight'}) ? undef : $in{'weight'});
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

# Bandwidth limit
if (defined($in{'bw'})) {
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

&save_managed_server($server);
&release_lock_server($server);

# Offer to reboot if needed
if ($reboot && $server->{'status'} ne 'down') {
	print &ui_form_start("save_serv.cgi");
	print &ui_hidden("id", $in{'id'});
	print &ui_hidden("reboot", 1);
	print &ui_hidden("confirm", 1);
	print "<b>$text{'limits_needreboot'}</b><p>\n";
	print &ui_form_end([ [ undef, $text{'limits_reboot'} ] ]);
	}

&ui_print_footer("edit_serv.cgi?id=$in{'id'}", $text{'edit_return'},
		 "", $text{'index_return'});


