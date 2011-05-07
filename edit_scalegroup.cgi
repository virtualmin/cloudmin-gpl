#!/usr/local/bin/perl
# Show a form for creating or editing a single auto-scaling group

require './server-manager-lib.pl';
&can_action_error(undef, "global");
&ReadParse();

if ($in{'new'}) {
	# Creating a new one
	&ui_print_header(undef, $text{'scalegroup_ctitle'}, "");
	$scalegroup = { 'host' => 'system${NUM}',
			'manager' => $in{'type'},
			'min' => 1,
			'max' => 5,
			'notify_inc' => 1,
			'notify_over' => 1,
		 	'interval' => 3600,
			'master' => 1,
			'and' => 1, };
	}
else {
	# Editing an existing one
	&ui_print_header(undef, $text{'scalegroup_etitle'}, "");
	$scalegroup = &get_scalegroup($in{'id'});
	$scalegroup || &error($text{'scalegroup_egone'});
	}

# Build list of possible systems to clone
# XXX exclude auto-scaled
my @servers;
foreach my $s (grep { $_->{'manager'} eq $scalegroup->{'manager'} }
		&list_available_managed_servers_sorted()) {
	my $cfunc = "type_".$s->{'manager'}."_can_clone";
	if (defined(&$cfunc) && &$cfunc($s)) {
		push(@servers, $s);
		}
	}
@servers || &error($text{'scalegroup_eservers'});

print &ui_form_start("save_scalegroup.cgi", "post");
print &ui_hidden("id", $in{'id'});
print &ui_hidden("new", $in{'new'});
@tds = ( "width=20% nowrap" );

# Section for host system details
print &ui_hidden_table_start($text{'scalegroup_header1'}, "width=100%", 2,
			     "host", 1, \@tds);

print &ui_table_row($text{'scalegroup_manager'},
	$text{$scalegroup->{'manager'}.'_typedesc'});

print &ui_table_row($text{'scalegroup_desc'},
	&ui_textbox("desc", $scalegroup->{'desc'}, 60));

print &ui_table_row($text{'scalegroup_min'},
	&ui_textbox("min", $scalegroup->{'min'}, 5));

print &ui_table_row($text{'scalegroup_max'},
	&ui_textbox("max", $scalegroup->{'max'}, 5));

print &ui_hidden_table_end("host");

# Section for new system details
print &ui_hidden_table_start($text{'scalegroup_header2'}, "width=100%", 2,
			     "system", 1, \@tds);

# New hostname template
print &ui_table_row($text{'scalegroup_host'},
	&ui_textbox("host", $scalegroup->{'host'}, 40));

# System to clone
print &ui_table_row($text{'scalegroup_clone'},
	&ui_select("clone", undef, 
		   [ map { [ $_->{'id'}, $_->{'host'} ] } @servers ]));

# Host systems to create on
@vhosts = &list_available_host_servers($scalegroup->{'manager'});
@locs = &list_vhost_locations(\@vhosts);
$dmode = $scalegroup->{'dest_location'} ? 2 :
	 $scalegroup->{'dest_hosts'} ? 1 : 0;
@dtable = ( [ 0, $text{'scalegroup_dests0'} ],
	    [ 1, $text{'scalegroup_dests1'},
	      &ui_select("dest_hosts",
		 [ split(/\s+/, $scalegroup->{'dest_hosts'}) ],
		 [ map { [ $_->{'id'}, $_->{'host'}.
			    &host_free_desc($_, $scalegroup->{'manager'}) ] }
		       @vhosts ], 10, 1) ],
	  );
if (@locs) {
	push(@dtable, [ 2, $text{'scalegroup_dests2'},
			&ui_select("dest_location",
				   $scalegroup->{'dest_location'},
			           [ map { [ $_->{'id'}, $_->{'desc'} ] }
					 @locs ]) ]);
	}
print &ui_table_row($text{'scalegroup_dests'},
	&ui_radio_table("dests_mode", $dmode, \@dtable));

print &ui_hidden_table_end("system");

# Section for scaling conditions
print &ui_hidden_table_start($text{'scalegroup_header3'}, "width=100%", 2,
			     "cond", 0, \@tds);

@rtable = ( );
$i = 0;
@forunits = &list_for_units();
@stats = sort { $text{'history_stat_'.$a} cmp
                $text{'history_stat_'.$b} }
              &list_historic_stats(\@servers);
@names = map { [ $_, $text{'history_stat_'.$_} ] }
	     grep { !&is_binary_alert($_) } @stats;
unshift(@names, [ undef, '&nbsp;' ]);
foreach my $r (@{$scalegroup->{'conds'}},
	       { 'for' => 60, 'count' => 1, 'over' => 1 }) {
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

# And / or mode
print &ui_table_row(undef,
	&ui_radio("and", $alert->{'and'},
		  [ [ 1, $text{'scalegroup_and'} ],
		    [ 0, $text{'scalegroup_or'} ] ]), 2);

print &ui_hidden_table_end("cond");

# Section for email notification
print &ui_hidden_table_start($text{'scalegroup_header4'}, "width=100%", 2,
			     "email", 0, \@tds);

# When to notify
print &ui_table_row($text{'scalegroup_notifwhen'},
	&ui_checkbox("notify_inc", 1, $text{'scalegroup_notify_inc'},
		     $scalegroup->{'notify_inc'})."<br>\n".
	&ui_checkbox("notify_dec", 1, $text{'scalegroup_notify_dec'},
		     $scalegroup->{'notify_dec'})."<br>\n".
	&ui_checkbox("notify_over", 1, $text{'scalegroup_notify_over'},
		     $scalegroup->{'notify_over'}));

# Who to notify
print &ui_table_row($text{'alert_notif'},
	&ui_checkbox("master", 1, $text{'alert_master'},
		     $scalegroup->{'master'}).
	"<br>\n".
	&ui_checkbox("email", 1, $text{'alert_email'},
		     $scalegroup->{'email'}).
	" ".
	&ui_textbox("emailto", $scalegroup->{'email'}, 60));

# How often to send
@forunits = &list_for_units();
($intunit, $int) = &split_for_units($scalegroup->{'interval'});
print &ui_table_row($text{'alert_interval'},
	&ui_textbox("int", $int, 4).
	&ui_select("intunit", $intunit, \@forunits));

print &ui_hidden_table_end("email");

if ($in{'new'}) {
	print &ui_form_end([ [ undef, $text{'create'} ] ]);
	}
else {
	print &ui_form_end([ [ undef, $text{'save'} ],
			     [ 'delete', $text{'delete'} ] ]);
	}

&ui_print_footer("list_scalegroups.cgi", $text{'scalegroups_return'});

