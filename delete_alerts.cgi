#!/usr/local/bin/perl
# Delete, silence or un-silence selected alerts

require './server-manager-lib.pl';
&can_action_error(undef, "global");
&ReadParse();
&error_setup($in{'delete'} ? $text{'dalerts_err1'} :
	     $in{'silence'} ? $text{'dalerts_err2'} : $text{'dalerts_err3'});
@d = split(/\s+/, $in{'d'});
@d || &error($text{'dalerts_enone'});
@alerts = grep { $_ } map { &get_alert($_) } @d;

if ($in{'delete'}) {
	# Delete selected alerts
	foreach $a (@alerts) {
		&delete_alert($a);
		}
	&webmin_log("delete", "alerts", scalar(@alerts));
	}
elsif ($in{'silence'}) {
	# Set as silenced
	foreach $a (@alerts) {
		if (!$a->{'silenced'}) {
			$a->{'silenced'} = 1;
			&save_alert($a);
			}
		}
	&webmin_log("silence", "alerts", scalar(@alerts));
	}
elsif ($in{'unsilence'}) {
	# Remove silence
	foreach $a (@alerts) {
		if ($a->{'silenced'}) {
			$a->{'silenced'} = 0;
			&save_alert($a);
			}
		}
	&webmin_log("unsilence", "alerts", scalar(@alerts));
	}
&redirect("list_alerts.cgi");

