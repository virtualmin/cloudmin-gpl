#!/usr/local/bin/perl
# Show the status of some server, with a limited set of editable fields and
# sections showing domains and status

require './server-manager-lib.pl';
&ReadParse();
@servers = &list_managed_servers();
($server) = grep { $_->{'id'} == $in{'id'} } @servers;
$server || &error($text{'edit_egone'});
$status = $server->{'status'};
$info = &get_server_collected($server);
&can_action($server, "edit") || &can_action_error($server, "view");
$view = !&can_action($server, "edit");

# Heading and form start
@tds = ( "width=30%" );
$in{'basic'} = 1 if (!defined($in{'basic'}));
if ($view) {
	&ui_print_header(&server_in($server), $text{'view_title'}, "");

	print &ui_hidden_table_start($text{'edit_bheader'}, "width=100%", 2,
				     "basic", $in{'basic'}, \@tds);
	}
else {
	&ui_print_header(&server_in($server), $text{'edit_title'}, "", "edit");

	print &ui_form_start("save_serv.cgi", "post");
	print &ui_hidden("id", $in{'id'});
	print &ui_hidden_table_start($text{'edit_bheader'}, "width=100%", 2,
				     "basic", $in{'basic'}, \@tds);
	}

# Hostname (editable for anything except this host)
if ($server->{'id'} != 0 && !$view) {
	print &ui_table_row($text{'edit_host'},
			    &ui_textbox("host", $server->{'host'}, 50));
	}
else {
	print &ui_table_row($text{'edit_host'}, "<tt>$server->{'host'}</tt>");
	}

# System type
$t = $server->{'manager'};
$tfunc = "type_".$t."_desc";
print &ui_table_row($text{'edit_type'}, &$tfunc());

if ($server->{'id'} != 0) {
	# Description (maybe editable)
	print &ui_table_row($text{'edit_desc'},
		$view ? $server->{'desc'}
		      : &ui_textbox("desc", $server->{'desc'}, 50), 3);
	}

# OS type
if ($view) {
	($os) = grep { $_->[0] eq $server->{'type'} }
		     @servers::server_types;
	print &ui_table_row($text{'edit_type2'}, $os->[1]);
	}
else {
	print &ui_table_row($text{'edit_type2'},
		    &ui_select("type", $server->{'type'} || 'unknown',
		      [ map { [ $_->[0], $_->[1] ] }
			sort { $a->[1] cmp $b->[1] } @servers::server_types ]));
	}

# Kernel info
$k = $info->{'kernel'};
if ($k->{'version'}) {
	print &ui_table_row($text{'edit_kernel'},
		&text('edit_kernelon', $k->{'os'},
		       $k->{'version'}, $k->{'arch'}));
	}

if (!$view) {
	# Groups
	@groups = &unique(map { split(/\t/, $_->{'group'}) } @servers);
	%ingroups = map { $_, 1 } split(/\t/, $server->{'group'});
	@grid = ( );
	foreach $g (@groups) {
		push(@grid, &ui_checkbox("group", $g, $g, $ingroups{$g}));
		}
	push(@grid, (@grid ? "&nbsp;&nbsp;&nbsp;" : "").
		    &text('edit_newgroup', &ui_textbox("newgroup", undef, 10)));
	$gtable = &ui_grid_table(\@grid, 4);
	print &ui_table_row($text{'edit_groups'}, $gtable);

	# Start at boot
	$bfunc = "type_".$t."_get_atboot";
	if (defined(&$bfunc)) {
		print &ui_table_row($text{'edit_atboot'},
			    &ui_yesno_radio("atboot",&$bfunc($server) ? 1 : 0));
		}
	}

# Last status
print &ui_table_row($text{'edit_status'},
		    &text('edit_statustime', &describe_status($server, 1, 0),
				     &make_date($server->{'statustime'})));
if ($server->{'status_msg'}) {
	print &ui_table_row($text{'edit_statusmsg'},
			    $server->{'status_msg'});
	}

# Virtualmin config error
if ($status eq 'virt' && $server->{'virtualmin_error'}) {
	print &ui_table_row($text{'edit_configerr'},
	      "<font color=#ff0000>$server->{'virtualmin_error'}</font>");
	}

# Webmin version
if ($status eq 'virt' || $status eq 'novirt') {
	print &ui_table_row($text{'edit_webmin'},
			    $info->{'general'}->{'version'});
	}

if ($status eq 'virt') {
	# Virtualmin version
	print &ui_table_row($text{'edit_vversion'},
	    $info->{'minfo'}->{'version'}.' ('.
	    ($info->{'minfo'}->{'virtualmin'} eq 'gpl' ? 'GPL' : 'Pro').')');

	if (!$view) {
		# Enabled for Virtualmin domain creation
		print &ui_table_row($text{'add_canvirt'},
		    &ui_yesno_radio("canvirt", $server->{'novirt'} ? 0 : 1));
		}

	# Virtualmin licence
	if ($info->{'serial'}) {
		print &ui_table_row($text{'edit_vlicence'},
		    &text('edit_vsk', "<tt>$info->{'serial'}->{'serial'}</tt>",
				      "<tt>$info->{'serial'}->{'key'}</tt>"));
		}
	}

# Read-only bandwidth limit
$rfunc = "type_".$t."_real_interfaces";
if ($view && defined(&$rfunc) && $config{'bw_enabled'}) {
	# Limit
	print &ui_table_row($text{'edit_lbw'},
		$server->{'bw_limit'} ? &nice_size($server->{'bw_limit'})." ".
					&describe_bandwidth_period(0)
				      : $text{'bw_unlimited'});

	# Usage over this period
	print &ui_table_row($text{'edit_lusage'},
		&bandwidth_usage_message($server));
	}

print &ui_hidden_table_end("basic");

# Type-specific extra information, if any
$efunc = "type_".$t."_edit_form";
if (defined(&$efunc)) {
	print &ui_hidden_table_start(&text('edit_eheader', &$tfunc()),
				     "width=100%", 2,
				     "extra", $in{'extra'}, \@tds);
	print &$efunc($server, $view);
	print &ui_hidden_table_end("extra");
	}

# Show authentication form (if needed)
if ($view) {
	# Cannot edit authentication options in view mode
	$haswebmin = $hasssh = 0;
	}
else {
	$haswebmin = ($status eq 'nowebminlogin' || $status eq 'novirt' ||
		      $status eq 'downwebmin' || $status eq 'virt') &&
		     $server->{'id'} != 0;
	$sfunc = "type_".$t."_no_ssh";
	$hasssh = !defined(&$sfunc) || !&$sfunc();
	}
if ($haswebmin || $hasssh) {
	print &ui_hidden_table_start($text{'edit_aheader'}." ".
				     &hlink($text{'edit_help'}, "editauth"),
				     "width=100%", 2,
				     "auth", $in{'auth'}, \@tds);
	}

# SSH
if ($hasssh) {
	# SSH password / key
	print &ui_table_row($text{'edit_auth'},
	   &ui_radio("auth_mode", $server->{'ssh_nologin'} ? 2 :
				  $server->{'ssh_pass'} ? 0 : 1,
	      [ [ 0, &text('add_auth0',
		   &ui_textbox("upass", $server->{'ssh_pass'}, 20))."<br>" ],
		[ 1, &text('add_auth1',
			&ssh_key_menu("key", $t,$server->{'key'}))."<br>" ],
		[ 2, $text{'add_auth2'} ] ]));

	# SSH user
	print &ui_table_row($text{'edit_authuser'},
	   &ui_textbox("uuser", $server->{'ssh_user'}, 20));

	# SSH port
	print &ui_table_row($text{'edit_authport'},
	   &ui_opt_textbox("uport", $server->{'ssh_port'}, 5,
			   $text{'default'}." (22)"));
	}

# Webmin
if ($haswebmin) {
	$s = $server->{'ssh_pass_same'};
	print &ui_table_row($text{'edit_wauth'},
	    &ui_radio("webmin_mode", $s ? 1 : 2,
	      [ [ 1, $text{'add_webmin1'}."<br>" ],
	        [ 2, &text('add_webmin2',
		   &ui_textbox("wuser", $s ? "" : $server->{'user'}, 20),
		   &ui_textbox("wpass", $s ? "" : $server->{'pass'}, 20)) ] ]));
	}

if ($haswebmin || $hasssh) {
	print &ui_hidden_table_end("auth");
	}

# Action buttons at end of form (depends on status)
$down = $status eq 'down' || $status eq 'nossh' || $status eq 'nohost';
if ($view) {
	# No form, so no buttons
	}
elsif ($main::vm2_no_edit_buttons) {
	# Theme provides it's own action links
	print &ui_form_end([ [ "save", $text{'save'} ] ]);
	}
else {
	# Show our own buttons
	local @buts = ( [ "save", $text{'save'} ] );
	foreach my $b (&get_server_actions($server)) {
		if (!$b) {
			push(@buts, undef);
			}
		elsif ($b->{'link'}) {
			# Opens a separate URL
			local $js = $b->{'target'} ?
				"window.open(\"$b->[3]\")" :
				"document.location = \"$b->[3]\"";
			push(@buts, [ $b->{'id'}, $b->{'desc'}, undef, undef,
			    "onClick='$js; return false'" ] );
			}
		else {
			push(@buts, [ $b->{'id'}, $b->{'desc'} ]);
			}
		}
	print &ui_form_end(\@buts);
	}

&ui_print_footer("", $text{'index_return'});

if (defined(&theme_select_server)) {
	&theme_select_server($server);
	}


