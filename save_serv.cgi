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
	# XXX
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
	# Install Virtualmin, after asking for version
	# XXX
	}

elsif ($in{'installwebmin'}) {
	# Install Webmin
	# XXX password?
	&ui_print_header(&server_in($server), $text{'save_webmintitle'}, "");

	($src, $type, $err) = &get_install_webmin_source($server);
	$err && &error(&text('save_webminerr', $err));

	print &text('save_webmining',
		    "<tt>$server->{'host'}</tt>", "<tt>$src</tt>"),"<br>\n";
	($out, $err) = &install_webmin_server($server, $src, $type);
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
	if ($server->{'id'} != 0) {
		$server->{'desc'} = $in{'desc'};
		}
	if (defined($in{'canvirt'})) {
		$server->{'novirt'} = $in{'canvirt'} ? 0 : 1;
		}
	$pfunc = "type_".$t."_edit_parse";
	if (defined(&$pfunc)) {
		&$pfunc($server, \%in);
		}
	&save_managed_server($server);
	&redirect("");
	}

