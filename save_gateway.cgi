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
if (!$in{'gw_def'}) {
	&check_ipaddress($in{'gw'}) || &error($text{'ifaces_egw'});
	($iface) = grep { $_->{'fullname'} eq $in{'gwdev'} } @$ifaces;
	$iface || &error($text{'ifaces_egwdev'});
	}

# Apply the change
if ($in{'gw_def'}) {
	$err = &modify_default_gateway($server, undef, undef);
	}
else {
	$err = &modify_default_gateway($server, $in{'gw'}, $in{'gwdev'});
	}
&error($err) if ($err);
&save_managed_server($server);
&release_lock_server($server);
&webmin_log("gateway", "server", $server->{'host'},
	    { 'gw' => $in{'gw_def'} ? undef : $in{'gw'},
	      'gwdev' => $in{'gwdev'} });

&redirect("list_ifaces.cgi?id=$in{'id'}");

