#!/usr/local/bin/perl
# Delete a bunch of system owners

require './server-manager-lib.pl';
&ReadParse();
&error_setup($text{'downers_err'});
@d = split(/\0/, $in{'d'});
@d || &error($text{'downers_enone'});

foreach $d (@d) {
	$owner = &get_system_owner($d);
	if ($owner) {
		&delete_system_owner($owner);
		}
	}
&redirect("list_owners.cgi");

