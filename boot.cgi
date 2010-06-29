#!/usr/local/bin/perl
# Change the boot mode for a system

require './server-manager-lib.pl';
&ReadParse();
&error_setup($text{'boot_err'});
$server = &get_managed_server($in{'id'});
$server || &error($text{'mkimage_egone'});
&can_action_error($server, "boot");

# Validate inputs
# XXX

&ui_print_unbuffered_header(&server_in($server), $text{'boot_title'}, "");
&obtain_lock_server($server);

# XXX do it

# Reboot if requested
# XXX only if changed
# XXX down and up again

&release_lock_server($server);
&webmin_log("boot", "server", $server->{'host'});
if (defined(&theme_select_server)) {
	&theme_select_server($newserver);
	}

&ui_print_footer("edit_serv.cgi?id=$in{'id'}", $text{'edit_return'});

