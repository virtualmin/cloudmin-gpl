#!/usr/local/bin/perl
# Show a form for creating or editing a single alert

require './server-manager-lib.pl';
&can_action_error(undef, "global");
&ReadParse();

if ($in{'new'}) {
	# Creating a new one
	&ui_print_header(undef, $text{'alert_ctitle'}, "");
	$alert = { 'all' => 1 };
	}
else {
	# Editing an existing one
	&ui_print_header(undef, $text{'alert_etitle'}, "");
	$alert = &get_alert($in{'id'});
	}

print &ui_form_start("save_alert.cgi", "post");
@tds = ( "width=30%" );

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
# XXX

# Section for notification
# XXX

if ($in{'new'}) {
	print &ui_form_end([ [ undef, $text{'create'} ] ]);
	}
else {
	print &ui_form_end([ [ undef, $text{'save'} ],
			     [ 'delete', $text{'delete'} ] ]);
	}

&ui_print_footer("list_alerts.cgi", $text{'alerts_return'});

