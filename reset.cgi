#!/usr/local/bin/perl
# Reset a virtual system to it's original image

require './server-manager-lib.pl';
&ReadParse();
&error_setup($text{'reset_err'});
$server = &get_managed_server($in{'id'});
$server || &error($text{'edit_egone'});
&can_action_error($server, "reset");

# Check the reset
$cfunc = "type_".$server->{'manager'}."_can_reset";
&$cfunc($server) || &error($text{'reset_ereset'});

&ui_print_unbuffered_header(&server_in($server), $text{'reset_title'}, "");
&obtain_lock_server($server);
$server->{'image'} = $in{'image'};
$img = &get_server_image($server->{'image'});
$img && &can_image($img) || &error($text{'reset_eimage'});
if ($img->{'type'}) {
	$server->{'type'} = $img->{'type'};
	}

# Call the reset function
$dfunc = "type_".$server->{'manager'}."_desc";
$desc = &$dfunc();
print "<b>",&text('reset_doing', $desc,
	  "<tt>$server->{'host'}</tt>", "<i>$img->{'desc'}</i>"),"</b><p>\n";
$err = &reset_system($server);
if ($err) {
	print "<b>$err</b><p>\n";
	}
else {
	print "<b>$text{'create_done'}</b><p>\n";
	}
&release_lock_server($server);
&webmin_log("reset", "server", $server->{'host'});

if (defined(&theme_post_save_server)) {
	&theme_post_save_server($server);
	}

&ui_print_footer("edit_serv.cgi?id=$in{'id'}", $text{'edit_return'});
