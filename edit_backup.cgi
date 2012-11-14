#!/usr/local/bin/perl
# Show a form for editing or creating a backup

require './server-manager-lib.pl';
&can_action_error(undef, "backup");
&ReadParse();
if ($in{'new'}) {
	&ui_print_header(undef, $text{'backup_title1'}, "");
	$backup = { 'special' => 'daily',
		    'servers' => '*' };
	if ($access{'owner'}) {
		$owner = &get_system_owner($base_remote_user);
		$backup->{'email'} = $owner->{'acl'}->{'email'};
		$backup->{'owner'} = $base_remote_user;
		}
	}
else {
	($backup) = grep { $_->{'id'} eq $in{'id'} } &list_available_backups();
	$backup || &error($text{'backup_egone'});
	&ui_print_header(undef, $text{'backup_title2'}, "");
	}

print &ui_form_start("save_backup.cgi", "post");
print &ui_hidden("id", $in{'id'});
print &ui_hidden("new", $in{'new'});
print &ui_hidden_table_start($text{'backup_header'}, "width=100%", 2,
			     "main", 1, [ "width=30%" ]);

# Work out selection mode
@allservers = &list_available_managed_servers_sorted();
@canservers = grep { &supports_backup($_) } @allservers;
$mode = $backup->{'servers'} eq '*' ? 0 :
	$backup->{'servers'} ne '' ? 1 :
	$backup->{'groups'} ne '' ? 2 :
	$backup->{'owners'} ne '' ? 3 :
	$backup->{'managers'} ne '' ? 4 :
	$backup->{'scalegroups'} ne '' ? 5 :
	$backup->{'vhosts'} ne '' ? 7 :
	$backup->{'locs'} ne '' ? 8 :
	0;

# Build lists of groups, owners, hosts and locations
@allgroups = &unique(map { split(/\t/, $_->{'group'}) } @canservers);
@allowners = &list_system_owners();
@allscalegroups = &list_scalegroups() if (defined(&list_scalegroups));
@allvhosts = &list_parent_servers(\@canservers);
if (defined(&list_vhost_locations)) {
	@alllocs = &list_vhost_locations(\@allvhosts);
	}
if ($mode == 1) {
	%sids = map { $_, 1 } split(/\s+/, $backup->{'servers'});
	@servers = grep { $sids{$_->{'id'}} } @canservers;
	}
elsif ($mode == 4) {
	%mans = map { $_, 1 } split(/\s+/, $backup->{'managers'});
	}
elsif ($mode == 5) {
	%sids = map { $_, 1 } split(/\s+/, $backup->{'scalegroups'});
	@scalegroups = grep { $sids{$_->{'id'}} } @allscalegroups;
	}
elsif ($mode == 7) {
	%vids = map { $_, 1 } split(/\s+/, $backup->{'vhosts'});
	@vhosts = grep { $vids{$_->{'id'}} } @allvhosts;
	}
elsif ($mode == 8) {
	%lids = map { $_, 1 } split(/\s+/, $backup->{'locs'});
	@locs = grep { $lids{$_->{'id'}} } &list_locations();
	}

# Selection by individual systems
@stable = ( [ 0, $text{'alert_mode0'} ],
	    [ 1, $text{'alert_mode1'},
	      &ui_multi_select("servers",
		       [ map { [ $_->{'id'}, $_->{'host'} ] } @servers ],
		       [ map { [ $_->{'id'}, $_->{'host'} ] } @canservers ],
		       10, 1, 0, $text{'alert_serveropts'},
				 $text{'alert_servervals'}) ],
	  );
if (@allgroups) {
	# Selection by group
	push(@stable, [ 2, $text{'alert_mode2'},
		&ui_multi_select("groups",
		   [ map { [ $_, $_ ] } split(/\s+/, $backup->{'groups'}) ],
		   [ map { [ $_, $_ ] } @allgroups ],
		   5, 1, 0, $text{'alert_groupopts'},
			    $text{'alert_groupvals'}) ]);
	}
if (@allowners && !$backup->{'owner'}) {
	# Selection by system owner
	push(@stable, [ 3, $text{'alert_mode3'},
		&ui_multi_select("owners",
			[ map { [ $_,$_ ] } split(/\s+/, $backup->{'owners'}) ],
			[ map { [ $_->{'name'}, $_->{'name'} ] } @allowners ],
			5, 1, 0, $text{'alert_owneropts'},
				 $text{'alert_ownervals'}) ]);
	}

# Selection by VM type
%allmans = map { $_->{'manager'}, 1 } @canservers;
@backup_server_management_types = grep {
	my $cfunc = "type_".$_."_can_backup";
	defined(&$cfunc) && &$cfunc() && ($mans{$_} || $allmans{$_})
	} @virtual_server_management_types;
push(@stable, [ 4, $text{'alert_mode4'},
		join(" ", map { &ui_checkbox("managers", $_,
				     $text{$_.'_typedesc'} || $_, $mans{$_}) }
			      @backup_server_management_types) ]);

# Selection by host
if (@vhosts || @allvhosts) {
	push(@stable, [ 7, $text{'alert_mode7'},
		&ui_multi_select("vhosts",
			[ map { [ $_->{'id'}, $_->{'host'} ] } @vhosts ],
			[ map { [ $_->{'id'}, $_->{'host'} ] } @allvhosts ],
			5, 1, 0, $text{'alert_vhostopts'},
				 $text{'alert_vhostvals'}) ]);
	}

# Selection by location group
if (@locs || @alllocs) {
	push(@stable, [ 8, $text{'alert_mode8'},
		&ui_multi_select("locs",
			[ map { [ $_->{'id'}, $_->{'desc'} ] } @locs ],
			[ map { [ $_->{'id'}, $_->{'desc'} ] } @alllocs ],
			3, 1, 0, $text{'alert_locopts'},
				 $text{'alert_locvals'}) ]);
	}

print &ui_table_row($text{'backup_servers'},
		    &ui_radio_table("mode", $mode, \@stable), 2);

# Owner, if logged in as root
if (!$access{'owner'} && $backup->{'owner'}) {
	print &ui_table_row($text{'backup_owner'},
		"<a href='edit_owner.cgi?name=".&urlize($backup->{'owner'}).
		"'>".&html_escape($backup->{'owner'})."</a>");
	}

# Shutdown or pause?
print &ui_table_row($text{'backup_shutdown'},
	&ui_radio("shutdown", int($backup->{'shutdown'}),
		  [ [ 1, $text{'backup_shutdown1'} ],
		    [ 0, $text{'backup_shutdown0'} ] ]));

# Parallel mode
print &ui_table_row($text{'backup_parallel'},
	&ui_radio("parallel", int($backup->{'parallel'}),
		  [ [ 1, $text{'backup_parallel1'} ],
		    [ 0, $text{'backup_parallel0'} ] ]));

print &ui_hidden_table_end("main");

print &ui_hidden_table_start($text{'backup_destsect'}, "width=100%", 2,
                             "destsect", 0, [ "width=30%" ]);

# Destination
$dest = $backup->{'dest'} ? &parse_backup_destination($backup->{'dest'})
			  : undef;
if ($dest && $dest->{'mode'} == 0) {
	# On master, convert to on-host mode
	$dest->{'mode'} = 2;
	$dest->{'id'} = '0';
	}
$mode = !$backup->{'dest'} ? -1 : $dest->{'mode'};
print &ui_table_row(&hlink($text{'backup_dest'}, "backup_dest"),
	&ui_radio_table("dest_mode", $mode,
		[ [ -1, $text{'backup_dest0'} ],
		  [ 2, $text{'backups_mode2'},
		       &ui_select("vm2", $dest->{'id'},
			  [ map { [ $_->{'id'}, $_->{'short_host'} ] }
			        @allservers ]).
		       " ".
		       &ui_textbox("vm2dir",
			   $dest->{'mode'} == 2 ? $dest->{'path'} : "", 40) ],
		  [ 3, $text{'backup_dest3'},
			&show_backup_ssh_dest(
			    $mode == 3 ? $dest : { }, "ssh", 22) ],
		  [ 4, $text{'backup_dest4'},
			&show_backup_ssh_dest(
			    $mode == 4 ? $dest : { }, "ftp", 21) ],
	 	]));

print &ui_hidden_table_end("destsect");

print &ui_hidden_table_start($text{'backup_sched'}, "width=100%", 2,
                             "sched", 0, [ "width=30%" ]);

# Backup on scheduled enabled?
print &ui_table_row($text{'backup_enabled'},
	&ui_yesno_radio("enabled", $backup->{'enabled'}));

# Scheduled run time
print &ui_table_row($text{'backup_when'},
	&virtualmin_ui_show_cron_time("when", $backup, undef));

# Who to notify
if ($access{'owner'}) {
	# Owners don't see master admin option
	print &ui_table_row($text{'backup_email'},
		&ui_radio("emailother", $backup->{'email'} ? 1 : 0,
			  [ [ 0, $text{'backup_emailnone'} ],
			    [ 1, $text{'backup_emailaddr'} ] ])." ".
		&ui_textbox("email", $backup->{'email'}, 40));
	}
else {
	# Master admin can choose to notify self
	print &ui_table_row($text{'backup_email'},
		&ui_checkbox("emailmaster", 1, $text{'backup_emailmaster'},
			     $backup->{'emailmaster'})."<br>\n".
		&ui_checkbox("emailother", 1, $text{'backup_emailother'},
			     $backup->{'email'})." ".
		&ui_textbox("email", $backup->{'email'}, 40));
	}

# When to send
print &ui_table_row($text{'backup_always'},
	&ui_radio("always", int($backup->{'always'}),
		  [ [ 1, $text{'backup_always1'} ],
		    [ 0, $text{'backup_always0'} ] ]));

# Purge old backups?
print &ui_table_row($text{'backup_purge'},
	&ui_opt_textbox("purge", $backup->{'purge'}, 5, $text{'backup_purgeno'},
			$text{'backup_purgeafter'})." ".
	$text{'backup_purgedays'});

# Pre and post backup commands
$master = &get_managed_server(0);
if (&can_action($master, "run")) {
	print &ui_table_row($text{'backup_pre'},
		&ui_textbox("pre", $backup->{'pre'}, 60)."<br>\n".
		&ui_checkbox("pre_host", 1, $text{'backup_pre_host'},
			     $backup->{'pre_host'}));

	print &ui_table_row($text{'backup_post'},
		&ui_textbox("post", $backup->{'post'}, 60)."<br>\n".
		&ui_checkbox("post_host", 1, $text{'backup_pre_host'},
			     $backup->{'post_host'}));
	}

print &ui_hidden_table_end("sched");

if ($in{'new'}) {
	print &ui_form_end([ [ undef, $text{'create'} ] ]);
	}
else {
	print &ui_form_end([ [ undef, $text{'save'} ],
			     [ 'run', $text{'backup_run'} ],
			     [ 'restore', $text{'backup_restore'} ],
			     [ 'logs', $text{'backup_logs'} ],
			     [ 'delete', $text{'delete'} ] ]);
	}

&ui_print_footer("list_backups.cgi", $text{'backups_return'});
