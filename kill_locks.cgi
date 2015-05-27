#!/usr/local/bin/perl
# Kill some running actions by PID

require './server-manager-lib.pl';
&ReadParse();
&error_setup($text{'locks_err'});
&can_action_error(undef, "global");
@d = split(/\0/, $in{'d'});
@d || &error($text{'locks_enone'});

@locks = &list_running_actions();
foreach my $d (@d) {
	($lock) = grep { $_->{'pid'} eq $d } @locks;
	if ($lock && $lock->{'pid'}) {
		&kill_logged('TERM', $lock->{'pid'});
		}
	}
&webmin_log("kill", "locks", scalar(@d));
&redirect("list_locks.cgi");
