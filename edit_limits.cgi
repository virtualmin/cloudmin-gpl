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
&can_action_error($server, "limits");

&ui_print_header(&server_in($server), $text{'limits_title2'}, "", "limits");

print &ui_form_start("save_limits.cgi");
print &ui_hidden("id", $in{'id'});
print &ui_table_start($text{'edit_lheader'}, undef, 2);

# Memory limit
$mfunc = "type_".$t."_get_memory";
$m = defined(&$mfunc) ? &$mfunc($server) : undef;
if (defined($m)) {
	$ufunc =  "type_".$t."_can_unlimited_memory";
	if (defined(&$ufunc) && &$ufunc($server)) {
		# Unlimited option
		print &ui_table_row($text{'edit_lmemory'},
			&ui_radio("memory_def", $m ? 0 : 1,
				  [ [ 1, $text{'edit_lunlimit'} ],
				    [ 0, &ui_bytesbox("memory", $m || '') ] ]));
		}
	else {
		# Memory limit must exist
		print &ui_table_row($text{'edit_lmemory'},
			&ui_bytesbox("memory", $m));
		}

	# Current memory usage in virtual system
	if ($info && $info->{'mem'}) {
		print &ui_table_row($text{'edit_umemory'},
			    &nice_size(($info->{'mem'}->[0]-
					$info->{'mem'}->[1])*1024));
		}

	# Memory usage on host system
	if ($vhost && $vhost->{$t.'_mem_free'}) {
		print &ui_table_row($text{'edit_vmemory'},
			     &nice_size($vhost->{$t.'_mem_free'}));
		}
	elsif ($vinfo && $vinfo->{'mem'}) {
		print &ui_table_row($text{'edit_vmemory'},
			      &nice_size($vinfo->{'mem'}->[1]*1024));
		}

	print &ui_table_hr();
	}

# CPU limit
$cfunc = "type_".$t."_get_cpu";
if (defined(&$cfunc)) {
	($cpu, $weight) = &$cfunc($server);
	if (defined($cpu)) {
		print &ui_table_row($text{'edit_lcpu'},
			&ui_opt_textbox("cpu", $cpu == 0 ? undef : $cpu,
				4, $text{'edit_lunlimit'})."%");
		}
	if (defined($weight)) {
		print &ui_table_row($text{'edit_lweight'},
			&ui_textbox("weight", $weight, 4));
		}

	print &ui_table_hr();
	}

# Disk limit
$dfunc = "type_".$t."_get_disk";
if (defined(&$dfunc)) {
	$disk = &$dfunc($server);
	print &ui_table_row($text{'edit_ldisk'},
		&ui_radio("disk_def", $disk ? 0 : 1,
			  [ [ 1, $text{'edit_lunlimit'} ],
			    [ 0, &ui_bytesbox("disk", $disk || undef) ] ]));

	# Current usage
	$sfunc = "type_".$t."_get_disk_space";
	if (defined(&$sfunc)) {
		$space = &$sfunc($server);
		if ($space) {
			print &ui_table_row($text{'edit_udisk'},
				&nice_size($space));
			}
		}

	# Free disk on host
	if ($vhost && $vhost->{$t.'_vg_free'}) {
		print &ui_table_row($text{'edit_vdisk'},
			&nice_size($vhost->{$t.'_vg_free'}));
		}
	elsif ($vinfo && $vinfo->{'disk_free'}) {
		print &ui_table_row($text{'edit_vdisk'},
			&nice_size($vinfo->{'disk_free'}));
		}

	print &ui_table_hr();
	}

# Bandwidth limit
$rfunc = "type_".$t."_real_interfaces";
if (defined(&$rfunc) && $config{'bw_enabled'}) {
	if (&can_action($server, "bw")) {
		# Edit limit
		print &ui_table_row($text{'edit_lbw'},
			&ui_radio("bw_def", $server->{'bw_limit'} ? 0 : 1,
				  [ [ 1, $text{'bw_unlimited'} ],
				    [ 0, $text{'bw_setto'} ] ])."\n".
			&ui_bytesbox("bw", $server->{'bw_limit'}, 8)."\n".
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

	print &ui_table_hr();
	}

# Network rate limit
$rfunc = "type_".$t."_get_network_rate";
if (defined(&$rfunc)) {
	$rate = &$rfunc($server);
	if (defined($rate)) {
		print &ui_table_row($text{'edit_lrate'},
			&ui_radio("rate_def", $rate ? 0 : 1,
			  [ [ 1, $text{'edit_lunlimit'} ],
			    [ 0, &ui_ratebox("rate", $rate || undef) ] ]));
		}
	}

print &ui_table_end();
print &ui_form_end([ [ undef, $text{'save'} ] ]);

&ui_print_footer("edit_serv.cgi?id=$in{'id'}", $text{'edit_return'});

if (defined(&theme_select_server)) {
	&theme_select_server($server);
	}


