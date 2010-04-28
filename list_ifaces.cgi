#!/usr/local/bin/perl
# Show network interfaces on some system

require './server-manager-lib.pl';
&ReadParse();

# Get and check system
$server = &get_managed_server($in{'id'});
$server || &error($text{'edit_egone'});
$t = $server->{'manager'};
&can_action_error($server, "ifaces");
$cfunc = "type_".$t."_can_interfaces";
$can = &$cfunc($server);
$can || &error($text{'iface_esupport'});

&ui_print_header(&server_in($server), $text{'ifaces_title'}, "", "ifaces");

# IP addresses, if we can manage them
$ifunc = "type_".$t."_list_interfaces";
$ifaces = &$ifunc($server);
@ilinks = ( );
if (&can_action($server, "ifaces")) {
	# Link to add
	@ilinks = ( "<a href='edit_iface.cgi?id=$in{'id'}&new=1'>".
		    "$text{'edit_ifaceadd'}</a>" );
	if (&can_action($server, "realifaces") && $can == 2) {
		# Link to real
		push(@ilinks, "<a href='edit_iface.cgi?id=$in{'id'}&new=2'>".
			      "$text{'edit_ifaceaddreal'}</a>");
		}
	}
print &ui_links_row(\@ilinks);
print &ui_columns_start([ $text{'edit_ifaceaddress'},
			  $can == 1 ? $text{'edit_ifacename'}
				    : $text{'edit_ifacename2'},
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

# Show default gateway form if possible
$gcfunc = "type_".$t."_can_gateway";
if ($can && defined(&$gcfunc) && &$gcfunc($server)) {
	($gw, $gwdev) = &get_server_default_gateway($server);

	print &ui_hr();
	print $text{'ifaces_gwdesc'},"<p>\n";
	print &ui_form_start("save_gateway.cgi", "post");
	print &ui_hidden("id", $in{'id'});
	print &ui_table_start($text{'ifaces_gwheader'}, undef, 2);

	print &ui_table_row($text{'ifaces_gw'},
		&ui_opt_textbox("gw", $gw, 20, $text{'ifaces_gwnone'},
				$text{'ifaces_gwset'}));

	print &ui_table_row($text{'ifaces_gwdev'},
		&ui_select("gwdev", $gwdev,
			   [ map { $_->{'fullname'} }
				grep { $_->{'virtual'} eq '' } @$ifaces ]));

	print &ui_table_end();
	print &ui_form_end([ [ undef, $text{'save'} ] ]);
	}

&ui_print_footer("edit_serv.cgi?id=$in{'id'}", $text{'edit_return'});

if (defined(&theme_select_server)) {
	&theme_select_server($server);
	}

