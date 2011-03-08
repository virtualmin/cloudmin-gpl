#!/usr/local/bin/perl
# Perform some operation on multiple servers at once (delete, reregister,
# refresh status)

require './server-manager-lib.pl';
&ReadParse();
%d = map { $_, 1 } split(/\0/, $in{'d'});
@servers = grep { $d{$_->{'id'}} } &list_managed_servers();
@servers || &error($text{'mass_enone'});
$ids = join("&", map { "d=".$_ } keys %d);
$s0 = $servers[0]->{'host'};

# Identify parent and virtual systems
@pservers = grep { !&is_virtual_server($_) } @servers;
@oservers = grep { &is_virtual_server($_) } @servers;
@hostnames = map { $_->{'host'} } @servers;

if ($in{'refresh'}) {
	# Fetch the status of selected servers, in 10 processes
	&can_action_error(\@servers, "refresh");
	&ui_print_header(undef, $text{'mass_ftitle'}, "");
	$override_webmin_script_type = 'status';

	if (@servers == 1) {
		print &text('mass_fdoing2', "<tt>$s0</tt>"),"<br>\n";
		}
	else {
		print &text('mass_fdoing', scalar(@servers)),"<br>\n";
		}
	print "<ul>\n";
	&obtain_lock_server(\@servers);
	@prv = &parallel_check_server_status(\@pservers, 0);
	@orv = &parallel_check_server_status(\@oservers, 0);
	&release_lock_server(\@servers);

	# Show new statuses
	@rv = ( @prv, @orv );
	@aservers = ( @pservers, @oservers );
	for($i=0; $i<@rv; $i++) {
		$s = $aservers[$i];
		($s->{'status'}, $s->{'status_msg'},
		 $s->{'virtualmin_domains'},
		 $s->{'virtualmin_error'}) = @{$rv[$i]};
		print $s->{'host'}," : ",&describe_status($s, 1, 1),"<br>\n";
		}
	print "</ul>\n";
	print $text{'mass_fdone'},"<p>\n";

	if (defined(&theme_post_save_server)) {
		&theme_post_save_server();
		&theme_select_server($aservers[0]) if (@aservers == 1);
		}
	&webmin_log("refresh", "servers", scalar(@servers),
		    { 'hosts' => \@hostnames });

	&ui_print_footer($in{'referer'} || $ENV{'HTTP_REFERER'},
			 $text{'index_return'});
	}

elsif ($in{'delete'}) {
	# Delete the selected servers (virtual only)
	&can_action_error(\@servers, "delete");
	&error_setup($text{'mass_derr'});

	# Check if servers cannot be deleted
	@cannot = ( );
	foreach $s (@servers) {
		if ($s->{'manager'} eq 'real' || $s->{'manager'} eq 'this') {
			push(@cannot, $s);
			}
		}
	if (@cannot) {
		&error(&text('mass_ereal',
			join(" ", map { "<tt>$_->{'host'}</tt>" } @cannot)));
		}

	# Check for dependencies
	@deps = &find_server_dependencies(@servers);
	if (@deps) {
		&error(&text('mass_edeps',
			join(" ", map { "<tt>$_->{'host'}</tt>" } @deps)));
		}

	&ui_print_unbuffered_header(undef, $text{'mass_dtitle'}, "");
	if (!$in{'confirm'}) {
		# Ask the user if he is sure
		print "<center>\n";
		print &ui_form_start("mass.cgi", "post");
		print &ui_hidden("delete", 1);
		print &ui_hidden("referer", $ENV{'HTTP_REFERER'});
		foreach $s (@servers) {
			print &ui_hidden("d", $s->{'id'});
			}
		print $text{'mass_drusre'},"<p>\n";
		print "<table>\n";
		foreach $s (@servers) {
			$tfunc = "type_".$s->{'manager'}."_desc";
			@sdoms = &get_server_domains($s);
			print "<tr>\n";
			print "<td><tt>$s->{'host'}</tt></td>\n";
			print "<td>&nbsp;</td>\n";
			print "<td>(",&$tfunc(),")</td>\n";
			if (@servers > 1) {
				print "<td>",@sdoms ? &text('mass_ddoms',
					scalar(@sdoms)) : undef,"</td>\n";
				}
			print "</tr>\n";
			$dtotal += scalar(@sdoms);
			}
		print "</table>\n";
		if ($dtotal) {
			print "<b><font size=+2>",
			      &text('mass_ddeldoms', $dtotal),
			      "</font></b><p>\n";
			}

		# Ask if disks should be kept, if appropriate
		$anydisks = 0;
		foreach $s (@servers) {
			$cfunc = "type_".$s->{'manager'}."_can_disks";
			$anydisks++ if (defined(&$cfunc) && &$cfunc($s));
			}
		if (&can_action(\@servers, "devices") && $anydisks) {
		        print &ui_checkbox("keep", 1, $text{'save_deletekeep'},
					   0),"<p>\n";
			}

		print &ui_form_end([ [ "confirm", $text{'mass_dok'} ] ]);
		print "</center>\n";
		}
	else {
		# Do it for real
		&obtain_lock_server(\@servers);
		foreach $s (@servers) {
			# Run pre-deletion script
			&run_system_script($s, 'before', 'delete') || next;

			$tfunc = "type_".$s->{'manager'}."_desc";
			print &text('mass_deleting', &$tfunc(),
				    "<tt>$s->{'host'}</tt>"),"<br>\n";
			$dfunc = "type_".$s->{'manager'}."_delete";
			$err = &$dfunc($s,
				&can_action($s, "devices") && $in{'keep'});
			if ($err) {
				print &text('mass_edelete', $err),"<p>\n";
				}
			else {
				print $text{'mass_deleted'},"<p>\n";
				&clear_ssh_host_key($s);
				&delete_managed_server($s);

				# Run post-deletion script
				&run_system_script($s, 'after', 'delete');

				$vhost = &get_parent_server($server);
				$newdef ||= $vhost;
				}
			}
		$newdef ||= &get_managed_server(0);
		if (defined(&theme_select_server) && $newdef) {
			&theme_select_server($newdef);
			}
		&release_lock_server(\@servers);
		&webmin_log("delete", "servers", scalar(@servers),
			    { 'hosts' => \@hostnames });
		}
	&ui_print_footer($in{'referer'} || $ENV{'HTTP_REFERER'},
			 $text{'index_return'});
	}

elsif ($in{'dereg'}) {
	# Removing from managed servers list
	&can_action_error(\@servers, "dereg");
	&error_setup($text{'mass_uerr'});

	# Check for dependencies
	@deps = &find_server_dependencies(@servers);
	if (@deps) {
		&error(&text('mass_edeps',
			join(" ", map { "<tt>$_->{'host'}</tt>" } @deps)));
		}

	&ui_print_unbuffered_header(undef, $text{'mass_rtitle'}, "");
	if (!$in{'confirm'}) {
		# Ask the user if he is sure
		print "<center>\n";
		print &ui_form_start("mass.cgi", "post");
		print &ui_hidden("dereg", 1);
		print &ui_hidden("referer", $ENV{'HTTP_REFERER'});
		foreach $s (@servers) {
			print &ui_hidden("d", $s->{'id'});
			}
		print &text('mass_rrusre', scalar(@servers)),"<p>\n";
		print &ui_form_end([ [ "confirm", $text{'mass_rok'} ] ]);
		print "</center>\n";
		}
	else {
		# Do it for real
		print $text{'mass_rdoing'},"<br>\n";
		&obtain_lock_server(\@servers);
		foreach $s (@servers) {
			&delete_managed_server($s);
			}
		print $text{'mass_rdone'},"<p>\n";
		if (defined(&theme_post_save_server)) {
			&theme_post_save_server($server);
			}
		&release_lock_server(\@servers);
		&webmin_log("dereg", "servers", scalar(@servers),
			    { 'hosts' => \@hostnames });
		}
	&ui_print_footer($in{'referer'} || $ENV{'HTTP_REFERER'},
			 $text{'index_return'});
	}

elsif ($in{'update'}) {
	&redirect("mass_update_form.cgi?$ids");
	}

elsif ($in{'script'}) {
	# Show a form for updating scripts from multiple systems
	&can_action_error(\@servers, "script");
	&ui_print_unbuffered_header(undef, $text{'mass_sctitle'}, "");

	# Find available updates across systems
	print &text('mass_scgetting', scalar(@servers)),"<br>\n";
	@updates = &list_all_script_updates(\@servers);

	# Show a table of them, by script
	if (@updates) {
		@scripts = &unique(map { $_->{'script'}->{'name'}."/".
					 $_->{'ver'} } @updates);
		print $text{'mass_scdone'},"<p>\n";
		print &ui_form_start("mass_script.cgi", "post");
		@links = ( &select_all_link("d"), &select_invert_link("d") );
		@tds = ( "width=5", "width=20%", "width=10%", "width=10%",
			 "width=60%" );
		print &ui_links_row(\@links);
		print &ui_columns_start([ "",
					  $text{'mass_scname'},
					  $text{'mass_scver'},
					  $text{'mass_scnewver'},
					  $text{'mass_scdoms'} ], 100, 1,\@tds);
		foreach my $namever (@scripts) {
			($name, $ver) = split(/\//, $namever);
			@thisname = grep { $_->{'script'}->{'name'} eq $name &&
					   $_->{'ver'} eq $ver } @updates;
			@vers = &unique(map { $_->{'sinfo'}->{'version'} }
					    @thisname);
			@doms = &unique(map { $_->{'dom'}->{'dom'} } @thisname);
			$doms = @doms > 4 ?
				&text('mass_manydoms', scalar(@doms)) :
				join(" , ", @doms);
			print &ui_checked_columns_row([
				$thisname[0]->{'script'}->{'desc'},
				join(", ", @vers),
				$ver,
				$doms,
				], \@tds, "d", $namever);
			foreach $u (@thisname) {
				print &ui_hidden("on_$namever",
					$u->{'server'}->{'id'});
				}	
			}
		print &ui_columns_end();
		print &ui_links_row(\@links);
		print &ui_form_end([ [ undef, $text{'mass_scok'} ] ]);
		}
	else {
		print $text{'mass_scnone'},"<p>\n";
		}

	&ui_print_footer($in{'referer'} || $ENV{'HTTP_REFERER'},
			 $text{'index_return'});
	}

elsif ($in{'shutdown'}) {
	# Shutdown the selected servers
	&error_setup($text{'mass_shuterr'});
	&can_action_error(\@servers, "shutdown");

	# Check if servers cannot be shut down
	@cannot = ( );
	foreach $s (@servers) {
		if ($s->{'status'} eq 'down' || $s->{'status'} eq 'nohost') {
			push(@cannot, $s);
			}
		$sfunc = "type_".$s->{'manager'}."_no_shutdown";
		if (defined(&$sfunc) && &$sfunc($s)) {
			push(@cannot, $s);
			}
		}
	if (@cannot) {
		&error(&text('mass_eshut',
			join(" ", map { "<tt>$_->{'host'}</tt>" } @cannot)));
		}

	&ui_print_unbuffered_header(undef, $text{'mass_shuttitle'}, "");
	if (!$in{'confirm'}) {
		# Ask the user if he is sure
		print "<center>\n";
		print &ui_form_start("mass.cgi", "post");
		print &ui_hidden("shutdown", 1);
		print &ui_hidden("referer", $ENV{'HTTP_REFERER'});
		foreach $s (@servers) {
			print &ui_hidden("d", $s->{'id'});
			}
		print $text{'mass_shutrusre'},"<p>\n";
		print "<table>\n";
		foreach $s (@servers) {
			$tfunc = "type_".$s->{'manager'}."_desc";
			@sdoms = &get_server_domains($s);
			print "<tr>\n";
			print "<td><tt>$s->{'host'}</tt></td>\n";
			print "<td>&nbsp;</td>\n";
			print "<td>(",&$tfunc(),")</td>\n";
			print "<td>&nbsp;</td>\n";
			print "<td>",@sdoms ? &text('mass_ddoms',
					scalar(@sdoms)) : undef,"</td>\n";
			print "</tr>\n";
			$dtotal += scalar(@sdoms);
			}
		print "</table>\n";
		print &ui_form_end([ [ "confirm", $text{'mass_shutok'} ] ]);
		print "</center>\n";
		}
	else {
		# Do it for real, in parallel. Virtual systems are done first.
		if (@servers == 1) {
			print &text('mass_shutting2', "<tt>$s0</tt>"),"<br>\n";
			}
		else {
			print &text('mass_shutting', scalar(@servers)),"<br>\n";
			}
		&obtain_lock_server(\@servers);
		foreach my $sl (\@oservers, \@pservers) {
			&parallel_server_function($sl,
				sub { $err = &shutdown_server($_[0]);
				      &check_server_status($_[0], 0, 1);
				      &refresh_server_usage($_[0]);
				      &save_managed_server($_[0]) });
			}
		print $text{'mass_shutted'},"<p>\n";
		foreach my $s (@servers) {
			if (defined(&theme_post_save_server)) {
				&theme_post_save_server($s);
				}
			}
		&theme_select_server($servers[0]) if (@servers == 1 &&
						defined(&theme_select_server));
		&release_lock_server(\@servers);
		&webmin_log("shutdown", "servers", scalar(@servers),
			    { 'hosts' => \@hostnames });
		}
	&ui_print_footer($in{'referer'} || $ENV{'HTTP_REFERER'},
			 $text{'index_return'});
	}

elsif ($in{'startup'}) {
	# Start up the selected servers
	&error_setup($text{'mass_starterr'});
	&can_action_error(\@servers, "startup");

	# Check if servers cannot be started up
	@cannot = ( );
	foreach $s (@servers) {
		if ($s->{'status'} ne 'down' && $s->{'status'} ne 'nossh') {
			push(@cannot, $s);
			}
		$sfunc = "type_".$s->{'manager'}."_no_startup";
		if (defined(&$sfunc) && &$sfunc($s)) {
			push(@cannot, $s);
			}
		}
	if (@cannot) {
		&error(&text('mass_estart',
			join(" ", map { "<tt>$_->{'host'}</tt>" } @cannot)));
		}

	&ui_print_unbuffered_header(undef, $text{'mass_starttitle'}, "");

	# Do the startup, in parallel. Real systems are done first.
	if (@servers == 1) {
		print &text('mass_starting2', "<tt>$s0</tt>"),"<br>\n";
		}
	else {
		print &text('mass_starting', scalar(@servers)),"<br>\n";
		}
	&obtain_lock_server(\@servers);
	foreach my $sl (\@pservers, \@oservers) {
		&parallel_server_function($sl,
			sub { ($ok, $err) = &startup_server($_[0]);
			      &check_server_status($_[0], 0, 1);
			      &refresh_server_usage($_[0]);
			      &save_managed_server($_[0]) });
		}
	print $text{'mass_started'},"<p>\n";
	foreach my $s (@servers) {
		if (defined(&theme_post_save_server)) {
			&theme_post_save_server($s);
			}
		}
	&theme_select_server($servers[0]) if (@servers == 1 &&
					      defined(&theme_select_server));
	&release_lock_server(\@servers);
	&webmin_log("startup", "servers", scalar(@servers),
		    { 'hosts' => \@hostnames });

	&ui_print_footer($in{'referer'} || $ENV{'HTTP_REFERER'},
			 $text{'index_return'});
	}

elsif ($in{'reboot'}) {
	# Reboot the selected servers
	&error_setup($text{'mass_rebooterr'});
	&can_action_error(\@servers, "reboot");

	&ui_print_unbuffered_header(undef, $text{'mass_reboottitle'}, "");
	if (!$in{'confirm'}) {
		# Ask the user if he is sure
		print "<center>\n";
		print &ui_form_start("mass.cgi", "post");
		print &ui_hidden("reboot", 1);
		print &ui_hidden("referer", $ENV{'HTTP_REFERER'});
		foreach $s (@servers) {
			print &ui_hidden("d", $s->{'id'});
			}
		print $text{'mass_rebootrusre'},"<p>\n";
		print "<table>\n";
		foreach $s (@servers) {
			$tfunc = "type_".$s->{'manager'}."_desc";
			@sdoms = &get_server_domains($s);
			print "<tr>\n";
			print "<td><tt>$s->{'host'}</tt></td>\n";
			print "<td>(",&$tfunc(),")</td>\n";
			print "<td>",@sdoms ? &text('mass_ddoms',
					scalar(@sdoms)) : undef,"</td>\n";
			print "</tr>\n";
			$dtotal += scalar(@sdoms);
			}
		print "</table>\n";
		print &ui_form_end([ [ "confirm", $text{'mass_rebootok'} ] ]);
		print "</center>\n";
		}
	else {
		# Do it for real, in parallel. Virtual systems are done first.
		if (@servers == 1) {
			print &text('mass_rebooting2', "<tt>$s0</tt>"),"<br>\n";
			}
		else {
			print &text('mass_rebooting',scalar(@servers)),"<br>\n";
			}
		&obtain_lock_server(\@servers);
		foreach my $sl (\@oservers, \@pservers) {
			&parallel_server_function($sl,
				sub { $err = &reboot_server($_[0]);
				      &save_managed_server($_[0]) });
			}
		print $text{'mass_rebooted'},"<p>\n";
		foreach my $s (@servers) {
			if (defined(&theme_post_save_server)) {
				&theme_post_save_server($s);
				}
			}
		&theme_select_server($servers[0]) if (@servers == 1 &&
						defined(&theme_select_server));
		&release_lock_server(\@servers);
		&webmin_log("reboot", "servers", scalar(@servers),
			    { 'hosts' => \@hostnames });
		}
	&ui_print_footer($in{'referer'} || $ENV{'HTTP_REFERER'},
			 $text{'index_return'});
	}

elsif ($in{'upload'}) {
	# Redirect to mass upload form
	&redirect("massupload_form.cgi?$ids");
	}

elsif ($in{'run'}) {
	# Redirect to mass shell form
	&redirect("massshell.cgi?$ids");
	}

else {
	&error($text{'mass_ebutton'});
	}

