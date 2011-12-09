#!/usr/local/bin/perl
# Show a form for creating or editing a single DNS roundrobin

require './server-manager-lib.pl';
&can_action_error(undef, "global");
&ReadParse();

if ($in{'new'}) {
	# Creating a new one
	&ui_print_header(undef, $text{'roundrobin_ctitle'}, "");
	$roundrobin = { 'master' => 1, 'interval' => 3600, 'min' => 2,
			'ttl' => 60, 'status' => 'nowebmin novirt virt alive' };
	}
else {
	# Editing an existing one
	&ui_print_header(undef, $text{'roundrobin_etitle'}, "");
	$roundrobin = &get_roundrobin($in{'id'});
	$roundrobin || &error($text{'roundrobin_egone'});
	}

print &ui_form_start("save_roundrobin.cgi", "post");
print &ui_hidden("id", $in{'id'});
print &ui_hidden("new", $in{'new'});
@tds = ( "width=20% nowrap" );

# Section for systems
print &ui_hidden_table_start($text{'roundrobin_header1'}, "width=100%", 2,
			     "servers", 1, \@tds);

$mode = $roundrobin->{'servers'} ne '' ? 1 :
	$roundrobin->{'groups'} ne '' ? 2 :
	$roundrobin->{'owners'} ne '' ? 3 :
	$roundrobin->{'scalegroups'} ne '' ? 5 :
	$roundrobin->{'iplist'} ne '' ? 6 : 1;
@allservers = &list_managed_servers_sorted();
@virtservers = grep { $_->{'status'} eq 'virt' } @allservers;
@allgroups = &unique(map { split(/\t/, $_->{'group'}) } @allservers);
@allowners = &list_system_owners();
@allscalegroups = defined(&list_scalegroups) ? &list_scalegroups() : ( );
if ($mode == 1) {
	%sids = map { $_, 1 } split(/\s+/, $roundrobin->{'servers'});
	@servers = grep { $sids{$_->{'id'}} } @allservers;
	}
elsif ($mode == 5) {
	%sids = map { $_, 1 } split(/\s+/, $roundrobin->{'scalegroups'});
	@scalegroups = grep { $sids{$_->{'id'}} } @allscalegroups;
	}
@stable = ( [ 1, $text{'alert_mode1'},
	      &ui_multi_select("servers",
		       [ map { [ $_->{'id'}, $_->{'host'} ] } @servers ],
		       [ map { [ $_->{'id'}, $_->{'host'} ] } @allservers ],
		       10, 1, 0, $text{'alert_serveropts'},
				 $text{'alert_servervals'}) ],
	  );
if (@allgroups) {
	# Selection by group
	push(@stable, [ 2, $text{'alert_mode2'},
		&ui_multi_select("groups",
		   [ map { [ $_, $_ ] } split(/\s+/, $roundrobin->{'groups'}) ],
		   [ map { [ $_, $_ ] } @allgroups ],
		   5, 1, 0, $text{'alert_groupopts'},
			    $text{'alert_groupvals'}) ]);
	}
if (@allowners) {
	# Selection by system owner
	push(@stable, [ 3, $text{'alert_mode3'},
		&ui_multi_select("owners",
		  [ map { [ $_, $_ ] } split(/\s+/, $roundrobin->{'owners'}) ],
		  [ map { [ $_->{'name'}, $_->{'name'} ] } @allowners ],
		  5, 1, 0, $text{'alert_owneropts'},
			   $text{'alert_ownervals'}) ]);
	}
if (@allscalegroups) {
	# Selection by auto-scaling group
	push(@stable, [ 5, $text{'alert_mode5'},
		      &ui_multi_select("scalegroups",
		       [ map { [ $_->{'id'}, $_->{'host'} ] } @scalegroups ],
		       [ map { [ $_->{'id'}, $_->{'host'} ] } @allscalegroups ],
		       3, 1, 0, $text{'alert_scalegroupopts'},
				 $text{'alert_scalegroupvals'}) ]);
	}
# Selection by arbitrary IPs
push(@stable, [ 6, $text{'alert_mode6'},
		&ui_textarea("iplist",
			     join("\n", split(/\s+/, $roundrobin->{'iplist'})),
			     5, 40) ]);
print &ui_table_row(undef, &ui_radio_table("mode", $mode, \@stable), 2);

print &ui_hidden_table_end("servers");

# Section for DNS name and zone
print &ui_hidden_table_start($text{'roundrobin_header2'}, "width=100%", 2,
			     "dns", 1, \@tds);

print &ui_table_row($text{'roundrobin_desc'},
	&ui_textbox("desc", $roundrobin->{'desc'}, 60));

print &ui_table_row($text{'roundrobin_name'},
	&ui_textbox("name", $roundrobin->{'name'}, 20));

@zones = &list_bind_zones();
print &ui_table_row($text{'roundrobin_dom'},
	&ui_select("dom", $roundrobin->{'dom'},
		   [ map { [ $_->{'name'}, $_->{'desc'} ] } @zones ],
		   1, 0, $roundrobin->{'dom'} ? 1 : 0));

print &ui_table_row($text{'roundrobin_ttl'},
	&ui_textbox("ttl", $roundrobin->{'ttl'}, 6)." ".
	$text{'roundrobin_secs'});

print &ui_table_row($text{'roundrobin_dnscount'},
	&ui_opt_textbox("dnscount", $roundrobin->{'dnscount'}, 6,
			$text{'roundrobin_dnscount_max'},
			$text{'roundrobin_dnscount_most'}));

print &ui_hidden_table_end("dns");

# Section for conditions
print &ui_hidden_table_start($text{'roundrobin_header3'}, "width=100%", 2,
			     "cond", 0, \@tds);

# By status
%selst = map { $_, 1 } split(/\s+/, $roundrobin->{'status'});
@grid = ( );
foreach my $st ('noping', 'nossh', 'nosshlogin', 'downwebmin',
                'nowebminlogin', 'nowebmin', 'novirt', 'virt', 'alive') {
	$sdesc = &describe_status({ 'status' => $st }, 1, 0);
	push(@grid, &ui_checkbox("status", $st, $sdesc, $selst{$st}));
	}
print &ui_table_row($text{'roundrobin_status'},
	&ui_grid_table(\@grid, 5));

# By TCP ports open
@ports = split(/\s+/, $roundrobin->{'ports'});
print &ui_table_row($text{'roundrobin_ports'},
	&ui_opt_textbox("ports", join(" ", @ports), 40,
		$text{'roundrobin_portsdef'}, $text{'roundrobin_portssel'}));

# By URL
print &ui_table_row($text{'roundrobin_url'},
	&ui_opt_textbox("url", $roundrobin->{'url'}, 60,
			$text{'roundrobin_urldef'}, $text{'roundrobin_urlsel'}).
	"<br>\n".$text{'roundrobin_urldesc'});

# By firing alerts
@alerts = &list_alerts();
if (@alerts) {
	print &ui_table_row($text{'roundrobin_alerts'},
		&ui_select("alerts",
			   [ split(/\s+/, $roundrobin->{'alerts'}) ],
			   [ map { [ $_->{'id'}, &describe_alert_rules($_) ] }
				 @alerts ], 5, 1));
	}

print &ui_hidden_table_end("cond");

# Section for proxy balancer domain to update
if (@virtservers) {
	print &ui_hidden_table_start($text{'roundrobin_header6'},
				     "width=100%", 2, "balancer", 0, \@tds);

	# System hosting domain to update
	print &ui_table_row($text{'roundrobin_bhost'},
		&ui_select("bhost", $roundrobin->{'bhost'},
			   [ [ "", "&lt;$text{'roundrobin_bnone'}&gt;" ],
			     map { [ $_->{'id'}, $_->{'host'} ] }
				 @virtservers ]));

	# Domain name
	print &ui_table_row($text{'roundrobin_bdomain'},
		&ui_textbox("bdomain", $roundrobin->{'bdomain'}, 40));

	# URL path
	print &ui_table_row($text{'roundrobin_burl'},
		&ui_textbox("burl", $roundrobin->{'burl'} || "/", 20));

	# Destination port number
	print &ui_table_row($text{'roundrobin_bport'},
		&ui_textbox("bport", $roundrobin->{'bport'} || 80, 6));

	print &ui_hidden_table_end("balancer");
	}

# Section for notification
print &ui_hidden_table_start($text{'roundrobin_header4'}, "width=100%", 2,
			     "notif", 0, \@tds);

# Minimum hosts in group to alert at
print &ui_table_row($text{'roundrobin_min'},
	&ui_textbox("min", $roundrobin->{'min'}, 5));

# Who to notify
print &ui_table_row($text{'alert_notif'},
	&ui_checkbox("master", 1, $text{'alert_master'},
		     $roundrobin->{'master'}).
	"<br>\n".
	&ui_checkbox("email", 1, $text{'alert_email'},
		     $roundrobin->{'email'}).
	" ".
	&ui_textbox("emailto", $roundrobin->{'email'}, 60));

# How often to send
@forunits = &list_for_units();
($intunit, $int) = &split_for_units($roundrobin->{'interval'});
print &ui_table_row($text{'alert_interval'},
	&ui_textbox("int", $int, 4).
	&ui_select("intunit", $intunit, \@forunits));

print &ui_hidden_table_end("notif");

# Show servers and current status
if ($roundrobin->{'include'} || $roundrobin->{'whynot'}) {
	print &ui_hidden_table_start(
		&text('roundrobin_header5',
		      &make_date($roundrobin->{'lastcheck'})), "width=100%",
		2, "status",
		$roundrobin->{'whynot'} || $roundrobin->{'msg'} ? 1 : 0, \@tds);

	# Show reason for update failure
	if ($roundrobin->{'msg'}) {
		print &ui_table_row(undef,
			"<font color=red><b>".
			&text('roundrobin_fail', $roundrobin->{'msg'}).
			"</b></font>", 2);
		}

	$rtable = &ui_columns_start([ $text{'roundrobin_host'},
				      $text{'roundrobin_ip'},
				      $text{'roundrobin_cstatus'} ], 100);
	%inc = map { $_, 1 } split(/\s+/, $roundrobin->{'include'});
	%whynot = map { my ($id, $r, $msg) = split(",", $_, 3);
			($id, [ $r, $msg ]) }
		      split(/\s+/, $roundrobin->{'whynot'});
	%dnsover = map { $_, 1 } split(/\s+/, $roundrobin->{'dnsover'});
	foreach $s (&get_roundrobin_servers($roundrobin, \@allservers)) {
		$ip = &get_server_ip($s);
		@row = ( "<a href='edit_serv.cgi?id=$s->{'id'}'>".
			 $s->{'host'}."</a>", $ip );
		if ($dnsover{$s->{'id'}}) {
			push(@row, "<font color=orange>".
				   $text{'roundrobin_dnsover'}."</font>");
			}
		elsif ($inc{$s->{'id'}}) {
			push(@row, "<font color=green>".
				   $text{'roundrobin_ok'}."</font>");
			}
		elsif ($whynot{$s->{'id'}}) {
			($r, $msg) = @{$whynot{$s->{'id'}}};
			if ($r eq 'status') {
				$msg = &describe_status({ 'status' => $msg });
				}
			elsif ($r eq 'alert') {
				@alerts = grep { $_ } map { &get_alert($_) }
					       split(",", $msg);
				$msg = join(" ",
				    map { &describe_alert_rules($_) } @alerts);
				}
			push(@row, "<font color=red>".
				   &text('roundrobin_status_'.$r, $msg).
				   "</font>");
			}
		else {
			push(@row, $text{'roundrobin_stnot'});
			}
		$rtable .= &ui_columns_row(\@row);
		}
	$rtable .= &ui_columns_end();
	print &ui_table_row(undef, $rtable, 2);

	print &ui_hidden_table_end("status");
	}

if ($in{'new'}) {
	print &ui_form_end([ [ undef, $text{'create'} ] ]);
	}
else {
	print &ui_form_end([ [ undef, $text{'save'} ],
			     [ 'delete', $text{'delete'} ] ]);
	}

&ui_print_footer("list_roundrobins.cgi", $text{'roundrobins_return'});

