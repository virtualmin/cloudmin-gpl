#!/usr/local/bin/perl
# Show resource limits for some system

require './server-manager-lib.pl';
&ReadParse();

# Get and check system
@servers = &list_managed_servers();
($server) = grep { $_->{'id'} == $in{'id'} } @servers;
$server || &error($text{'edit_egone'});
$t = $server->{'manager'};
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
	}

print &ui_table_end();
print &ui_form_end([ [ undef, $text{'save'} ] ]);

&ui_print_footer("edit_serv.cgi?id=$in{'id'}", $text{'edit_return'});

if (defined(&theme_select_server)) {
	&theme_select_server($server);
	}


