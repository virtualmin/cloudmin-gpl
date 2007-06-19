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
			($err, $out) = &call_virtualmin_api($server,
						"delete-domain", \@args);
			if ($err) {
				print &text('dcreate_failed',
					    &html_escape($err)),"<p>\n";
				}
			else {
				print "<pre>",&html_escape($out),"</pre>\n";
				print $text{'create_done'},"<p>\n";
				$recheck++;
				}

			# Remove the virtual IP
			$iface = &get_domain_interface($server, $d);
			if ($iface && !$err) {
				print &text('dmass_deleteip',
				    "<tt>$iface->{'address'}</tt>",
				    "<tt>$server->{'host'}</tt>"),"<br>\n";
				$dfunc = "type_".$server->{'manager'}.
					 "_delete_interface";
				$err = &$dfunc($server, $iface);
				if ($err) {
					print &text('dcreate_failed',
						    $err),"<p>\n";
					}
				else {
					print $text{'create_done'},"<p>\n";
					}
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
	&ui_print_header(undef, $text{'dmass_titlemove'}, "", "move");

	if (!$in{'confirm'}) {
		# Ask where
		print &ui_form_start("mass_domains.cgi", "post");
		foreach $d (@d) {
			print &ui_hidden("d", $d);
			}
		print &ui_hidden("move", 1);
		print &ui_table_start($text{'dmass_mheader'}, undef, 2,
				      [ "width=30%" ]);

		# Domains to move
		@sources = &unique(map { $_->[0]->{'host'} } @serverdoms);
		if (@sources > 1) {
			print &ui_table_row($text{'dmass_mdoms'},
			    join(" ", map { &text('dmass_on',
					  $_->[1]->{'dom'}, $_->[0]->{'host'}) }
					  @serverdoms));
			}
		else {
			print &ui_table_row($text{'dmass_mdoms'},
			    join(" ", map { $_->[1]->{'dom'} } @serverdoms));
			}

		# Destination server
		print &ui_table_row($text{'dmass_mdest'},
			&ui_select("dest", undef,
				[ map { [ $_->{'id'}, $_->{'host'} ] }
				      grep { $_->{'status'} eq 'virt' } 
				           @servers ]));

		# Delete from source?
		print &ui_table_row($text{'dmass_mdelete'},
			&ui_radio("deletesource", 2,
				  [ [ 1, $text{'yes'} ],
				    [ 2, $text{'dmass_mdisable'} ],
				    [ 0, $text{'no'} ] ]));

		# Force move?
		print &ui_table_row($text{'dmass_mforce'},
			&ui_yesno_radio("force", 0));

		print &ui_table_end();
		print &ui_form_end([ [ "confirm", $text{'dmass_move'} ] ]);
		}
	else {
		# Make sure the move is valid (cannot move child without parent)
		($server) = grep { $_->{'id'} eq $in{'dest'} } @servers;
		$server || &error($text{'dmass_edest'});
		$err = &check_domain_move(\@serverdoms, $server,
					  $in{'deletesource'});
		&error(&text('dmass_emove', $err)) if ($err);

		# Check for missing features
		@missing = &check_move_features(\@serverdoms, $server);
		if (@missing && !$in{'force'}) {
			print $text{'dmass_emissing'},"<p>\n";
			print &ui_columns_start([
				$text{'dmass_msdom'},
				$text{'dmass_msserver'},
				$text{'dmass_msfeature'} ]);
			foreach $m (@missing) {
				print &ui_columns_row([
					$m->[1]->{'dom'},
					$m->[0]->{'host'},
					$m->[2]->{'desc'},
					]);
				}
			print &ui_columns_end();
			}
		else {
			# Do each one in series, by backing up and restoring
			&move_domains_to_server(\@serverdoms, $server,
						$in{'deletesource'});
			}
		}
	}

else {
	&error("No button clicked!");
	}

if ($recheck) {
	# Re-check and save the status
	print $text{'dcreate_statusing'},"<br>\n";
	foreach my $sd (@serverdoms) {
		$server = $sd->[0];
		if (!$donerecheck{$server->{'host'}}++) {
			&check_server_status($server);
			&save_managed_server($server);
			}
		}
	print $text{'dcreate_statusok'},"<p>\n";
	}
if ($in{'id'} eq '') {
	&ui_print_footer("list_domains.cgi", $text{'domains_return'});
	}
else {
	&ui_print_footer("edit_serv.cgi?id=$in{'id'}&doms=1", $text{'edit_return'});
	}

