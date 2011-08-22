#!/usr/local/bin/perl
# Change the default gateway for a system

require './server-manager-lib.pl';
&ReadParse();
&error_setup($text{'ifaces_gwerr'});
&error_if_cloudmin_replica();

# Get the server and check support
$server = &get_managed_server($in{'id'});
$server || &error($text{'edit_egone'});
&can_action_error($server, "ifaces");
$cfunc = "type_".$server->{'manager'}."_can_gateway";
$can = &$cfunc($server);
$can || &error($text{'iface_egwsupport'});
&obtain_lock_server($server);

# Get interfaces
$ifunc = "type_".$server->{'manager'}."_list_interfaces";
$ifaces = &$ifunc($server);
ref($ifaces) || &error(&text('iface_eget', $ifaces));

# Check inputs
($oldgw, $oldgwdev) = &get_server_default_gateway($server);
if (!$in{'gw_def'}) {
	&check_ipaddress($in{'gw'}) || &error($text{'ifaces_egw'});
	($iface) = grep { $_->{'fullname'} eq $in{'gwdev'} } @$ifaces;
	$iface || $in{'gwdev'} eq $oldgwdev || &error($text{'ifaces_egwdev'});
	}

# Check inputs for IPv6 gateway
$c6func = "type_".$server->{'manager'}."_can_ipv6";
if (defined(&$cfunc) && &$c6func($server) && defined($in{'gw6_def'})) {
	($oldgw6, $oldgwdev6) = &get_server_default_ipv6_gateway($server);
	if (!$in{'gw6_def'}) {
		&check_ip6address($in{'gw6'}) || &error($text{'ifaces_egw6'});
		($iface) = grep { $_->{'fullname'} eq $in{'gwdev6'} } @$ifaces;
		$iface || $in{'gwdev6'} eq $oldgwdev6 ||
			&error($text{'ifaces_egwdev6'});
		}
	}

# Apply the change
if ($in{'gw_def'}) {
	$err = &modify_default_gateway($server, undef, undef);
	}
else {
	$err = &modify_default_gateway($server, $in{'gw'}, $in{'gwdev'});
	}
&error($err) if ($err);

# Apply the change for IPv6
if (defined(&$cfunc) && &$c6func($server) && defined($in{'gw6_def'})) {
	if ($in{'gw6_def'}) {
		$err = &modify_default_ipv6_gateway(
			$server, undef, undef);
		}
	else {
		$err = &modify_default_ipv6_gateway(
			$server, $in{'gw6'}, $in{'gwdev6'});
		}
	&error($err) if ($err);
	}

&check_server_status($server, 0, 1);
&save_managed_server($server);
&release_lock_server($server);
&webmin_log("gateway", "server", $server->{'host'},
	    { 'gw' => $in{'gw_def'} ? undef : $in{'gw'},
	      'gwdev' => $in{'gwdev'} });

&redirect("list_ifaces.cgi?id=$in{'id'}&refresh=1");

