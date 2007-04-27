#!/usr/local/bin/perl
# Perform some operation on multiple servers at once (delete, reregister,
# refresh status)

require './server-manager-lib.pl';
&ReadParse();
%d = map { $_, 1 } split(/\0/, $in{'d'});
@servers = grep { $d{$_->{'id'}} } &list_managed_servers();
@servers || &error($text{'mass_enone'});

if ($in{'refresh'}) {
	# Fetch the status of selected servers, in 10 processes
	&ui_print_header(undef, $text{'mass_ftitle'}, "");

	print &text('mass_fdoing', scalar(@servers)),"<br>\n";
	&parallel_check_server_status(\@servers);
	print $text{'mass_fdone'},"<p>\n";

	&ui_print_footer("", $text{'index_return'});
	}
elsif ($in{'delete'}) {
	# Delete the selected servers (virtual only)
	&error_setup($text{'mass_derr'});
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

	&ui_print_unbuffered_header(undef, $text{'mass_dtitle'}, "");
	if (!$in{'confirm'}) {
		# Ask the user if he is sure
		print "<center>\n";
		print &ui_form_start("mass.cgi", "post");
		print &ui_hidden("delete", 1);
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
			print "<td>(",&$tfunc(),")</td>\n";
			print "<td>",@sdoms ? &text('mass_ddoms',
					scalar(@sdoms)) : undef,"</td>\n";
			print "</tr>\n";
			$dtotal += scalar(@sdoms);
			}
		print "</table>\n";
		if ($dtotal) {
			print "<b><font size=+2>",
			      &text('mass_ddeldoms', $dtotal),
			      "</font></b><p>\n";
			}
		print &ui_form_end([ [ "confirm", $text{'mass_dok'} ] ]);
		print "</center>\n";
		}
	else {
		# Do it for real
		foreach $s (@servers) {
			$tfunc = "type_".$s->{'manager'}."_desc";
			print &text('mass_deleting', &$tfunc(),
				    "<tt>$s->{'host'}</tt>"),"<br>\n";
			$dfunc = "type_".$s->{'manager'}."_delete";
			$err = &$dfunc($s);
			if ($err) {
				print &text('mass_edelete', $err),"<p>\n";
				}
			else {
				print $text{'mass_deleted'},"<p>\n";
				&delete_managed_server($s);
				}
			}
		}
	&ui_print_footer("", $text{'index_return'});
	}
elsif ($in{'dereg'}) {
	# Removing from managed servers list
	&error_setup($text{'mass_uerr'});

	&ui_print_unbuffered_header(undef, $text{'mass_rtitle'}, "");
	if (!$in{'confirm'}) {
		# Ask the user if he is sure
		print "<center>\n";
		print &ui_form_start("mass.cgi", "post");
		print &ui_hidden("dereg", 1);
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
		foreach $s (@servers) {
			&delete_managed_server($s);
			}
		print $text{'mass_rdone'},"<p>\n";
		}
	&ui_print_footer("", $text{'index_return'});
	}
elsif ($in{'update'}) {
	# Update packages on multiple systems at once
	&ui_print_unbuffered_header(undef, $text{'mass_uptitle'}, "");

	# Find selected servers with updates
	@upservers = ( );
	$pos = 0;
	foreach $s (@servers) {
		$info = &get_server_collected($s);
		if ($info->{'poss'} && @{$info->{'poss'}}) {
			push(@upservers, $s);
			$pos += scalar(@{$info->{'poss'}});
			}
		}

	# Run them in parallel
	print &text('mass_updoing', scalar(@upservers), $pos),"<br>\n";
	&parallel_install_package_updates(\@upservers);
	print $text{'mass_updone'},"<p>\n";

	&ui_print_footer("", $text{'index_return'});
	}
else {
	&error($text{'mass_ebutton'});
	}

