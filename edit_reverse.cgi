#!/usr/local/bin/perl
# Show a page for editing reverse IP mappings for a system

require './server-manager-lib.pl';
&ReadParse();

# Get and check system
@servers = &list_managed_servers();
($server) = grep { $_->{'id'} == $in{'id'} } @servers;
$server || &error($text{'edit_egone'});
&can_action_error($server, "reverse");

&ui_print_header(&server_in($server), $text{'reverse_title'}, "", "reverse");

# For each IP for which we could possibly have a reverse, show it
print &ui_form_start("save_reverse.cgi");
print &ui_hidden("id", $in{'id'});
print &ui_table_start($text{'reverse_header'}, undef, 2);

@ips = &get_server_ip($server);
$i = 0;
foreach $ip (@ips) {
	print &ui_table_hr() if ($i);
	print &ui_table_row($i == 0 ? $text{'reverse_ip0'}
				    : &text('reverse_ipn', $i), "<tt>$ip</tt>");
	($rfn, $rrecs) = &get_reverse_dns_zone($ip);
	$arpa = &bind8::ip_to_arpa($ip);
	if ($rfn) {
		# Can edit reverse for IP
		($r) = grep { $_->{'name'} eq $arpa } @$rrecs;
		$rev = $r ? $r->{'values'}->[0] : '';
		$rev =~ s/\.$//;
		print &ui_table_row($text{'reverse_host'},
			&ui_opt_textbox("host_$ip", $rev, 30,
					$text{'reverse_none'}));
		}
	else {
		# Cannot set, as no reverse zone
		print &ui_table_row($text{'reverse_host'},
				    "<i>$text{'reverse_nozone'}</i>");
		}
	$i++;
	}

print &ui_table_end();
print &ui_form_end([ [ undef, $text{'save'} ] ]);

&ui_print_footer("edit_serv.cgi?id=$in{'id'}", $text{'edit_return'});

if (defined(&theme_select_server)) {
	&theme_select_server($server);
	}

