#!/usr/local/bin/perl
# Show an SSH applet for logging into a system's console

require './server-manager-lib.pl';
&ReadParse();
($server) = grep { $_->{'id'} == $in{'id'} } &list_managed_servers();
$server || &error($text{'edit_egone'});
&can_action_error($server, "console");
&ui_print_header(&server_in($server), $text{'login_title'}, "");

# Setup user if needed
$clfunc = "type_".$server->{'manager'}."_supports_console_login";
$ok = &$clfunc($server);
if ($ok == -1) {
	$err = &create_console_user($server);
	$err && &error(&text('login_euser', $err));
	&save_managed_server($server);
	}
elsif ($ok == 0) {
	&error($text{'login_esupport'});
	}

# Get and check SSH config
($host, $port, $protos) = &get_ssh_host_port();
if (&indexof("1", @$protos) < 0) {
	# No SSH 1 support in server :-(
	print &text('login_essh1'),"<p>\n";
	if (&foreign_available("sshd")) {
		print &text('login_sshlink', "../sshd/edit_net.cgi"),"<p>\n";
		}
	print &ui_hr();
	print $text{'login_sshcmd'},"\n";
	print "<pre>ssh $server->{'login_user'}\@$host</pre>\n";
	print &text('login_sshpasswd',
		"<tt>$server->{'login_pass'}</tt>"),"<p>\n";
	}
else {
	# Create the SSH applet
	print <<EOF;
<applet archive=jta26.jar code=de.mud.jta.Applet
 width=100% height=90%>
<param name=config value="sshconf.cgi?id=$server->{'id'}">
<param name=Socket.host value=$host>
<param name=Socket.port value=$port>
$text{'login_nojava'}
</applet>
EOF
	}

&ui_print_footer("edit_serv.cgi?id=$in{'id'}", $text{'edit_return'});
