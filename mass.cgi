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
	# XXX not done yet
	}
elsif ($in{'rereg'}) {
	# XXX not done yet
	}
else {
	&error($text{'mass_ebutton'});
	}

