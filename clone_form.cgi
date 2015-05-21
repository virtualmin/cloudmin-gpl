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
$cfunc = "type_".$server->{'manager'}."_can_interfaces";
$ifunc = "type_".$server->{'manager'}."_list_interfaces";
if (&can_action($server, 'ips')) {
	@grid = ( );
	if (defined(&$cfunc) && &$cfunc($server)) {
		# Can show list of interfaces
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

# IPv6 addresses, if allowed and VM type supports IPv6 and the system has v6
# addresses currently
$c6func = "type_".$server->{'manager'}."_can_ipv6";
@ip6ifaces = grep { $_->{'address6'} && @{$_->{'address6'}} } @$ifaces;
if (&can_action($server, 'ips') && defined(&$c6func) && &$c6func($server) &&
    $server->{'ip6_addresses'} && @ip6ifaces) {
	@grid = ( );
	if (defined(&$cfunc) && &$cfunc($server)) {
		# Can show list of interfaces
		$i = 0;
		foreach my $iface (grep { $_->{'virtual'} eq '' } @$ifaces) {
			push(@grid, [ $iface->{'name'},
				      &ui_textbox("ip6_$i", undef, 20) ]);
			$i++;
			}
		$ipsfield = &ui_columns_table(
			[ $text{'clone_iface'}, $text{'clone_ip6'} ],
			undef, \@grid);
		}
	if (!@grid) {
		# One text box
		$ipsfield = &ui_textarea("ips6", undef, 3, 20);
		}
	print &ui_table_row($text{'clone_ips6'},
		&ui_radio("ips6_def", 1, [ [ 1, $text{'clone_ips1'} ],
					  [ 0, $text{'clone_ips0'} ] ]).
		"<br>\n".$ipsfield);
	}

# New host system, if allowed
$rcfunc = "type_".$server->{'manager'}."_can_clone_remote";
if (&can_action($server, "move") && defined(&$rcfunc) && &$rcfunc($server)) {
	$vhost = &get_parent_server($server);
	@dests = grep { $_->{'id'} ne $vhost->{'id'} &&
			&indexof($server->{'manager'},
			         &is_parent_server($_)) >= 0 &&
			&can_host_server($_)
		      } &list_managed_servers();
	if (@dests) {
		print &ui_table_row($text{'clone_dest'},
			&ui_select("dest", undef,
			[ [ undef, &text('clone_leave', $vhost->{'host'}) ],
			  map { [ $_->{'id'}, $_->{'host'} ] } @dests ]));
		}
	}

# New directory
if (&indexof($server->{'manager'}, @diskfile_server_management_types) >= 0) {
	$sel = &directory_selector($server->{'manager'},
				   $server->{'directory'});
	if ($sel) {
		print &ui_table_row($text{'clone_directory'}, $sel);
		}
	}

print &ui_table_end();
print &ui_form_end([ [ undef, $text{'clone_ok'} ] ]);

&ui_print_footer("edit_serv.cgi?id=$in{'id'}", $text{'edit_return'});
