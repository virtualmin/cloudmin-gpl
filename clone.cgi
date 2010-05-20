#!/usr/local/bin/perl
# Actually create a new system image

require './server-manager-lib.pl';
&ReadParse();
&error_setup($text{'clone_err'});
$server = &get_managed_server($in{'id'});
$server || &error($text{'mkimage_egone'});
&can_create_server_error($server->{'manager'});

# Check if clonable
$dfunc = "type_".$server->{'manager'}."_desc";
$desc = &$dfunc();
$cfunc = "type_".$server->{'manager'}."_can_clone";
defined(&$cfunc) || &error(&text('clone_ecan', $desc));
&$cfunc($server) || &error($text{'clone_ecan2'});

# Validate inputs
# XXX

# Validate owner resource limits
# XXX

&ui_print_unbuffered_header(&server_in($server), $text{'clone_title'}, "");
&obtain_lock_server($server);

&$first_print(&text('clone_doing', $desc, $server->{'host'}, $in{'host'}));
&$indent_print();
($newserver, $err) = &clone_system($server, $in{'host'}, $in{'desc'});
&$outdent_print();
&release_lock_server($server);
if ($newserver && $err) {
	&$second_print($err);
	&$second_print(&text('clone_partial', $newserver->{'host'}));
	}
elsif ($newserver && !$err) {
	&$second_print(&text('clone_done', $newserver->{'host'}));
	}
elsif (!$newserver && $err) {
	&$second_print($err);
	}

&release_lock_server($server);
if ($newserver) {
	&webmin_log("clone", "server", $server->{'host'},
		    'cmd' => $newserver->{'host'});
	}
&ui_print_footer("edit_serv.cgi?id=$in{'id'}", $text{'edit_return'});

