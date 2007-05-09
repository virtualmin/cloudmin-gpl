#!/usr/local/bin/perl
# Show a form for editing or adding a network interface

require './server-manager-lib.pl';
&ReadParse();

# Get the server and interface
($server) = grep { $_->{'id'} == $in{'id'} } &list_managed_servers();
$server || &error($text{'edit_egone'});
if (!$in{'new'}) {
	$ifunc = "type_".$server->{'manager'}."_list_interfaces";
	$ifaces = &$ifunc($server);
	ref($ifaces) || &error(&text('iface_eget', $ifaces));
	$iface = $ifaces->[$in{'idx'}];
	}

&ui_print_header(&server_in($server), $in{'new'} ? $text{'iface_create'}
						 : $text{'iface_edit'}, "", "iface");
print &ui_form_start("save_iface.cgi", "post");
print &ui_table_start($text{'iface_header'}, undef, 2);

# Parent interface
if ($in{'new'}) {
	$pfunc = "type_".$server->{'manager'}."_list_parent_interfaces";
	$parents = &$pfunc($server);
	ref($parents) || &error(&text('iface_egetparents', $parents));
	$parents = [ grep { $_->{'virtual'} eq '' && $_->{'name'} ne 'lo' &&
                            $_->{'address'} } @$parents ];
	print &ui_table_row($text{'iface_parent'},
		    &ui_select("name", undef,
			[ map { [ $_->{'fullname'} ] } @$parents ]));
	}
else {
	print &ui_table_row($text{'iface_parent'},
			    "<tt>$iface->{'name'}</tt>");
	print &ui_table_row($text{'iface_virt'},
			    "<tt>$iface->{'virtual'}</tt>");
	}

# Address
$afunc = "type_".$server->{'manager'}."_can_allocate_address";
if ($in{'new'} && defined(&$afunc) && &$afunc($server)) {
	# Show auto-allocate option
	print &ui_table_row($text{'iface_address'},
		    &ui_opt_textbox("address", undef, 20, $text{'iface_alloc'}));
	}
else {
	print &ui_table_row($text{'iface_address'},
		    &ui_textbox("address", $iface->{'address'}, 20));
	}

# Netmask
print &ui_table_row($text{'iface_netmask'},
	    &ui_textbox("netmask", $iface->{'netmask'}, 20));

print &ui_table_end();
print &ui_form_end(
	$in{'new'} ? [ [ undef, $text{'create'} ] ]
		   : [ [ undef, $text{'save'} ], [ 'delete', $text{'delete'} ] ]);

&ui_print_footer("edit_serv.cgi?id=$in{'id'}&ifaces=1",
		 $text{'edit_return'});

