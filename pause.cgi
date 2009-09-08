#!/usr/local/bin/perl
# Actually pause a virtual system

require './server-manager-lib.pl';
&ReadParse();
$server = &get_managed_server($in{'id'});
$server || &error($text{'edit_egone'});
&can_action_error($server, "pause");

# Can we actually pause?
$cfunc = "type_".$server->{'manager'}."_can_pause";
defined(&$cfunc) && &$cfunc($server) == 1 || &error($text{'pause_ecannot'});

&ui_print_unbuffered_header(&server_in($server), $text{'pause_title'}, "");
&obtain_lock_server($server);

$dfunc = "type_".$server->{'manager'}."_desc";
&$first_print(&text('pause_doing', &$dfunc(), "<tt>$server->{'host'}</tt>"));
$pfunc = "type_".$server->{'manager'}."_pause_system";
$err = &$pfunc($server);
if ($err) {
	&$second_print(&text('pause_failed', $err));
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
&webmin_log("pause", "server", $server->{'host'});

&ui_print_footer("", $text{'index_return'});
