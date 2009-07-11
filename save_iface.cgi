#!/usr/local/bin/perl
# Create, update or delete a network interface

require './server-manager-lib.pl';
&ReadParse();

# Get the server and interface
($server) = grep { $_->{'id'} == $in{'id'} } &list_managed_servers();
$server || &error($text{'edit_egone'});
&can_action_error($server, "ifaces");
if (!$in{'new'}) {
	$ifunc = "type_".$server->{'manager'}."_list_interfaces";
	$ifaces = &$ifunc($server);
	ref($ifaces) || &error(&text('iface_eget', $ifaces));
	$iface = $ifaces->[$in{'idx'}];
	$oldiface = { %$iface };
	}

if ($in{'delete'}) {
	# Delete it, but ask first as this may render some site inaccessible
	&error_setup($text{'iface_derr'});
	$info = &get_server_collected($server);
	@doms = &get_server_domains($server);
	if ($info) {
		($ucode, $use) = &get_interface_use($server, $info,
						    \@doms, $iface);
		}
	if ($ucode && !$in{'confirm'}) {
		# Need to ask the user if he is sure
		&ui_print_header(&server_in($server), $text{'iface_delete'},"");
		&show_confirm_form(
			&text('iface_deleterusure', $iface->{'address'}, $use),
			"save_iface.cgi", [ [ "id", $in{'id'} ],
					    [ "idx", $in{'idx'} ],
					    [ "delete", 1 ] ],
			$text{'iface_deleteok'});
		&ui_print_footer("edit_serv.cgi?id=$in{'id'}&ifaces=1",
				 $text{'edit_return'});
		}
	else {
		# Just do it
		&obtain_lock_server($server);
		$dfunc = "type_".$server->{'manager'}."_delete_interface";
		$err = &$dfunc($server, $iface);
		&release_lock_server($server);
		&error($err) if ($err);
		&redirect("edit_serv.cgi?id=$in{'id'}&ifaces=1");
		}
	}
else {
	# Validate inputs
	&error_setup($text{'iface_err'});
	if ($in{'new'}) {
		$iface = { 'name' => $in{'name'} };
		}
	if (!$in{'new'} || !$in{'address_def'}) {
		&check_ipaddress($in{'address'}) ||
			&error($text{'iface_eaddress'});
		$iface->{'address'} = $in{'address'};
		if ($in{'new'} ||
		    $iface->{'address'} ne $oldiface->{'address'}) {
			# New or changed .. check for clash
			%used = &used_ip_addresses();
			$u = $used{$iface->{'address'}};
			$u && &error(&text('iface_eclash', $u->{'host'}));
			&ping_server_host($iface->{'address'}) &&
				&error(&text('iface_eclash2'));
			}
		}
	&check_ipaddress($in{'netmask'}) || &error($text{'iface_enetmask'});
	$iface->{'netmask'} = $in{'netmask'};

	# Save or create
	&obtain_lock_server($server);
	if ($in{'new'}) {
		$cfunc = "type_".$server->{'manager'}."_create_interface";
		$err = &$cfunc($server, $iface);
		}
	else {
		$mfunc = "type_".$server->{'manager'}."_modify_interface";
		$err = &$mfunc($server, $iface, $oldiface);
		}
	&release_lock_server($server);
	&error($err) if ($err);
	&redirect("list_ifaces.cgi?id=$in{'id'}");
	}
