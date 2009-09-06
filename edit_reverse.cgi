#!/usr/local/bin/perl
# Show a page for editing reverse IP mappings for a system

require './server-manager-lib.pl';
&ReadParse();

# Get and check system
$server = &get_managed_server($in{'id'});
$server || &error($text{'edit_egone'});
&can_action_error($server, "reverse");

&ui_print_header(&server_in($server), $text{'reverse_title'}, "", "reverse");

# For each IP for which we could possibly have a reverse, show it
print &ui_form_start("save_reverse.cgi");
print &ui_hidden("id", $in{'id'});
print &ui_table_start($text{'reverse_header'}, undef, 2);

@revs = &get_server_reverse_records($server);
$i = 0;
foreach $rev (@revs) {
	print &ui_table_hr() if ($i);
	print &ui_table_row($i == 0 ? $text{'reverse_ip0'} :
		&text('reverse_ipn', $i), "<tt>$rev->{'ip'}</tt>");
	if ($rev->{'outside'}) {
		# Cannot set, as no reverse zone
		print &ui_table_row($text{'reverse_host'},
				    "<i>$text{'reverse_nozone'}</i>");
		}
	else {
		print &ui_table_row($text{'reverse_host'},
			&ui_opt_textbox("host_$rev->{'ip'}", $rev->{'name'}, 30,
					$text{'reverse_none'}));
		}
	$i++;
	}

print &ui_table_end();
print &ui_form_end([ [ undef, $text{'save'} ] ]);

&ui_print_footer("edit_serv.cgi?id=$in{'id'}", $text{'edit_return'});

if (defined(&theme_select_server)) {
	&theme_select_server($server);
	}

