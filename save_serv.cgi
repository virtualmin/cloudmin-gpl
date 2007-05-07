#!/usr/local/bin/perl
# Either update the details of some server, or perform some action

require './server-manager-lib.pl';
&ReadParse();
($server) = grep { $_->{'id'} == $in{'id'} } &list_managed_servers();
$server || &error($text{'edit_egone'});
$t = $server->{'manager'};

if ($in{'shutdown'}) {
	# Shut down this system, after asking for confirmation
	&ui_print_header(&server_in($server), $text{'save_shuttitle'}, "");
	if (!$in{'confirm'}) {
		&show_confirm_form(
			&text('save_shutrusure', "<tt>$server->{'host'}</tt>"),
			"save_serv.cgi", [ [ "id", $in{'id'} ],
					   [ "shutdown", 1 ] ],
			$text{'save_shutok'});
		}
	else {
		print &text('save_shutting',
			    "<tt>$server->{'host'}</tt>"),"<br>\n";
		$err = &shutdown_server($server);
		if ($err) {
			print &text('save_shutfailed', $err),"<p>\n";
			}
		else {
			&check_server_status($server);
			&save_managed_server($server);
			print $text{'save_shutdone'},"<p>\n";
			}
		}
	&ui_print_footer("", $text{'index_return'});
	}

elsif ($in{'startup'}) {
	# Start up this virtual system
	&ui_print_header(&server_in($server), $text{'save_starttitle'}, "");
	print &text('save_starting',
		    "<tt>$server->{'host'}</tt>"),"<br>\n";
	$err = &startup_server($server);
	if ($err) {
		print &text('save_startfailed', $err),"<p>\n";
		}
	else {
		&check_server_status($server);
		&save_managed_server($server);
		print $text{'save_startdone'},"<p>\n";
		}
	&ui_print_footer("", $text{'index_return'});
	}

elsif ($in{'reboot'}) {
	# Request a reboot, after asking for confirmation
	&ui_print_header(&server_in($server), $text{'save_reboottitle'}, "");
	if (!$in{'confirm'}) {
		&show_confirm_form(
		    &text('save_rebootrusure', "<tt>$server->{'host'}</tt>"),
		    "save_serv.cgi", [ [ "id", $in{'id'} ],
				       [ "reboot", 1 ] ],
		    $text{'save_rebootok'});
		}
	else {
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
	&ui_print_footer("", $text{'index_return'});
	}

elsif ($in{'installvirt'}) {
	# Install Virtualmin, which may take a while
	&ui_print_header(&server_in($server), $text{'save_virttitle'}, "");

	# Start off the process
	print $text{'save_virtstart'},"<br>\n";
	$err = &install_virtualmin_server($server, 1);
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
		$done = &install_virtualmin_server_done($server);
		if ($done eq "OK") {
			print "<br>",$text{'save_virtdone'},"<p>\n";
			last;
			}
		elsif ($done) {
			print "<br>",&text('save_virterr', $done),"<p>\n";
			last;
			}
		else {
			print ".";
			}
		}

	# Update server status
	print $text{'dcreate_statusing'},"<br>\n";
	&check_server_status($server);
	&save_managed_server($server);
	print $text{'dcreate_statusok'},"<p>\n";

	VIRTFAILED:
	&ui_print_footer("", $text{'index_return'});
	}

elsif ($in{'installwebmin'}) {
	# Install Webmin
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
		}

	&ui_print_footer("", $text{'index_return'});
	}

elsif ($in{'recheck'}) {
	# Perform a config re-check
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

	&ui_print_footer("", $text{'index_return'});
	}

elsif ($in{'refresh'}) {
	# Refresh monitored status
	&ui_print_header(&server_in($server), $text{'save_refreshtitle'}, "");

	print $text{'save_refreshing'},"<br>\n";
	&check_server_status($server);
	&save_managed_server($server);
	print $text{'save_refreshdone'},"<p>\n";

	# And go back to server form
	print "<script>\n";
	print "window.location = 'edit_serv.cgi?id=$in{'id'}';\n";
	print "</script>\n";

	&ui_print_footer("", $text{'index_return'});
	}

elsif ($in{'shell'}) {
	# Go to shell page
	&redirect("shell.cgi?id=$in{'id'}");
	}

elsif ($in{'webmin'}) {
	# Go to Webmin
	&redirect(&webmin_link($server));
	}

else {
	# Validate inputs, and save details
	&error_setup($text{'save_err'});
	if ($server->{'id'} != 0) {
		$server->{'desc'} = $in{'desc'};
		}
	$server->{'type'} = $in{'type'};
	if (defined($in{'canvirt'})) {
		$server->{'novirt'} = $in{'canvirt'} ? 0 : 1;
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
		}
	if (defined($in{'webmin_mode'})) {
		if ($in{'webmin_mode'} == 1) {
			# Same as SSH
			$server->{'ssh_pass'} || &error($text{'add_emode1'});
			$server->{'user'} = 'root';
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

