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
	&ui_print_header(undef, $text{'mass_rtitle'}, "");

	print &text('mass_rdoing', scalar(@servers)),"<br>\n";
	&parallel_check_serve_status(\@servers);
	print $text{'mass_rdone'},"<p>\n";

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
			print "<tr>\n";
			print "<td><tt>$s->{'host'}</tt></td>\n";
			print "<td>(",&$tfunc(),")</td>\n";
			print "</tr>\n";
			}
		print "</table>\n";
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
elsif ($in{'rereg'}) {
	# XXX not done yet
	&error_setup($text{'mass_uerr'});
	}
else {
	&error($text{'mass_ebutton'});
	}

