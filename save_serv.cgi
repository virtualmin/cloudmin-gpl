#!/usr/local/bin/perl
# Either update the details of some server, or perform some action

require './server-manager-lib.pl';
&ReadParse();
($server) = grep { $_->{'id'} == $in{'id'} } &list_managed_servers();
$server || &error($text{'edit_egone'});
$t = $server->{'manager'};

if ($in{'shutdown'}) {
	# Shut down this system, after asking for confirmation
	&can_action_error($server, "shutdown");
	&ui_print_header(&server_in($server), $text{'save_shuttitle'}, "");
	if (!$in{'confirm'}) {
		&show_confirm_form(
			&text('save_shutrusure', "<tt>$server->{'host'}</tt>").
			"<br>\n".
			&ui_checkbox("force", 1, $text{'save_shutforce'}, 0),
			"save_serv.cgi", [ [ "id", $in{'id'} ],
					   [ "shutdown", 1 ] ],
			$text{'save_shutok'});
		}
	else {
		print &text('save_shutting',
			    "<tt>$server->{'host'}</tt>"),"<br>\n";
		$err = &shutdown_server($server, $in{'force'});
		if ($err) {
			print &text('save_shutfailed', $err),"<p>\n";
			}
		else {
			#&check_server_status($server);
			$server->{'status'} = 'down';        # Assume it worked
			&save_managed_server($server);
			print $text{'save_shutdone'},"<p>\n";
			if (defined(&theme_post_save_server)) {
				&theme_post_save_server($server);
				}
			}
		}
	&ui_print_footer("edit_serv.cgi?id=$in{'id'}", $text{'edit_return'});
	}

elsif ($in{'startup'}) {
	# Start up this virtual system
	&can_action_error($server, "startup");
	&ui_print_header(&server_in($server), $text{'save_starttitle'}, "");
	print &text('save_starting',
		    "<tt>$server->{'host'}</tt>"),"<br>\n";
	$err = &startup_server($server);
	if ($err) {
		print &text('save_startfailed', $err),"<p>\n";
		&save_managed_server($server);
		}
	else {
		&check_server_status($server, 0, 1);
		&save_managed_server($server);
		print $text{'save_startdone'},"<p>\n";
		if (defined(&theme_post_save_server)) {
			&theme_post_save_server($server);
			}
		}
	&ui_print_footer("edit_serv.cgi?id=$in{'id'}", $text{'edit_return'});
	}

elsif ($in{'reboot'}) {
	# Request a reboot, after asking for confirmation
	&can_action_error($server, "reboot");
	&ui_print_header(&server_in($server), $text{'save_reboottitle'}, "");
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
			$err = &startup_server($server);
			if ($err) {
				print &text('save_startfailed', $err),"<p>\n";
				}
			else {
				print $text{'save_startdone'},"<p>\n";
				}
			}
		&save_managed_server($server);
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
			if (defined(&theme_post_save_server)) {
				&theme_post_save_server($server);
				}
			}
		&save_managed_server($server);
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
		&show_confirm_form(
		    &text('save_deleterusure', "<tt>$server->{'host'}</tt>").
		    (@doms ? "<p>".&text('save_deleterusure2',
					 scalar(@doms)) : ""),
		    "save_serv.cgi", [ [ "id", $in{'id'} ],
				       [ "delete", 1 ] ],
		    $text{'save_deleteok'});
		}
	else {
		# Run pre-deletion script
		&run_system_script($server, 'before', 'delete') || goto FAILED;

		print &text('save_deleteing',
			    "<tt>$server->{'host'}</tt>"),"<br>\n";
		$dfunc = "type_".$server->{'manager'}."_delete";
		$err = &$dfunc($server);
		if ($err) {
			print &text('save_deletefailed', $err),"<p>\n";
			}
		else {
			&remove_server_ssh_keys($server);
			&delete_managed_server($server);
			print $text{'save_deletedone'},"<p>\n";

			# Run post-deletion script
			&run_system_script($server, 'after', 'delete');

			if (defined(&theme_post_save_server)) {
				&theme_post_save_server($server);
				}
			}
		}
	FAILED:
	&ui_print_footer("edit_serv.cgi?id=$in{'id'}", $text{'edit_return'});
	}



elsif ($in{'installvirt'}) {
	# Install Virtualmin, which may take a while
	&can_action_error($server, "installvirt");
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
				}
			}
	        &stop_installing_virtualmin_licence($serial, $key);

		# Update server status
		print $text{'dcreate_statusing'},"<br>\n";
		&check_server_status($server);
		&save_managed_server($server);
		print $text{'dcreate_statusok'},"<p>\n";

		if (defined(&theme_post_save_server)) {
			&theme_post_save_server($server);
			}

		VIRTFAILED:
		}
	&ui_print_footer("edit_serv.cgi?id=$in{'id'}", $text{'edit_return'});
	}

elsif ($in{'installwebmin'}) {
	# Install Webmin
	&can_action_error($server, "installwebmin");
	&ui_print_header(&server_in($server), $text{'save_webmintitle'}, "");

	($src, $type, $err) = &get_install_webmin_source($server);
	$err && &error(&text('save_webminerr', $err));

	print &text('save_webmining',
		    "<tt>$server->{'host'}</tt>", "<tt>$src</tt>"),"<br>\n";
	($out, $err) = &install_webmin_server($server, $src, $type, 1);
	print "<pre>$out</pre>";
	if ($err) {
		print &text('save_webminfailed', $err),"<p>\n";
		}
	else {
		&check_server_status($server);
		&save_managed_server($server);
		print $text{'save_webmindone'},"<p>\n";

		if (defined(&theme_post_save_server)) {
			&theme_post_save_server($server);
			}
		}

	&ui_print_footer("edit_serv.cgi?id=$in{'id'}", $text{'edit_return'});
	}

elsif ($in{'recheck'}) {
	# Perform a config re-check
	&can_action_error($server, "refresh");
	&ui_print_header(&server_in($server), $text{'save_rechecktitle'}, "");

	print $text{'save_rechecking'},"<br>\n";
	&remote_foreign_require($server, "virtual-server",
					 "virtual-server-lib.pl");
	($out, $cerrarr) = &remote_foreign_call($server, "virtual-server",
		"capture_function_output", "check_virtual_server_config");
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

	&ui_print_footer("edit_serv.cgi?id=$in{'id'}", $text{'edit_return'});
	}

elsif ($in{'refresh'}) {
	# Refresh monitored status
	&can_action_error($server, "refresh");
	&ui_print_header(&server_in($server), $text{'save_refreshtitle'}, "");

	print $text{'save_refreshing'},"<br>\n";
	&check_server_status($server, 1);
	&save_managed_server($server);
	print $text{'save_refreshdone'},"<p>\n";

	if (defined(&theme_post_save_server)) {
		&theme_post_save_server($server);
		}

	# And go back to server form
	print &vm2_js_redirect("edit_serv.cgi?id=$in{'id'}");

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
	$server->{'type'} = $in{'type'};
	@groups = split(/\0/, $in{'group'});
	if ($in{'newgroup'}) {
		$in{'newgroup'} =~ /^\S+$/ || &error($text{'save_egroup2'});
		push(@groups, $in{'newgroup'})
		}
	$server->{'group'} = join("\t", @groups);
	if (defined($in{'canvirt'})) {
		$server->{'novirt'} = $in{'canvirt'} ? 0 : 1;
		}
	$bfunc = "type_".$t."_set_atboot";
	if (defined(&$bfunc)) {
		&$bfunc($server, $in{'atboot'});
		}
	$pfunc = "type_".$t."_edit_parse";
	if (defined(&$pfunc)) {
		&$pfunc($server, \%in);
		}

	# Validate authentication inputs
	$oldserver = { %$server };
	if (defined($in{'auth_mode'})) {
		if ($in{'auth_mode'} == 0) {
			# Via password
			$in{'upass'} || &error($text{'add_eupass'});
			$server->{'ssh_pass'} = $in{'upass'};
			delete($server->{'key'});
			}
		else {
			# Via SSH key
			$server->{'key'} = $in{'key'};
			delete($server->{'ssh_pass'});
			}
		$in{'uuser'} =~ /^[a-z0-9\.\-\_]+$/i ||
			&error($text{'add_euuser'});
		$server->{'ssh_user'} = $in{'uuser'};
		if ($in{'uport_def'}) {
			delete($server->{'ssh_port'});
			}
		else {
			$in{'uport'} =~ /^\d+$/ && $in{'uport'} > 0 &&
			    $in{'uport'} < 65536 || error($text{'add_euport'});
			$server->{'ssh_port'} = $in{'uport'};
			}
		}
	if (defined($in{'webmin_mode'})) {
		if ($in{'webmin_mode'} == 1) {
			# Same as SSH
			$server->{'ssh_pass'} || &error($text{'add_emode1'});
			$server->{'user'} = $server->{'ssh_user'} || 'root';
			$server->{'pass'} = $server->{'ssh_pass'};
			$server->{'ssh_pass_same'} = 1;
			}
		else {
			# Custom Webmin login
			$in{'wuser'} =~ /^\S+$/ || &error($text{'add_ewuser'});
			$server->{'user'} = $in{'wuser'};
			$in{'wpass'} =~ /\S/ || &error($text{'add_ewpass'});
			$server->{'pass'} = $in{'wpass'};
			$server->{'ssh_pass_same'} = 0;
			}

		# Fill in Webmin connection details if we don't have them yet
		if (!$server->{'port'} || $server->{'ssl'} eq '') {
			local ($sok, $serr, $webminroot, $webminport,
			       $webminssl) = &check_server_ssh_login($server);
			if ($webminport) {
				$server->{'port'} = $webminport;
				$server->{'ssl'} = $webminssl;
				}
			}
		}

	# Re-check status if login mode has changed
	if ($oldserver->{'ssh_pass'} ne $server->{'ssh_pass'} ||
	    $oldserver->{'ssh_user'} ne $server->{'ssh_user'} ||
	    $oldserver->{'ssh_port'} != $server->{'ssh_port'} ||
	    $oldserver->{'key'} ne $server->{'key'} ||
	    $oldserver->{'user'} ne $server->{'user'} ||
	    $oldserver->{'pass'} ne $server->{'pass'} ||
	    $oldserver->{'port'} != $server->{'port'} ||
	    $oldserver->{'ssl'} != $server->{'ssl'}) {
		&check_server_status($server);
		}

	&save_managed_server($server);
	&redirect("");
	}

# show_host_override_form(oldip, newip)
# Tell the user that changing the IP may be a bad idea
sub show_host_override_form
{
local ($oldip, $newip) = @_;
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
