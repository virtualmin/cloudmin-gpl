#!/usr/local/bin/perl
# Save blocked IPs

require './server-manager-lib.pl';
&error_setup($text{'blocked_err'});
&error_if_cloudmin_replica();
&can_action_error(undef, "global");
&ReadParse();

@blocked = split(/\s+/, $in{'blocked'});
foreach $ip (@blocked) {
	&check_ipaddress($ip) || &check_ip6address($ip) ||
		&error(&text('blocked_eip', $ip));
	}
&save_blocked_ips({ map { $_, 1 } @blocked });
&webmin_log("blocked");
&redirect("list_ips.cgi");
