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

# Get the VNC port
$vfunc = "type_".$server->{'manager'}."_open_vnc_port";
($masterport, $pass) = &$vfunc($server);
$masterport || &error($pass);

# Ouput applet HTML
($masterhost) = split(/:/, $ENV{'HTTP_HOST'});
print &vnc_client_html($masterhost, $masterport, $pass,
		       \%in, $server, "gvnc.cgi");

ENDPAGE:
&ui_print_footer("edit_serv.cgi?id=$in{'id'}", $text{'edit_return'});

