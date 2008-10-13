#!/usr/local/bin/perl
# Show network interfaces on some system

require './server-manager-lib.pl';
&ReadParse();

# Get and check system
@servers = &list_managed_servers();
($server) = grep { $_->{'id'} == $in{'id'} } @servers;
$server || &error($text{'edit_egone'});
$t = $server->{'manager'};
&can_action($server, "edit") || &can_action_error($server, "view");

&ui_print_header(&server_in($server), $text{'ifaces_title'}, "", "ifaces");

# IP addresses, if we can manage them
$ifunc = "type_".$t."_list_interfaces";
$cfunc = "type_".$t."_can_interfaces";
$ifaces = &$ifunc($server);
@ilinks = ( );
if (&can_action($server, "ifaces")) {
	@ilinks = ( "<a href='edit_iface.cgi?id=$in{'id'}&new=1'>".
		    "$text{'edit_ifaceadd'}</a>" );
	}
print &ui_links_row(\@ilinks);
print &ui_columns_start([ $text{'edit_ifaceaddress'},
			  $text{'edit_ifacename'},
			  $text{'edit_ifacenumber'},
			  $text{'edit_ifacenetmask'},
			  $info ? ( $text{'edit_ifaceuse'} ) : ( ) ],
			100);
$n = 0;
foreach $iface (@$ifaces) {
	if ($info) {
		($ucode, $use) = &get_interface_use($server, $info,
						    \@doms, $iface);
		}
	print &ui_columns_row([
		$iface->{'noedit'} || !&can_action($server, "ifaces") ?
		    $iface->{'address'} :
		    "<a href='edit_iface.cgi?id=$in{'id'}&idx=$n'>".
		    "$iface->{'address'}</a>",
		$iface->{'name'},
		$iface->{'virtual'} eq '' ?
		 "<i>$text{'edit_ifacereal'}</i>" : $iface->{'virtual'},
		$iface->{'netmask'},
		$info ? ( $use ) : ( ),
		]);
	$n++;
	}
print &ui_columns_end();
print &ui_links_row(\@ilinks);

&ui_print_footer("edit_serv.cgi?id=$in{'id'}", $text{'edit_return'});

if (defined(&theme_select_server)) {
	&theme_select_server($server);
	}

