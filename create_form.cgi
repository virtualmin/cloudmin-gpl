#!/usr/local/bin/perl
# Show a form for creating a new server, on some virtualization system that
# supports it

require './server-manager-lib.pl';
&ReadParse();
&can_create_server_error($in{'type'});
&ui_print_header(undef, $text{'create_title'}, "", "new".$in{'type'});
@servers = &list_managed_servers();

# Check if 'empty' creation is supported
$efunc = "type_".$in{'type'}."_can_create_empty";
$empty = defined(&$efunc) && &$efunc() && &can_action(undef, "empty");
if ($empty) {
	# Yes, so show tabs
	$prog = "create_form.cgi?type=$in{'type'}&mode=";
	@tabs = ( [ "full", $text{'create_tabfull'}, $prog."full" ],
		  [ "empty", $text{'create_tabempty'}, $prog."empty" ] );
	print &ui_tabs_start(\@tabs, "mode", $in{'mode'} || "full", 1);
	print &ui_tabs_start_tab("mode", "full");
	print $text{'create_descfull'},"<p>\n";
	}

print &ui_form_start("create.cgi", "post");
print &ui_hidden("type", $in{'type'});
print &ui_hidden_table_start($text{'create_header'}, "width=100%", 2,
			     "main", 1, [ "width=30%" ]);

# Type of system
$tfunc = "type_".$in{'type'}."_desc";
print &ui_table_row($text{'add_type'}, &$tfunc());

# Hostname
$hfunc = "type_".$in{'type'}."_no_create_hostname";
if (!defined(&$hfunc) || !&$hfunc()) {
	print &ui_table_row($text{'create_host'},
			    &ui_textbox("host", undef, 40));
	}

# Unix hostname
$chfunc = "type_".$in{'type'}."_can_custom_hostname";
if (defined(&$chfunc) && &$chfunc() && $config{'show_unix'}) {
	print &ui_table_row($text{'create_unixhost'},
			    &ui_opt_textbox("unixhost", undef, 40,
					    $text{'create_unixsame'}));
	}

# Description
print &ui_table_row($text{'add_desc'},
	&ui_textbox("desc", undef, 60));

# In groups
if (&can_action($server, "groups")) {
	print &ui_table_row($text{'edit_groups'},
		&show_groups_form($server, \@servers));
	}

# System image, if any are available for the server type
@images = &list_server_images($in{'type'});
@images = grep { &can_image($_) && $_->{'format'} ne 'cd' } @images;
$ifunc = "type_".$in{'type'}."_must_image";
$mustimage = defined(&$ifunc) && &$ifunc();
if (@images) {
	# Can select an image
	$noimage = $text{'create_noimage_'.$in{'type'}} ||
		   $text{'create_noimage'};
	($defimage) = grep { $_->{'default'} } @images;
	print &ui_table_row($text{'create_image'},
		&ui_select("image", $defimage ? $defimage->{'id'} : undef,
			[ $mustimage || !&can_image(undef) ? ( )
				     : ( [ undef, $noimage ] ),
			  map { [ $_->{'id'}, $_->{'desc'} ] }
			      sort { lc($a->{'desc'}) cmp lc($b->{'desc'}) }
				   @images ]));
	}
elsif ($mustimages) {
	# No images available, but none are needed
	print &ui_table_row($text{'create_image'},
		"<font color=red>$text{'create_noimagedownloaded'}</font>");
	}

# Root password / SSH key (if possible)
$sfunc = "type_".$in{'type'}."_no_ssh";
$no_ssh = defined(&$sfunc) && &$sfunc();
if (!$no_ssh) {
	$pfunc = "type_".$in{'type'}."_no_create_pass";
	if (defined(&$pfunc) && &$pfunc()) {
		# This server type doesn't set a root password at creation
		# (ie. EC2)
		$has_root_password = 0;
		print &ui_table_row($text{'create_sshkey'},
				    &ssh_key_menu("key", $in{'type'}));
		print &ui_hidden("auth_mode", 1);
		}
	elsif (!&can_action(undef, "sshkeys")) {
		# Cannot select SSH keys
		$has_root_password = 1;
		print &ui_table_row($text{'add_authpass'},
			&ui_password("upass", undef, 20));
		}
	else {
		# Can enter password or key or neither
		$has_root_password = 1;
		$randpass = $config{'passwd_mode'} ? &random_password() : "";
		print &ui_table_row($text{'add_auth'},
		    &ui_radio("auth_mode", 0,
		      [ [ 0, &text('add_auth0',
			   &ui_password("upass", $randpass, 20))."<br>" ],
			[ 1, &text('add_auth1', &ssh_key_menu("key"))."<br>" ],
			[ 2, $text{'add_auth2'} ] ]));

		# SSH port field
		if ($config{'ssh_port'}) {
			print &ui_table_row($text{'add_sshport'},
			    &ui_textbox("ssh_port", $config{'ssh_port'}, 5));
			}
		}
	}
else {
	$has_root_password = 0;
	}

# System owner
if (&can_action(undef, "global") && defined(&list_system_owners) &&
    !$access{'owner'}) {
	@owners = sort { $a->{'name'} cmp $b->{'name'} } &list_system_owners();
	@otable = ( [ 0, $text{'create_noowner'} ] );
	if (@owners) {
		push(@otable, [ 1, $text{'create_oexist'},
				&ui_select("owner", undef,
				  [ map { $_->{'name'} } @owners ]) ]);
		}
	@plans = &supports_plans() ? &list_plans() : ( );
	if (@plans) {
		push(@otable, [ 2, $text{'create_onew'},
			&ui_textbox("newowner", undef, 20)." ".
			$text{'create_onewpass'}." ".
		        &ui_password("newownerpass", undef, 20)."<br>".
		  	&ui_select("newownerplan", $plans[0]->{'id'},
			    [ map { [ $_->{'id'}, &describe_plan($_) ] }
				  @plans ]) ]);
		}
	if (@otable > 1) {
		print &ui_table_row($text{'create_owner'},
			&ui_radio_table("omode", 0, \@otable, 1));
		}
	else {
		print &ui_hidden("omode", 0);
		}
	}

print &ui_hidden_table_end();

# Type-specific limit options
$afunc = "type_".$in{'type'}."_limits_create_form";
if (defined(&$afunc)) {
	print &ui_hidden_table_start($text{'create_lheader'}, "width=100%", 2,
				     "limits", 1, [ "width=30%" ]);
	print &$afunc(0);

	# Bandwidth limit
	$rfunc = "type_".$in{'type'}."_real_interfaces";
	if (defined(&$rfunc) && $config{'bw_enabled'} &&
	    &can_action(undef, "bw")) {
		$db = $config{'defbwlimit'} ?
			$config{'defbwlimit'}*1024*1024*1024 : undef;
		print &ui_table_row($text{'edit_lbw'},
			&ui_radio("bw_def", $db ? 0 : 1,
				  [ [ 1, $text{'bw_unlimited'} ],
				    [ 0, $text{'bw_setto'} ] ])."\n".
			&ui_bytesbox("bw", $db, 8)."\n".
			&describe_bandwidth_period(0));
		}

	# Disk image directory, if appropriate
	if (&indexof($in{'type'}, @diskfile_server_management_types) >= 0) {
		$sel = &directory_selector($in{'type'});
		if ($sel) {
			print &ui_table_row($text{'create_directory'}, $sel);
			}
		}

	print &ui_hidden_table_end();
	}

# Type-specific options
$ffunc = "type_".$in{'type'}."_create_form";
if (defined(&$ffunc)) {
	$nhtml = &ui_hidden_table_start($text{'create_nheader'}, "width=100%",
				        2, "net", 0, [ "width=30%" ]);
	$nbody = &$ffunc(0);
	$nhtml .= $nbody;
	$bfunc = "type_".$in{'type'}."_set_atboot";
	if ($nbody && defined(&$bfunc)) {
		# Enable at host boot time opton
		$nhtml .= &ui_table_row($text{'create_atboot'},
			&ui_yesno_radio("atboot", $config{'default_start'}));
		}
	$nhtml .= &ui_hidden_table_end();
	print $nhtml if ($nbody);
	}

# Type-specific advanced options
$afunc = "type_".$in{'type'}."_advanced_create_form";
if (defined(&$afunc) && &can_action(undef, "advanced")) {
	print &ui_hidden_table_start($text{'create_aheader'}, "width=100%", 2,
				     "advanced", 0, [ "width=30%" ]);
	print &$afunc(0);
	print &ui_hidden_table_end();
	}

# Start of section for Virtualmin options
if (&can_action(undef, "virtualmin")) {
	print &ui_hidden_table_start($text{'create_vheader'}, "width=100%", 2,
				     "virtualmin", 0, [ "width=30%" ]);

	# Virtualmin licence
	@proimages = grep { $_->{'virtualmin'} eq 'pro' } @images;
	if (@proimages) {
		print &ui_table_row($text{'create_vlicence'},
			&virtualmin_licence_form("licence", 0));
		}
	else {
		print &ui_hidden("licence", 0);
		}

	# Can add domains?
	print &ui_table_row($text{'add_canvirt'},
		&ui_yesno_radio("canvirt", 1));

	# Update Virtualmin package?
	print &ui_table_row($text{'create_update'},
		&ui_yesno_radio("update", 1));

	print &ui_hidden_table_end();
	}

print &ui_form_end([ [ undef, $text{'create_ok'} ] ]);

if ($empty) {
	# Show form for empty system creation, in a new tab
	print &ui_tabs_end_tab();

	print &ui_tabs_start_tab("mode", "empty");
	print $text{'create_descempty'},"<p>\n";

	print &ui_form_start("empty.cgi", "post");
	print &ui_hidden("type", $in{'type'});
	print &ui_hidden_table_start($text{'create_header2'}, "width=100%", 2,
				     "main2", 1, [ "width=30%" ]);

	# Type of system
	$tfunc = "type_".$in{'type'}."_desc";
	print &ui_table_row($text{'add_type'}, &$tfunc());

	# Hostname
	print &ui_table_row($text{'create_host'},
			    &ui_textbox("host", undef, 40));

	# Description
	print &ui_table_row($text{'add_desc'},
		&ui_textbox("desc", undef, 60));

	# In groups
	if (&can_action($server, "groups")) {
		print &ui_table_row($text{'edit_groups'},
			&show_groups_form($server, \@servers));
		}

	# CD image or file (on host)
	if ($empty != 2) {
		@images = &list_server_images($in{'type'});
		@images = grep { &can_image($_) && $_->{'format'} eq 'cd' }
			       @images;
		@opts = ( );
		if (@images) {
			push(@opts, [ 0, $text{'create_cdimage'},
			      &ui_select("image", undef,
				[ map { [ $_->{'id'}, $_->{'desc'} ] }
				 sort { lc($a->{'desc'}) cmp lc($b->{'desc'}) }
				   @images ]) ]);
			}
		if (&can_action(undef, "global")) {
			$chooser = $module_info{'onehost'} ?
				&file_chooser_button("file", 0, 1) : "";
			push(@opts, [ 1, $text{'create_cdfile'},
				      &ui_textbox("file", undef, 40).
				      $chooser ]);
			}
		if (@opts > 1) {
			print &ui_table_row($text{'create_cd'},
				    &ui_radio_table("cdmode", 0, \@opts));
			}
		elsif (@opts > 0) {
			print &ui_table_row($text{'create_cd'},
				$opts[0]->[1]." ".$opts[0]->[2]);
			print &ui_hidden("cdmode", $opts[0]->[0]);
			}
		else {
			print &ui_table_row($text{'create_cd'},
				"<font color=red>$text{'create_nocd'}</font>");
			}
		}

	# Owner, if any
	@owners = defined(&list_system_owners) ? &list_system_owners() : ( );
	if (!$access{'owner'} && scalar(@owners)) {
		@owners = sort { $a->{'name'} cmp $b->{'name'} } @owners;
		print &ui_table_row($text{'create_owner'},
			&ui_select("owner", undef,
				   [ [ '', "&lt;$text{'create_noowner'}&gt;" ],
				     map { $_->{'name'} } @owners ]));
		}
	print &ui_hidden_table_end();

	# Type-specific limit options
	$afunc = "type_".$in{'type'}."_limits_create_form";
	if (defined(&$afunc)) {
		print &ui_hidden_table_start($text{'create_lheader'},
					     "width=100%", 2,
					     "limits2", 1, [ "width=30%" ]);
		print &$afunc(1);

		# Disk image directory, if appropriate
		if (&indexof($in{'type'},
			     @diskfile_server_management_types) >= 0) {
			$sel = &directory_selector($in{'type'});
			if ($sel) {
				print &ui_table_row(
					$text{'create_directory'}, $sel);
				}
			}

		print &ui_hidden_table_end();
		}

	# Type-specific options
	$ffunc = "type_".$in{'type'}."_create_form";
	if (defined(&$ffunc)) {
		$nhtml = &ui_hidden_table_start($text{'create_nheader'},
					     "width=100%", 2,
					     "net2", 0, [ "width=30%" ]);
		$nbody = &$ffunc(1);
		$nhtml .= $nbody;
		$bfunc = "type_".$in{'type'}."_set_atboot";
		if ($nbody && defined(&$bfunc)) {
			# Enable at host boot time opton
			$nhtml .= &ui_table_row($text{'create_atboot'},
				&ui_yesno_radio("atboot",
						$config{'default_start'}));
			}
		$nhtml .= &ui_hidden_table_end();
		print $nhtml if ($nbody);
		}

	# Type-specific advanced options
	$afunc = "type_".$in{'type'}."_advanced_create_form";
	if (defined(&$afunc) && &can_action(undef, "advanced")) {
		print &ui_hidden_table_start($text{'create_aheader'},
					     "width=100%", 2,
					     "advanced2", 0, [ "width=30%" ]);
		print &$afunc(1);
		print &ui_hidden_table_end();
		}

	print &ui_form_end([ [ undef, $text{'create_ok'} ] ]);

	print &ui_tabs_end_tab();
	print &ui_tabs_end(1);
	}

&ui_print_footer("", $text{'index_return'});

