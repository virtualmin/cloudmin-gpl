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

# Create the SSH applet
# XXX how to auto-login?
print <<EOF;
<applet archive=../telnet/jta25.jar code=de.mud.jta.Applet
 width=100% height=90%>
<param name=config value=../telnet/ssh.conf>
$text{'login_nojava'}
</applet>
EOF

&ui_print_footer("", $text{'index_return'});

