#!/usr/local/bin/perl
# Create, update or delete a network interface

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


