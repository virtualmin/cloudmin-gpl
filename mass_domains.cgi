#!/usr/local/bin/perl
# Delete, enable or disable virtual servers on multiple servers

require './server-manager-lib.pl';
&ReadParse();
&error_setup($text{'dmass_err'});
@servers = &list_managed_servers();

# Parse inputs and find servers
@d = split(/\0/, $in{'d'});
foreach $sd (@d) {
	($sid, $did) = split(/\//, $sd);
	($server) = grep { $_->{'id'} eq $sid } @servers;
	$server || &error(&text('dmass_eserver', $sid));
	@doms = &get_server_domains($server);
	($d) = grep { $_->{'id'} eq $did } @doms;
	$d || &error(&text('dmass_edom', $server->{'host'}, $did));
	$server->{'status'} eq 'virt' ||
		&error(&text('dmass_estatus', $server->{'host'}, $d->{'dom'}));
	push(@serverdoms, [ $server, $d ]);
	}
@serverdoms || &error($text{'dmass_enone'});
$postmsg = &text('dmass_post', join(", ", map { "<tt>$_->[1]->{'dom'}</tt>" }
					      @serverdoms));

if ($in{'delete'}) {
	# Delete the domains, after asking for confirmation
	&ui_print_header(undef, $text{'dmass_titledelete'},"");
	if (!$in{'confirm'}) {
		# Ask first
		&show_confirm_form(
			&text('dmass_deleterusure', scalar(@serverdoms)),
			"mass_domains.cgi", [ (map { [ "d", $_ ] } @d),
					      [ "id", $in{'id'} ],
					      [ "delete", 1 ] ],
			$text{'dmass_deleteok'}, $postmsg);
		}
	else {
		# Do them
		foreach $sd (@serverdoms) {
			($server, $d) = @$sd;
			print &text('dmass_deleting', "<tt>$d->{'dom'}</tt>",
					"<tt>$server->{'host'}</tt>"),"<br>\n";
			@args = ( [ "domain", $d->{'dom'} ] );
			($err, $out) = &call_virtualmin_api($server, "delete-domain",
							    \@args);
			if ($err) {
				print &text('dcreate_failed',
					    &html_escape($err)),"<p>\n";
				}
			else {
				print "<pre>",&html_escape($out),"</pre>\n";
				print $text{'create_done'},"<p>\n";
				$recheck++;
				}
			}
		}
	}

elsif ($in{'disable'}) {
	# Disable the domains, after asking for confirmation
	&ui_print_header(undef, $text{'dmass_titledisable'},"");
	if (!$in{'confirm'}) {
		# Ask first
		&show_confirm_form(
			&text('dmass_disablerusure', scalar(@serverdoms)),
			"mass_domains.cgi", [ (map { [ "d", $_ ] } @d),
					      [ "id", $in{'id'} ],
					      [ "disable", 1 ] ],
			$text{'dmass_disableok'}, $postmsg);
		}
	else {
		# Do them
		foreach $sd (@serverdoms) {
			($server, $d) = @$sd;
			print &text('dmass_disabling', "<tt>$d->{'dom'}</tt>",
					"<tt>$server->{'host'}</tt>"),"<br>\n";
			@args = ( [ "domain", $d->{'dom'} ] );
			($err, $out) = &call_virtualmin_api($server, "disable-domain",
							    \@args);
			if ($err) {
				print &text('dcreate_failed',
					    &html_escape($err)),"<p>\n";
				}
			else {
				print "<pre>",&html_escape($out),"</pre>\n";
				print $text{'create_done'},"<p>\n";
				$recheck++;
				}
			}
		}
	}

elsif ($in{'enable'}) {
	# Enable the domains
	&ui_print_header(undef, $text{'dmass_titleenable'},"");
	foreach $sd (@serverdoms) {
		($server, $d) = @$sd;
		print &text('dmass_enabling', "<tt>$d->{'dom'}</tt>",
				"<tt>$server->{'host'}</tt>"),"<br>\n";
		@args = ( [ "domain", $d->{'dom'} ] );
		($err, $out) = &call_virtualmin_api($server, "enable-domain",
						    \@args);
		if ($err) {
			print &text('dcreate_failed',
				    &html_escape($err)),"<p>\n";
			}
		else {
			print "<pre>",&html_escape($out),"</pre>\n";
			print $text{'create_done'},"<p>\n";
			$recheck++;
			}
		}
	}

elsif ($in{'move'}) {
	# Move the domains to another server, after asking where
	&ui_print_header(undef, $text{'dmass_titlemove'},"");

	if (!$in{'confirm'}) {
		# Ask where
		print &ui_form_start("mass_domains.cgi", "post");
		foreach $d (@d) {
			print &ui_hidden("d", $d);
			}
		print &ui_table_start($text{'dmass_mheader'}, undef, 2);

		# Domains to move
		print &ui_table_row($text{'dmass_mdoms'},
			join(" ", map { $_->[1]->{'dom'} } @serverdoms));

		# Destination server
		print &ui_table_row($text{'dmass_mdest'},
			&ui_select("dest", undef,
				[ map { [ $_->{'id'}, $_->{'dom'} ] }
				      grep { $_->{'status'} eq 'virt' } 
				           @servers ]));

		print &ui_table_end();
		print &ui_form_end([ [ "confirm", $text{'dmass_move'} ] ]);
		}
	else {
		# Make sure the move is valid (cannot move child without parent)
		$err = &check_domain_move(\@serverdoms, $server);
		&error(&text('dmass_emove', $err));

		# Do each one in series, by backing up and restoring
		($server) = grep { $_->{'id'} eq $in{'dest'} } @servers;
		$server || &error($text{'dmass_edest'});
		&move_domains_to_server(\@serverdoms, $server);
		}
	}

else {
	&error("No button clicked!");
	}

if ($recheck) {
	# Re-check and save the status
	print $text{'dcreate_statusing'},"<br>\n";
	&check_server_status($server);
	&save_managed_server($server);
	print $text{'dcreate_statusok'},"<p>\n";
	}
if ($in{'id'} eq '') {
	&ui_print_footer("list_domains.cgi", $text{'domains_return'});
	}
else {
	&ui_print_footer("edit_serv.cgi?id=$in{'id'}&doms=1", $text{'edit_return'});
	}

