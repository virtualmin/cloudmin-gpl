#!/usr/local/bin/perl
# Update reverse IPs for some system

require './server-manager-lib.pl';
&ReadParse();
&error_setup($text{'reverse_err'});

# Get and check system
@servers = &list_managed_servers();
($server) = grep { $_->{'id'} == $in{'id'} } @servers;
$server || &error($text{'edit_egone'});
&can_action_error($server, "reverse");

# Update each of the IPs
&obtain_lock_server($server);
@ips = &get_server_ip($server);
foreach $ip (@ips) {
	next if (!defined($in{"host_".$ip}) &&
		 !defined($in{"host_".$ip."_def"}));
	($rfn, $rrecs) = &get_reverse_dns_zone($ip);
	$rfn || &error(&text('reverse_ezone', $ip));
        $arpa = &bind8::ip_to_arpa($ip);
	($r) = grep { $_->{'name'} eq $arpa } @$rrecs;
	if ($r && $in{"host_".$ip."_def"}) {
		# Delete the record
		# XXX
		}
	elsif ($r && !$in{"host_".$ip."_def"}) {
		# Update the record
		# XXX
		}
	elsif (!$r && !$in{"host_".$ip."_def"}) {
		# Add a record
		# XXX
		}
	# XXX bump SOAs
	}
&release_lock_server($server);

&redirect("edit_serv.cgi?id=".$in{'id'}");

