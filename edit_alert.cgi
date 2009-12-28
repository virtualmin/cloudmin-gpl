#!/usr/local/bin/perl
# Show a form for creating or editing a single alert

require './server-manager-lib.pl';
&can_action_error(undef, "global");
&ReadParse();

if ($in{'new'}) {
	# Creating a new one
	&ui_print_header(undef, $text{'alert_ctitle'}, "");
	$alert = { 'all' => 1,
		   'and' => 1,
		   'master' => 1,
		   'interval' => 3600 };
	}
else {
	# Editing an existing one
	&ui_print_header(undef, $text{'alert_etitle'}, "");
	$alert = &get_alert($in{'id'});
	$alert || &error($text{'alert_egone'});
	}

print &ui_form_start("save_alert.cgi", "post");
print &ui_hidden("id", $in{'id'});
print &ui_hidden("new", $in{'new'});
@tds = ( "width=20% nowrap" );

# Section for systems
print &ui_hidden_table_start($text{'alert_header1'}, "width=100%", 2,
			     "servers", 1, \@tds);

$mode = $alert->{'servers'} ? 1 :
	$alert->{'groups'} ? 2 :
	$alert->{'owners'} ? 3 :
	$alert->{'managers'} ? 4 : 0;
@allservers = &list_managed_servers_sorted();
@allgroups = &unique(map { split(/\t/, $_->{'group'}) } @allservers);
@allowners = &list_system_owners();
if ($mode == 1) {
	%sids = map { $_, 1 } split(/\s+/, $alert->{'servers'});
	@servers = grep { $sids{$_->{'id'}} } @allservers;
	}
elsif ($mode == 4) {
	%mans = map { $_, 1 } split(/\s+/, $alert->{'managers'});
	}
@stable = ( [ 0, $text{'alert_mode0'} ],
	    [ 1, $text{'alert_mode1'},
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
		   [ map { [ $_, $_ ] } split(/\s+/, $alert->{'groups'}) ],
		   [ map { [ $_, $_ ] } @allgroups ],
		   5, 1, 0, $text{'alert_groupopts'},
			    $text{'alert_groupvals'}) ]);
	}
if (@allowners) {
	# Selection by system owner
	push(@stable, [ 3, $text{'alert_mode3'},
		&ui_multi_select("owners",
			[ map { [ $_, $_ ] } split(/\s+/, $alert->{'owners'}) ],
			[ map { [ $_->{'name'}, $_->{'name'} ] } @allowners ],
			5, 1, 0, $text{'alert_owneropts'},
				 $text{'alert_ownervals'}) ]);
	}
push(@stable, [ 4, $text{'alert_mode4'},
		join(" ", map { &ui_checkbox("managers", $_,
				     $text{$_.'_typedesc'} || $_, $mans{$_}) }
			      @server_management_types) ]);
print &ui_table_row(undef, &ui_radio_table("mode", $mode, \@stable), 2);

print &ui_hidden_table_end("servers");

# Section for rules
print &ui_hidden_table_start($text{'alert_header2'}, "width=100%", 2,
			     "rules", 1, \@tds);

@rtable = ( );
$i = 0;
@forunits = &list_for_units();
@names = map { [ $_, $text{'history_stat_'.$_} ] }
             sort { $text{'history_stat_'.$a} cmp
                    $text{'history_stat_'.$b} }
                  &list_historic_stats(\@allservers);
unshift(@names, [ undef, '&nbsp;' ]);
foreach my $r (@{$alert->{'rules'}}, { 'for' => 60, 'count' => 1 },
				     { 'for' => 60, 'count' => 1 }) {
	($forunit, $for) = &split_for_units($r->{'for'});
	push(@rtable, [ &ui_select("name_$i", $r->{'name'}, \@names),
			&ui_select("over_$i", $r->{'over'} ? 1 : 0,
				   [ [ 1, $text{'alert_over'} ],
				     [ 0, $text{'alert_under'} ] ]),
			&ui_textbox("value_$i", $r->{'value'}, 6),
			&ui_textbox("for_$i", $for, 4).
			 &ui_select("forunit_$i", $forunit, \@forunits),
			&ui_textbox("count_$i", $r->{'count'}, 4),
			]);
	$i++;
	}
print &ui_table_row(undef,
	&ui_columns_table([ $text{'alert_name'}, $text{'alert_comp'},
			    $text{'alert_value'},
			    $text{'alert_for'}, $text{'alert_count'} ],
			  100, \@rtable, undef, 1), 2);

print &ui_table_row(undef,
	&ui_radio("and", $alert->{'and'},
		  [ [ 1, $text{'alert_and'} ], [ 0, $text{'alert_or'} ] ]), 2);

print &ui_hidden_table_end("rules");

# Section for notification
print &ui_hidden_table_start($text{'alert_header3'}, "width=100%", 2,
			     "notif", 1, \@tds);

# Who to notify
print &ui_table_row($text{'alert_notif'},
	&ui_checkbox("master", 1, $text{'alert_master'}, $alert->{'master'}).
	"<br>\n".
	&ui_checkbox("owner", 1, $text{'alert_owner'}, $alert->{'owner'}).
	"<br>\n".
	&ui_checkbox("email", 1, $text{'alert_email'}, $alert->{'email'}).
	" ".
	&ui_textbox("emailto", $alert->{'email'}, 40));

# How often to send
($intunit, $int) = &split_for_units($alert->{'interval'});
print &ui_table_row($text{'alert_interval'},
	&ui_textbox("int", $int, 4).
	&ui_select("intunit", $intunit, \@forunits));

# Alert message
print &ui_table_row($text{'alert_desc'},
	&ui_opt_textbox("desc", $alert->{'desc'}, 50, $text{'alert_descdef'}));

print &ui_hidden_table_end("notif");

if ($in{'new'}) {
	print &ui_form_end([ [ undef, $text{'create'} ] ]);
	}
else {
	print &ui_form_end([ [ undef, $text{'save'} ],
			     [ 'delete', $text{'delete'} ] ]);
	}

&ui_print_footer("list_alerts.cgi", $text{'alerts_return'});

