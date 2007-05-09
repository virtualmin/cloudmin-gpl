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
				}
			}
		$recheck = 1;
		}
	}

elsif ($in{'disable'}) {
	# Disable the domains, after asking for confirmation
	# XXX
	}

elsif ($in{'enablee'}) {
	# Enable the domains
	# XXX
	}

if ($recheck) {
	# Re-check and save the status
	print $text{'dcreate_statusing'},"<br>\n";
	&check_server_status($server);
	&save_managed_server($server);
	print $text{'dcreate_statusok'},"<p>\n";
	}
&ui_print_footer("list_domains.cgi", $text{'domains_return'});
