#!/usr/local/bin/perl
# Delete or re-evaluate DNS roundrobins

require './server-manager-lib.pl';
&can_action_error(undef, "global");
&ReadParse();
&error_setup($in{'delete'} ? $text{'droundrobins_err1'} :
			     $text{'droundrobins_err2'});
&error_if_cloudmin_replica();
@d = split(/\0/, $in{'d'});
@d || &error($text{'droundrobins_enone'});
@roundrobins = grep { $_ } map { &get_roundrobin($_) } @d;

if ($in{'delete'}) {
	# Delete selected roundrobins
	foreach $a (@roundrobins) {
		&delete_roundrobin_dns($a);
		&delete_roundrobin($a);
		}
	&webmin_log("delete", "roundrobins", scalar(@roundrobins));
	}
else {
	# Refresh selected
	@errs = &evaluate_all_roundrobins(undef, \@roundrobins, 1);
	if (@errs) {
		# Some failed .. tell the user
		&ui_print_header(undef, $text{'droundrobins_title'}, "");
		foreach $e (@errs) {
			print &text('droundrobins_fail',
				$e->[0]->{'name'}.".".$e->[0]->{'dom'},
				$e->[1]),"<p>\n";
			}
		&ui_print_footer("list_roundrobins.cgi",
				 $text{'roundrobins_return'});
		return;
		}
	}
&redirect("list_roundrobins.cgi");

