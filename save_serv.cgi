#!/usr/local/bin/perl
# Either update the details of some server, or perform some action

require './server-manager-lib.pl';
&error_if_cloudmin_replica();
&ReadParse();
$server = &get_managed_server($in{'id'});
$server || &error($text{'edit_egone'});
$t = $server->{'manager'};
$oldserver = { %$server };

if ($in{'shutdown'}) {
	# Shut down this system, after asking for confirmation
	&can_action_error($server, "shutdown");
	&ui_print_header(&server_in($server), $text{'save_shuttitle'}, "");
	if (!$in{'confirm'}) {
		&show_confirm_form(
			&text('save_shutrusure', "<tt>$server->{'host'}</tt>").
			"<br>\n".
			(&is_virtual_server() ?
			  &ui_checkbox("force", 1, $text{'save_shutforce'}, 0) :
			  ""),
			"save_serv.cgi", [ [ "id", $in{'id'} ],
					   [ "shutdown", 1 ] ],
			$text{'save_shutok'});
		}
	else {
		&obtain_lock_server($server);
		&start_background_dot_printer(&text('save_shutting',
			    "<tt>$server->{'host'}</tt>"));
		$err = &shutdown_server($server, $in{'force'});
		if ($err) {
			&stop_background_dot_printer();
			&$second_print(&text('save_shutfailed', $err));
			}
		else {
			&check_server_status($server, 0, 1);
			&refresh_server_usage($server);
			&save_managed_server($server);
			&stop_background_dot_printer();
			&$second_print($text{'save_shutdone'});
			if (defined(&theme_post_save_server)) {
				&theme_post_save_server($server);
				}
			}
		&release_lock_server($server);
		&webmin_log("shutdown", "server", $server->{'host'});
		}
	&ui_print_footer("edit_serv.cgi?id=$in{'id'}", $text{'edit_return'});
	}

elsif ($in{'startup'}) {
	# Start up this virtual system, after asking for the mode
	&can_action_error($server, "startup");
	&ui_print_header(&server_in($server), $text{'save_starttitle'}, "");
	if (!$in{'confirm'}) {
		&show_confirm_form(
			&text('save_startrusure', "<tt>$server->{'host'}</tt>").
			"<br>\n".
			($server->{'ssh_nologin'} ? "" :
			  &ui_checkbox("wait", 1, $text{'save_startwait'}, 1)),
			"save_serv.cgi", [ [ "id", $in{'id'} ],
					   [ "startup", 1 ] ],
			$text{'save_startok'});
		}
	else {
		&obtain_lock_server($server);
		&start_background_dot_printer(&text('save_starting',
			    "<tt>$server->{'host'}</tt>"));
		($ok, $err) = &startup_server($server, !$in{'wait'});
		if (!$ok) {
			&stop_background_dot_printer();
			&$second_print(&text('save_startfailed', $err));
			&save_managed_server($server);
			}
		else {
			&check_server_status($server, 0, 1);
			&refresh_server_usage($server);
			&save_managed_server($server);
			&stop_background_dot_printer();
			if ($ok == 1) {
				&$second_print($text{'save_startdone'});
				}
			else {
				&$second_print(&text('save_startmaybe', $err));
				}
			if (defined(&theme_post_save_server)) {
				&theme_post_save_server($server);
				}
			}
		&release_lock_server($server);
		&webmin_log("startup", "server", $server->{'host'});
		}
	&ui_print_footer("edit_serv.cgi?id=$in{'id'}", $text{'edit_return'});
	}

elsif ($in{'reboot'}) {
	# Request a reboot, after asking for confirmation
	&can_action_error($server, "reboot");
	&ui_print_header(&server_in($server), $text{'save_reboottitle'}, "");
	&obtain_lock_server($server);
	if (!$in{'confirm'}) {
		&show_confirm_form(
		    &text('save_rebootrusure', "<tt>$server->{'host'}</tt>"),
		    "save_serv.cgi", [ [ "id", $in{'id'} ],
				       [ "reboot", 1 ] ],
		    $text{'save_rebootok'});
		}
	elsif ($in{'updown'}) {
		# Take down and start up again
		print &text('save_shutting',
			    "<tt>$server->{'host'}</tt>"),"<br>\n";
		$err = &shutdown_server($server);
		if ($err) {
			print &text('save_shutfailed', $err),"<p>\n";
			}
		else {
			print $text{'save_shutdone'},"<p>\n";

			print &text('save_starting',
				    "<tt>$server->{'host'}</tt>"),"<br>\n";
			($ok, $err) = &startup_server($server);
			if (!$ok) {
				print &text('save_startfailed', $err),"<p>\n";
				}
			else {
				print $text{'save_startdone'},"<p>\n";
				}
			}
		&refresh_server_usage($server);
		}
	else {
		# Just reboot
		print &text('save_rebooting',
			    "<tt>$server->{'host'}</tt>"),"<br>\n";
		$err = &reboot_server($server);
		if ($err) {
			print &text('save_rebootfailed', $err),"<p>\n";
			}
		else {
			print $text{'save_rebootdone'},"<p>\n";
			}
		}
	&check_server_status($server, 0, 1);
	if (defined(&theme_post_save_server)) {
		&theme_post_save_server($server);
		}
	&save_managed_server($server);
	&release_lock_server($server);
	if ($in{'confirm'}) {
		&webmin_log("reboot", "server", $server->{'host'});
		}
	&ui_print_footer("edit_serv.cgi?id=$in{'id'}", $text{'edit_return'});
	}

elsif ($in{'delete'}) {
	# Delete system, after asking for confirmation
	&can_action_error($server, "delete");

	# Check if server can be deleted
	if ($s->{'manager'} eq 'real' || $s->{'manager'} eq 'this') {
		&error($text{'save_edeletemanager'});
		}
	@deps = &find_server_dependencies($server);
	if (@deps) {
		&error(&text('save_edeletedeps',
			join(" ", map { "<tt>$_->{'host'}</tt>" } @deps)));
		}

	&ui_print_header(&server_in($server), $text{'save_deletetitle'}, "");
	if (!$in{'confirm'}) {
		@doms = &get_server_domains($server);
		$cfunc = "type_".$server->{'manager'}."_can_disks";
		$kfunc = "type_".$server->{'manager'}."_can_keep";
		$cankeep =  defined(&$cfunc) && &$cfunc($server) ||
			     defined(&$kfunc) && &$kfunc($server);
		&show_confirm_form(
		    &text('save_deleterusure', "<tt>$server->{'host'}</tt>").
		    (@doms ? "<p>".&text('save_deleterusure2',
					 scalar(@doms)) : "").
		    (&can_action($server, "devices") && $cankeep ?
		        "<p>".&ui_checkbox("keep", 1,
					   $text{'save_deletekeep'}, 0) : ""),
		    "save_serv.cgi", [ [ "id", $in{'id'} ],
				       [ "delete", 1 ] ],
		    $text{'save_deleteok'});
		}
	else {
		# Run pre-deletion script
		&obtain_lock_server($server);
		&run_system_script($server, 'before', 'delete') || goto FAILED;

		&delete_all_domains($server);

		print &text('save_deleteing',
			    "<tt>$server->{'host'}</tt>"),"<br>\n";
		$dfunc = "type_".$server->{'manager'}."_delete";
		$err = &$dfunc($server,
			       &can_action($server, "devices") && $in{'keep'});
		if ($err) {
			print &text('save_deletefailed', $err),"<p>\n";
			}
		else {
			&clear_ssh_host_key($server);
			&delete_managed_server($server);
			print $text{'save_deletedone'},"<p>\n";

			# Run post-deletion script
			&run_system_script($server, 'after', 'delete');

			$newdef = &get_parent_server($server) ||
				  &get_managed_server(0);
			if (defined(&theme_select_server) && $newdef) {
				&theme_select_server($newdef);
				}
			}
		FAILED:
		&release_lock_server($server);
		&webmin_log("delete", "server", $server->{'host'});
		}
	&ui_print_footer("edit_serv.cgi?id=$in{'id'}", $text{'edit_return'});
	}

elsif ($in{'installvirt'}) {
	# Install Virtualmin, which may take a while
	&can_action_error($server, "virtualmin");
	&ui_print_header(&server_in($server), $text{'save_virttitle'}, "");

	if (!$in{'confirm'}) {
		# Ask first
		$vlform = &ui_table_start($text{'virtualmin_lheader'},undef, 2);
		$vlform .= &ui_table_row($text{'virtualmin_lfrom'},
				&virtualmin_licence_form("licence", 1, 1));
		$vlform .= &ui_table_end();
		&show_confirm_form(
		    &text('save_virtrusure', "<tt>$server->{'host'}</tt>").
		    "<br>".$vlform,
		    "save_serv.cgi", [ [ "id", $in{'id'} ],
				       [ "installvirt", 1 ] ],
		    $text{'save_virtok'});
		}
	else {
		# Parse licence inputs
		($serial, $key) = &virtualmin_licence_parse("licence", \%in);
		$serial || &error($key);

		# Start off the process
		print $text{'save_virtstart'},"<br>\n";
		&obtain_lock_server($server);
	        &start_installing_virtualmin_licence($serial, $key);
		$err = &install_virtualmin_server($server, 1, $serial, $key);
		if ($err) {
			print &text('save_virterr', $err),"<p>\n";
			goto VIRTFAILED;
			}
		else {
			print $text{'save_virtstarted'},"<p>\n";
			}

		# Wait till done
		print $text{'save_virtwait'};
		$dot_count = 0;
		while(1) {
			sleep(1);
			$done = &install_virtualmin_server_done($server);
			if ($done eq "OK") {
				print "<br>",$text{'save_virtdone'},"<p>\n";
				last;
				}
			elsif ($done) {
				print "<br>",&text('save_virterr',
						   $done),"<p>\n";
				last;
				}
			else {
				print ".";
				print "\n" if (++$dot_count % 80 == 0);
				}
			}
	        &stop_installing_virtualmin_licence($serial, $key);

		# Update server status
		print $text{'dcreate_statusing'},"<br>\n";
		&check_server_status($server);
		&save_managed_server($server);
		print $text{'dcreate_statusok'},"<p>\n";
		&webmin_log("virt", "server", $server->{'host'});

		if (defined(&theme_post_save_server)) {
			&theme_post_save_server($server);
			}

		VIRTFAILED:
		&release_lock_server($server);
		}
	&ui_print_footer("edit_serv.cgi?id=$in{'id'}", $text{'edit_return'});
	}

elsif ($in{'installwebmin'}) {
	# Install Webmin
	&can_action_error($server, "webmin");
	&ui_print_header(&server_in($server), $text{'save_webmintitle'}, "");

	($src, $type, $err) = &get_install_webmin_source($server);
	$err && &error(&text('save_webminerr', $err));

	if (!$in{'confirm'}) {
		# Ask first
		&show_confirm_form(
		    &text('save_webminrusure', "<tt>$server->{'host'}</tt>"),
		    "save_serv.cgi", [ [ "id", $in{'id'} ],
				       [ "installwebmin", 1 ] ],
		    $text{'save_webminok'});
		}
	else {
		# Do it
		print &text('save_webmining', "<tt>$server->{'host'}</tt>",
			    $src =~ /:/ ? "<tt>$src</tt>" : uc($src)),"<br>\n";
		($out, $err) = &install_webmin_server($server, $src, $type, 1);
		print "<pre>$out</pre>";
		if ($err) {
			print &text('save_webminfailed', $err),"<p>\n";
			}
		else {
			&obtain_lock_server($server);
			&check_server_status($server);
			&save_managed_server($server);
			&release_lock_server($server);
			print $text{'save_webmindone'},"<p>\n";

			if (defined(&theme_post_save_server)) {
				&theme_post_save_server($server);
				}
			}
		&webmin_log("webmin", "server", $server->{'host'});
		}

	&ui_print_footer("edit_serv.cgi?id=$in{'id'}", $text{'edit_return'});
	}

elsif ($in{'recheck'}) {
	# Perform a config re-check
	&can_action_error($server, "refresh");
	&ui_print_header(&server_in($server), $text{'save_rechecktitle'}, "");
	&obtain_lock_server($server);

	print $text{'save_rechecking'},"<br>\n";
	&remote_foreign_require($server, "virtual-server",
					 "virtual-server-lib.pl");
	($out, $cerrarr) = &remote_foreign_call($server, "virtual-server",
		"capture_function_output",
		"virtual_server::check_virtual_server_config");
	print $out;
	$cerr = $cerrarr->[0];
	$cerr =~ s/<[^>]*>//g;  # Remove HTML
	if ($cerr) {
		print "<font color=#ff0000>",
		      &text('save_recheckerr', $cerr),"</font><p>\n";
		}
	else {
		print $text{'save_recheckdone'},"<p>\n";
		}
	$server->{'virtualmin_checked'} = $cerr ? 0 : 1;
	$server->{'virtualmin_error'} = $cerr;
	&save_managed_server($server);

	if (defined(&theme_post_save_server)) {
		&theme_post_save_server($server);
		}
	&release_lock_server($server);
	&webmin_log("recheck", "server", $server->{'host'});

	&ui_print_footer("edit_serv.cgi?id=$in{'id'}", $text{'edit_return'});
	}

elsif ($in{'refresh'} || $in{'regen'}) {
	# Refresh monitored status
	&can_action_error($server, "refresh");
	&ui_print_header(&server_in($server), $text{'save_refreshtitle'}, "");
	&obtain_lock_server($server);
	$override_webmin_script_type = 'status';

	print $in{'regen'} ? $text{'save_refreshing2'}
			   : $text{'save_refreshing'};
	print "<br>\n";
	&check_server_status($server, $in{'regen'} ? 1 : 0);
	&save_managed_server($server);
	print &text('save_refreshdone2',
		    describe_status($server, 1, 1)),"<p>\n";

	if (defined(&theme_post_save_server)) {
		&theme_post_save_server($server);
		}
	&release_lock_server($server);
	&webmin_log($in{'regen'} ? "regen" : "refresh",
		    "server", $server->{'host'});

	&ui_print_footer("edit_serv.cgi?id=$in{'id'}", $text{'edit_return'});
	}

elsif ($in{'shell'}) {
	# Go to shell page
	&redirect("shell.cgi?id=$in{'id'}");
	}

elsif ($in{'webmin'}) {
	# Go to Webmin
	&redirect(&webmin_link($server));
	}

elsif ($in{'pass'}) {
	# Go to password change page
	&redirect("edit_pass.cgi?id=$in{'id'}");
	}

elsif ($in{'image'}) {
	# Go to image creation form
	&redirect("image_form.cgi?id=$in{'id'}");
	}

elsif ($in{'transfer'}) {
	# Go to file transfer form
	&redirect("transfer_form.cgi?id=$in{'id'}");
	}

elsif ($in{'disks'}) {
	# Go to disk management form
	&redirect("list_disks.cgi?id=$in{'id'}");
	}

elsif ($in{'vcpus'}) {
	# Go to disk management form
	&redirect("list_vcpus.cgi?id=$in{'id'}");
	}

elsif ($in{'bw'}) {
	# Go to system's bandwidth graph
	&redirect("bwgraph.cgi?id=$in{'id'}");
	}

else {
	# Validate inputs, and save details
	&error_setup($text{'save_err'});
	&can_action($server, "edit");
	&obtain_lock_server($server);
	if ($server->{'id'} != 0) {
		$oldip = &to_ipaddress($server->{'host'});
		$newip = &to_ipaddress($in{'host'});
		if ($oldip && $oldip ne $newip && !$in{'confirm'}) {
			# IP mismatch .. but allow override
			&show_host_override_form($oldip, $newip);
			exit;
			}
		$server->{'host'} = $in{'host'};
		$server->{'desc'} = $in{'desc'};
		}
	if (defined($in{'ip_def'}) || defined($in{'ip'})) {
		# Validate custom IP
		if ($in{'ip_def'}) {
			delete($server->{'ip_force'});
			}
		else {
			&check_ipaddress($in{'ip'}) ||
				&error($text{'edit_eip'});
			$server->{'ip_force'} = $in{'ip'};
			}
		&complete_managed_server($server);	# To refresh 'ip' field
		}
	$server->{'type'} = $in{'type'};
	$in{'notes'} =~ s/\r//g;
	$server->{'notes'} = join("\t", split(/\n/, $in{'notes'}));
	if (&can_action($server, "groups")) {
		&parse_groups_form($server, \%in);
		}
	if (defined($in{'canvirt'})) {
		$server->{'novirt'} = $in{'canvirt'} ? 0 : 1;
		}

	# Save boot-time flag
	$bfunc = "type_".$t."_set_atboot";
	if (defined(&$bfunc) && $server->{'status'} ne 'nohost') {
		&$bfunc($server, $in{'atboot'});
		}

	# Save owner
	@allowners = &list_system_owners();
	if (@allowners && !$access{'owner'}) {
		# Take away from old owners
		foreach my $owner (&get_server_owners($server)) {
			&revoke_from_system_owner($owner, $server);
			}

		if ($in{'owner'}) {
			# Grant to selected owner
			my ($owner) = grep { $_->{'name'} eq $in{'owner'} }
					   @allowners;
			&grant_to_system_owner($owner, $server) if ($owner);
			}
		}

	# Save type-specific options
	$pfunc = "type_".$t."_edit_parse";
	if (defined(&$pfunc)) {
		&$pfunc($server, \%in);
		}

	# Call type-specific post-save function
	$psfunc = "type_".$t."_post_save";
	if (defined(&$psfunc)) {
		$err = &$psfunc($server, $oldserver);
		&error($err) if ($err);
		}

	# Re-check status if login mode has changed
	if ($oldserver->{'ssh_pass'} ne $server->{'ssh_pass'} ||
	    $oldserver->{'ssh_user'} ne $server->{'ssh_user'} ||
	    $oldserver->{'ssh_port'} != $server->{'ssh_port'} ||
	    $oldserver->{'key'} ne $server->{'key'} ||
	    $oldserver->{'user'} ne $server->{'user'} ||
	    $oldserver->{'pass'} ne $server->{'pass'} ||
	    $oldserver->{'port'} != $server->{'port'} ||
	    $oldserver->{'ssl'} != $server->{'ssl'} ||
	    $oldserver->{'ip_force'} != $server->{'ip_force'}) {
		&check_server_status($server);
		}

	&save_managed_server($server);
	&release_lock_server($server);
	&webmin_log("modify", "server", $server->{'host'});
	&redirect("index.cgi?refresh=$server->{'id'}");
	}

# show_host_override_form(oldip, newip)
# Tell the user that changing the IP may be a bad idea
sub show_host_override_form
{
my ($oldip, $newip) = @_;
&ui_print_header(&server_in($server), $text{'save_title'}, "");

print "<center>\n";
print &ui_form_start("save_serv.cgi", "post");
foreach my $i (keys %in) {
	foreach my $v (split(/\0/, $in{$i})) {
		print &ui_hidden($i, $v);
		}
	}
print &text('save_iprusure', "<tt>$server->{'host'}</tt>",
    "<tt>$in{'host'}</tt>", "<tt>$oldip</tt>", "<tt>$newip</tt>"),"<p>\n";
print &ui_form_end([ [ "confirm", $text{'save_ipok'} ] ]);
print "</center>\n";

&ui_print_footer("edit_serv.cgi?id=$in{'id'}", $text{'edit_return'});
}
