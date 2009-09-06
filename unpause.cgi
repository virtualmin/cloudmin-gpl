#!/usr/local/bin/perl
# Resume a paused system

require './server-manager-lib.pl';
&ReadParse();
$server = &get_managed_server($in{'id'});
$server || &error($text{'edit_egone'});
&can_action_error($server, "pause");

# Can we actually un-pause?
$cfunc = "type_".$server->{'manager'}."_can_pause";
defined(&$cfunc) && &$cfunc($server) == 2 || &error($text{'unpause_ecannot'});

&ui_print_unbuffered_header(&server_in($server), $text{'unpause_title'}, "");
&obtain_lock_server($server);

$dfunc = "type_".$server->{'manager'}."_desc";
&$first_print(&text('unpause_doing', &$dfunc(), "<tt>$server->{'host'}</tt>"));
$pfunc = "type_".$server->{'manager'}."_unpause_system";
$err = &$pfunc($server);
if ($err) {
	&$second_print(&text('unpause_failed', $err));
	}
else {
	&check_server_status($server, 0, 1);
	&$second_print($text{'create_done'});
	}
&save_managed_server($server);

if (defined(&theme_post_save_server)) {
	&theme_post_save_server($server);
	}
&release_lock_server($server);

&ui_print_footer("", $text{'index_return'});
