#!/usr/local/bin/perl
# Show a form for editing or adding a network interface

require './server-manager-lib.pl';
&ReadParse();

# Get the server and interface
$server = &get_managed_server($in{'id'});
$server || &error($text{'edit_egone'});
&can_action_error($server, "ifaces");
if (!$in{'new'}) {
	$ifunc = "type_".$server->{'manager'}."_list_interfaces";
	$ifaces = &$ifunc($server);
	ref($ifaces) || &error(&text('iface_eget', $ifaces));
	$iface = $ifaces->[$in{'idx'}];
	}
$cfunc = "type_".$server->{'manager'}."_can_interfaces";
$can = &$cfunc($server);
$can || &error($text{'iface_esupport'});
if ($in{'new'} == 2) {
	$can == 2 || &error($text{'iface_esupportreal'});
	&can_action_error($server, "realifaces");
	}

&ui_print_header(&server_in($server),
		 $in{'new'} == 2 ? $text{'iface_createreal'} :
		 $in{'new'} == 1 ? $text{'iface_create'} :
				   $text{'iface_edit'},
		 "", "iface");

print &ui_form_start("save_iface.cgi", "post");
print &ui_hidden("id", $in{'id'});
print &ui_hidden("idx", $in{'idx'});
print &ui_hidden("new", $in{'new'});
print &ui_table_start($text{'iface_header'}, undef, 2);

# Get parent interfaces
if ($in{'new'}) {
	$pfunc = "type_".$server->{'manager'}."_list_parent_interfaces";
	$parents = &$pfunc($server);
	ref($parents) || &error(&text('iface_egetparents', $parents));
	}

# Parent interface
if ($in{'new'} == 1) {
	# New virtual interface .. show parent chooser
	$parents = [ grep { $_->{'virtual'} eq '' &&
			    $_->{'name'} !~ /^lo/ &&
                            $_->{'address'} } @$parents ];
	print &ui_table_row($can ? $text{'iface_parent2'} 
				 : $text{'iface_parent'},
		    &ui_select("name", $parents->[0]->{'fullname'},
			[ map { [ $_->{'fullname'} ] } @$parents ]));
	$iface->{'netmask'} = $parents->[0]->{'netmask'};
	}
elsif ($in{'new'} == 2) {
	# New real interface .. show name and bridge chooser
	$max = 1;
	foreach $p (@$parents) {
		if ($p->{'fullname'} =~ /^eth(\d+)$/ && $1 >= $max) {
			$max++;
			}
		}
	print &ui_table_row($text{'iface_name'},
			    &ui_textbox("name", "eth$max", 20));

	$vhost = &get_parent_server($server);
	@bridges = &list_host_bridges($vhost);
	if (@bridges) {
		print &ui_table_row($text{'iface_bridge'},
				    &ui_select("bridge", undef,
					       [ [ undef, $text{'default'} ],
						 @bridges ]));
		}
	}
else {
	# Show details of existing interface
	print &ui_table_row($can == 1 ? $text{'iface_parent'}
				      : $text{'iface_name'},
			    "<tt>$iface->{'name'}</tt>");
	if ($iface->{'virtual'} ne '') {
		print &ui_table_row($text{'iface_virt'},
				    "<tt>$iface->{'virtual'}</tt>");
		}
	$info = &get_server_collected($server);
	@doms = &get_server_domains($server);
	if ($info) {
		($ucode, $use) = &get_interface_use($server, $info,
						    \@doms, $iface);
		print &ui_table_row($text{'iface_use'}, $use);
		}
	if ($iface->{'bridge'}) {
		print &ui_table_row($text{'iface_bridge'},
				    "<tt>$iface->{'bridge'}</tt>");
		}
	}

# Address
$afunc = "type_".$server->{'manager'}."_can_allocate_address";
if ($in{'new'} && defined(&$afunc) && &$afunc($server)) {
	# Show auto-allocate option
	if (&can_action($server, "ips")) {
		# Can allocate or enter
		print &ui_table_row($text{'iface_address'},
			    &ui_opt_textbox("address", undef, 20,
					    $text{'iface_alloc'},
					    $text{'iface_man'})." ".
			    &ip_address_chooser_button("address", $server));
		}
	else {
		# Always allocated
		print &ui_table_row($text{'iface_address'},
				    "<i>$text{'iface_alloc'}</i>");
		}
	}
elsif (!&can_action($server, "ips")) {
	# Show existing IP
	print &ui_table_row($text{'iface_address'},
		"<tt>$iface->{'address'}</tt>");
	}
else {
	# Must enter
	print &ui_table_row($text{'iface_address'},
		    &ui_textbox("address", $iface->{'address'}, 20));
	}

# Netmask
$nfunc = "type_".$server->{'manager'}."_force_netmask";
if (defined(&$nfunc) && ($forcemask = &$nfunc($server))) {
	print &ui_hidden("netmask", $forcemask);
	print &ui_table_row($text{'iface_netmask'}, "<tt>$forcemask</tt>");
	}
else {
	print &ui_table_row($text{'iface_netmask'},
		    &ui_textbox("netmask", $iface->{'netmask'}, 20));
	}

# MAC address (if non-virtual)
$mfunc = "type_".$server->{'manager'}."_can_mac_address";
if (defined(&$mfunc) && &$mfunc($server, $in{'new'} ? undef : $iface)) {
	print &ui_table_row($text{'iface_mac'},
		&ui_opt_textbox("mac", $iface->{'ether'}, 20,
				$text{'iface_macdef'}));
	}

print &ui_table_end();
if ($in{'new'}) {
	print &ui_form_end([ [ undef, $text{'create'} ] ]);
	}
else {
	print &ui_form_end(
		[ [ undef, $text{'save'} ],
		  $iface->{'nodelete'} ? ( ) : ( [ 'delete', $text{'delete'} ] )
		]);
	}

&ui_print_footer("list_ifaces.cgi?id=$in{'id'}",
		 $text{'ifaces_return'});

