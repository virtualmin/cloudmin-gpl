#!/usr/local/bin/perl
# Show an applet for VNC access to a virtual system's console

require './server-manager-lib.pl';
use Socket;
&ReadParse();
$server = &get_managed_server($in{'id'});
$server || &error($text{'edit_egone'});
&can_action_error($server, "console");
$server->{'status'} ne 'down' && $server->{'status'} ne 'nohost' ||
	&error($text{'vnc_edown'});

&ui_print_header(&server_in($server), $text{'vnc_title'}, "");

# Figure out which mode we're in (flash, java or noVNC)
$mode = $in{'novnc'} ? 2 : $in{'flash'} ? 1 : $in{'java'} ? 0 : $config{'flash_vnc'};
$sfunc = "type_".$server->{'manager'}."_supports_websockets";
if ($mode == 2 && !&$sfunc($server)) {
	$mode = 0;
	}

# Get the VNC port
$vfunc = "type_".$server->{'manager'}."_open_vnc_port";
($masterport, $pass, $wsmasterport, $wsencrypt,
 $hostip, $hostport, $wshostport) = &$vfunc($server, $mode);
$masterport || $wsmasterport || &error($pass);

# Ouput applet, flash or JS HTML
($masterhost) = split(/:/, $ENV{'HTTP_HOST'});
print &vnc_client_html($masterhost, $masterport, $pass,
	       $mode, $server, "gvnc.cgi", $wsmasterport, $wsencrypt,
	       $hostip, $hostport, $wshostport);

ENDPAGE:
&ui_print_footer("edit_serv.cgi?id=$in{'id'}", $text{'edit_return'});

