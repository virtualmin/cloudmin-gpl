#!/usr/local/bin/perl
# Create, update or delete a network interface

require './server-manager-lib.pl';
&ReadParse();
&error_if_cloudmin_replica();

# Get the server and interface
$server = &get_managed_server($in{'id'});
$server || &error($text{'edit_egone'});
&can_action_error($server, "ifaces");
$cfunc = "type_".$server->{'manager'}."_can_interfaces";
$can = &$cfunc($server);
$can || &error($text{'iface_esupport'});
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
	$iface->{'nodelete'} && &error($text{'iface_edelete'});
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
		&ui_print_footer("list_ifaces.cgi?id=$in{'id'}",
				 $text{'ifaces_return'});
		}
	else {
		# Just do it
		&obtain_lock_server($server);
		$dfunc = "type_".$server->{'manager'}."_delete_interface";
		$err = &$dfunc($server, $iface);
		if (&supports_dhcpd(1) && $iface->{'virtual'} eq '') {
			&delete_iface_dhcpd($server, $iface);
			}
		&compute_ip_addresses($server);
		&save_managed_server($server);
		&release_lock_server($server);
		&error($err) if ($err);
		&webmin_log("delete", "iface", $server->{'host'},
			    { 'address' => $iface->{'address'} });
		&redirect("list_ifaces.cgi?id=$in{'id'}");
		}
	}
else {
	# Validate inputs
	&error_setup($text{'iface_err'});
	if ($in{'new'}) {
		$iface = { 'name' => $in{'name'} };
		}
	if ($in{'new'} == 2) {
		# Check real interface
		$can == 2 || &error($text{'iface_esupportreal'});
		&can_action_error($server, "realifaces");
		if ($in{'bridge'}) {
			$vhost = &get_parent_server($server);
			@bridges = &list_host_bridges($vhost);
			&indexof($in{'bridge'}, @bridges) >= 0 ||
				&error($text{'iface_ebridge'});
			}
		}
	if ((!$in{'new'} || !$in{'address_def'}) &&
	    &can_action($server, "ips")) {
		# Validate manually entered address
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

		# Validate manual netmask
		&check_ipaddress($in{'netmask'}) ||
			&error($text{'iface_enetmask'});
		$iface->{'netmask'} = $in{'netmask'};
		}

	# Save IPv6 addresses
	if (defined($in{'address6_0'})) {
		my (@address6, @netmask6);
		for(my $n=0; defined($in{'address6_'.$n}); $n++) {
			next if (!$in{'address6_'.$n});
			&check_ip6address($in{'address6_'.$n}) ||
				&error(&text('iface_eaddress6', $n+1));
			$in{'netmask6_'.$n} =~ /^\d+$/ &&
                            $in{'netmask6_'.$n} > 0 &&
                            $in{'netmask6_'.$n} <= 128 ||
                                &error(&text('iface_enetmask6', $n+1));
			push(@address6, $in{'address6_'.$n});
			push(@netmask6, $in{'netmask6_'.$n});
			}
		$iface->{'address6'} = \@address6;
		$iface->{'netmask6'} = \@netmask6;
		}

	# Save ethernet address
	if (defined($in{'mac'}) || defined($in{'mac_def'})) {
		$in{'mac_def'} || $in{'mac'} =~ /^[A-Fa-f0-9:]+$/ ||
			&error($text{'iface_emac'});
		$iface->{'ether'} = $in{'mac_def'} ? undef : $in{'mac'};
		}

	# Save device model
	$lfunc = "type_".$server->{'manager'}."_list_models";
	if (defined($in{'model'}) && defined(&$lfunc)) {
		if ($in{'model'} eq '') {
			delete($iface->{'model'});
			}
		else {
			$models = &$lfunc($server);
			ref($models) || &error($models);
			($model) = grep { $_->[0] eq $in{'model'} } @$models;
			$model || &error($text{'iface_emodel'});
			$iface->{'model'} = $in{'model'};
			}
		}

	# Check if over limit
	$limits = &get_owner_limits();
	if ($in{'new'} && $limits && $limits->{'max_ips'}) {
		if ($limits->{'ips'} + 1 > $limits->{'max_ips'}) {
			&error(&text('iface_elimit',
			       $limits->{'max_ips'}, $limits->{'ips'}));
			}
		}

	# Save or create
	&obtain_lock_server($server);
	$oldip = &get_server_ip($server);
	if ($in{'new'}) {
		$cfunc = "type_".$server->{'manager'}."_create_interface";
		$err = &$cfunc($server, $iface, $in{'new'} == 2, $in{'bridge'});
		}
	else {
		$mfunc = "type_".$server->{'manager'}."_modify_interface";
		$err = &$mfunc($server, $iface, $oldiface);
		}

	# Update DHCPd config, if enabled
	if (($config{'dhcp_add'} || $oldiface) && &supports_dhcpd(1) &&
	    $iface->{'virtual'} eq '') {
		if ($iface->{'ether'}) {
			&save_iface_dhcpd($server, $iface, $oldiface);
			}
		elsif ($oldiface->{'ether'}) {
			&delete_iface_dhcpd($server, $oldiface);
			}
		}

	# Check for change in main IP, which effects DNS
	if (!$in{'new'} && $iface->{'address'} ne $oldiface->{'address'} &&
	    $oldiface->{'address'} eq $oldip) {
		&remote_finished();
		$server->{'ip'} = $iface->{'address'};
		&delete_ip_address($server, $oldiface->{'address'});
		&add_ip_address($server, $iface->{'address'});
		&modify_primary_ip_address($server, $oldiface->{'address'},
						    $iface->{'address'});
		&check_server_status($server, 0, 1);
		$refresh = 1;
		}
	else {
		# Refresh IP cache
		&compute_ip_addresses($server);
		$refresh = 0;
		}

	&save_managed_server($server);
	&release_lock_server($server);
	&error($err) if ($err);
	&webmin_log($in{'new'} ? "create" : "modify",
		    "iface", $server->{'host'},
		    { 'address' => $iface->{'address'} });
	&redirect("list_ifaces.cgi?id=$in{'id'}&refresh=$refresh");
	}
