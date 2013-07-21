#!/usr/local/bin/perl
# Show resource limits for some system

require './server-manager-lib.pl';
&ReadParse();

# Get and check system
$server = &get_managed_server($in{'id'});
$server || &error($text{'edit_egone'});
$t = $server->{'manager'};
$info = &get_server_collected($server);
$vhost = &get_parent_server($server);
if ($vhost) {
	$vinfo = &get_server_collected($vhost);
	}
$limits = &get_owner_limits();
&can_action_error($server, "limits");

&ui_print_header(&server_in($server), $text{'limits_title2'}, "", "limits");

print &ui_form_start("save_limits.cgi");
print &ui_hidden("id", $in{'id'});
print &ui_table_start($text{'edit_lheader'}, undef, 2);

# Memory limit
$mfunc = "type_".$t."_get_memory";
$m = defined(&$mfunc) ? &$mfunc($server) : undef;
if (defined($m)) {
	print &ui_table_hr() if ($donehr++);
	$ufunc =  "type_".$t."_can_unlimited_memory";
	if (defined(&$ufunc) && &$ufunc($server)) {
		# Unlimited option
		print &ui_table_row($text{'edit_lmemory'},
			&vui_opt_bytesbox("memory", $m || undef, undef,
					  $text{'edit_lunlimit'}, undef,
					  0, undef, undef, undef,
					  1024*1024));
		}
	else {
		# Memory limit must exist
		print &ui_table_row($text{'edit_lmemory'},
			&ui_bytesbox("memory", $m, undef, 0, undef,
				     1024*1024));
		}

	# Current memory usage in virtual system
	if ($info && $info->{'mem'}) {
		print &ui_table_row($text{'edit_umemory'},
			    &nice_size(($info->{'mem'}->[0]-
					$info->{'mem'}->[1])*1024));
		}

	# Memory usage on host system
	$freemem = &host_free_memory($vhost, $t, 0);
	if ($freemem) {
		print &ui_table_row($text{'edit_vmemory'},
			     &nice_size($freemem));
		}
	$freegmem = &host_free_memory($vhost, $t, 1);
	if ($freegmem && $freegmem != $freemem) {
		print &ui_table_row($text{'edit_vgmemory'},
			     &nice_size($freegmem));
		}

	# Owner memory limit
	if ($limits && $limits->{'max_ram'}) {
		print &ui_table_row($text{'edit_omemory'},
			&nice_size($limits->{'max_ram'} - $limits->{'ram'}));
		}
	}

# Guaranteed memory limit
$gmfunc = "type_".$t."_get_guaranteed_memory";
$gm = defined(&$gmfunc) ? &$gmfunc($server) : undef;
if (defined($gm)) {
	print &ui_table_row($text{'edit_gmemory'},
		&vui_opt_bytesbox("gmemory", $gm == $m ? undef : $gm, undef,
				  $text{'edit_gmemory_same'}, undef,
                                  0, undef, undef, undef, 1024*1024));
	}

# CPU limit
$cfunc = "type_".$t."_get_cpu";
if (defined(&$cfunc)) {
	($cpu, $weight) = &$cfunc($server);
	print &ui_table_hr() if ((defined($cpu) || defined($weight)) &&
				 $donehr++);
	if (defined($cpu)) {
		print &ui_table_row($text{'edit_lcpu'},
			&ui_opt_textbox("cpu", $cpu == 0 ? undef : $cpu,
				4, $text{'edit_lunlimit'})."%");
		}
	if (defined($weight)) {
		print &ui_table_row($text{'edit_lweight'},
			&ui_textbox("weight", $weight, 4));
		}

	# Owner CPU
	if ($limits && $limits->{'max_cpu'}) {
		print &ui_table_row($text{'edit_ocpu'},
			($limits->{'max_cpu'} - $limits->{'cpu'})."%");
		}
	}

# Disk limit
$dfunc = "type_".$t."_get_disk";
if (defined(&$dfunc)) {
	print &ui_table_hr() if ($donehr++);
	$disk = &$dfunc($server);
	print &ui_table_row($text{'edit_ldisk'},
		&vui_opt_bytesbox("disk", $disk || undef, undef,
				  $text{'edit_lunlimit'}, undef,
				  0, undef, undef, undef, 1024*1024*1024));

	# Current usage
	$sfunc = "type_".$t."_get_disk_space";
	if (defined(&$sfunc)) {
		$space = &$sfunc($server);
		if ($space) {
			print &ui_table_row($text{'edit_ludisk'},
				&nice_size($space));
			}
		}

	# Free disk on host
	$freedisk = &host_free_disk($vhost, $t, $server);
	if ($freedisk) {
		print &ui_table_row($text{'edit_vdisk'},
			&nice_size($freedisk));
		}

	# Owner disk limit
	if ($limits && $limits->{'max_disk'}) {
		print &ui_table_row($text{'edit_odisk'},
			&nice_size($limits->{'max_disk'} - $limits->{'disk'}));
		}
	}

# IO class
$ifunc = "type_".$t."_get_ioclass";
if (defined(&$ifunc) && &can_action($server, "ioclass")) {
	print &ui_table_hr() if ($donehr++);
	$ioclass = &$ifunc($server);
	print &ui_table_row($text{'edit_lioclass'},
		&ui_select("ioclass", $ioclass,
			[ [ 0, $text{'edit_lioclass0'} ],
			  1 .. 6,
			  [ 7, $text{'edit_lioclass7'} ] ]));
	}

# Bandwidth limit
$rfunc = "type_".$t."_real_interfaces";
if (defined(&$rfunc) && $config{'bw_enabled'}) {
	print &ui_table_hr() if ($donehr++);
	if (&can_action($server, "bw")) {
		# Edit limit
		print &ui_table_row($text{'edit_lbw'},
			&ui_radio("bw_def", $server->{'bw_limit'} ? 0 : 1,
				  [ [ 1, $text{'bw_unlimited'} ],
				    [ 0, $text{'bw_setto'} ] ])."\n".
			&ui_bytesbox("bw", $server->{'bw_limit'}, undef, 0,
				     undef, 1024*1024)."\n".
			&describe_bandwidth_period(0));
		}
	else {
		# Just show
		print &ui_table_row($text{'edit_lbw'},
			($server->{'bw_limit'} ?
				&nice_size($server->{'bw_limit'})." ".
				&describe_bandwidth_period(0) :
				$text{'bw_unlimited'}));
		}

	# Current usage
	print &ui_table_row($text{'edit_lusage'},
		&bandwidth_usage_message($server));
	}

# Network rate limit
$rfunc = "type_".$t."_get_network_rate";
if (defined(&$rfunc) && &can_action($server, "rate")) {
	$rate = &$rfunc($server);
	if (defined($rate)) {
		print &ui_table_row($text{'edit_lrate'},
			&ui_radio("rate_def", $rate ? 0 : 1,
			  [ [ 1, $text{'edit_lunlimit'} ],
			    [ 0, &ui_ratebox("rate", $rate || undef) ] ]));
		}
	}

# IP spoofing firewall
$cfunc = "type_".$t."_can_firewall";
if (defined(&$cfunc) && &$cfunc($server) && &can_action($server, "ifaces")) {
	$gfunc = "type_".$t."_get_firewall";
	@ips = &$gfunc($server);
	$mode = !@ips ? 0 : $ips[0] eq '*' ? 1 : 2;
	@sips = ( &get_server_ip($server), &get_server_ip6($server) );
	print &ui_table_row($text{'limits_firewall'},
	    &ui_radio_table("firewall_mode", $mode,
		[ [ 0, $text{'limits_firewall0'} ],
		  [ 1, $text{'limits_firewall1'} ],
		  [ 2, $text{'limits_firewall2'},
		    &ui_textbox("firewall",
			$mode == 2 ? join(" ", @ips)
				   : join(" ", @sips), 60) ] ]));
	}

print &ui_table_end();
print &ui_form_end([ [ undef, $text{'save'} ] ]);

&ui_print_footer("edit_serv.cgi?id=$in{'id'}", $text{'edit_return'});

if (defined(&theme_select_server)) {
	&theme_select_server($server);
	}


