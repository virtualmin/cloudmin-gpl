#!/usr/local/bin/perl
# Show a form for cloning an existing system

require './server-manager-lib.pl';
&ReadParse();
$server = &get_managed_server($in{'id'});
$server || &error($text{'edit_egone'});
&can_create_server_error($server->{'manager'});
$cfunc = "type_".$server->{'manager'}."_can_clone";
$can = &$cfunc($server); 

&ui_print_header(&server_in($server), $text{'clone_title'}, "", "clone");

print $text{'clone_topdesc'},"<p>\n";

print &ui_form_start("clone.cgi", "post");
print &ui_hidden("id", $in{'id'});
print &ui_table_start($text{'clone_header'}, undef, 2);

# System type
$tfunc = "type_".$server->{'manager'}."_desc";
print &ui_table_row($text{'mkimage_type'},
		    &$tfunc());

# New hostname prefix
print &ui_table_row($text{'clone_host'},
	&ui_textbox("host", undef, 20));

# New description
print &ui_table_row($text{'clone_desc'},
	&ui_textbox("desc", $server->{'desc'} ? "Clone of ".$server->{'desc'}
					      : "", 40));

# Do live snapshot if supported
$down = $server->{'status'} eq 'down';
if ($can == 2) {
	print &ui_table_row($down ? $text{'clone_snap'} : $text{'clone_live'},
		&ui_yesno_radio("live", !$down));
	}

# IP addresses for non-virtual interfaces
if (&can_action($server, 'ips')) {
	$cfunc = "type_".$server->{'manager'}."_can_interfaces";
	@grid = ( );
	if (defined(&$cfunc) && &$cfunc($server)) {
		# Can show list of interfaces
		$ifunc = "type_".$server->{'manager'}."_list_interfaces";
		$i = 0;
		$ifaces = &$ifunc($server);
		foreach my $iface (grep { $_->{'virtual'} eq '' } @$ifaces) {
			push(@grid, [ $iface->{'name'},
				      &ui_textbox("ip_$i", undef, 20) ]);
			$i++;
			}
		$ipsfield = &ui_columns_table(
			[ $text{'clone_iface'}, $text{'clone_ip'} ],
			undef, \@grid);
		}
	if (!@grid) {
		# One text box
		$ipsfield = &ui_textarea("ips", undef, 3, 20);
		}
	print &ui_table_row($text{'clone_ips'},
		&ui_radio("ips_def", 1, [ [ 1, $text{'clone_ips1'} ],
					  [ 0, $text{'clone_ips0'} ] ]).
		"<br>\n".$ipsfield);
	}

print &ui_table_end();
print &ui_form_end([ [ undef, $text{'clone_ok'} ] ]);

&ui_print_footer("edit_serv.cgi?id=$in{'id'}", $text{'edit_return'});
