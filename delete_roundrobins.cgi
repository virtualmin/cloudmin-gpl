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
	&evaluate_all_roundrobins(undef, \@roundrobins, 1);
	}
&redirect("list_roundrobins.cgi");

