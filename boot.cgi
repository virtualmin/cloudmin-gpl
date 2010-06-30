#!/usr/local/bin/perl
# Change the boot mode for a system

require './server-manager-lib.pl';
&ReadParse();
&error_setup($text{'boot_err'});
$server = &get_managed_server($in{'id'});
$server || &error($text{'mkimage_egone'});
&can_action_error($server, "boot");

# Validate inputs
$lfunc = "type_".$server->{'manager'}."_list_boot_modes";
$modes = &$lfunc($server);
ref($modes) || &error($modes);
($canmode) = grep { $_->{'id'} eq $in{'mode'} } @$modes;
$canmode || &error($text{'boot_emode'});

&ui_print_unbuffered_header(&server_in($server), $text{'boot_title'}, "");
&obtain_lock_server($server);

&$first_print(&text('boot_moding', $canmode->{'desc'}));
$mfunc = "type_".$server->{'manager'}."_set_boot_mode";
$err = &$mfunc($server, $in{'mode'});
if ($err) {
	&$second_print(&text('boot_modefailed', $err));
	}
else {
	&$second_print($text{'create_done'});

	# Reboot if requested
	if ($in{'reboot'}) {
		&$first_print($text{'mkimage_shutdown'});
		$err = &shutdown_system($server);
		if ($err) {
			&$second_print(&text('mkimage_eshutdown', $err));
			}
		else {
			}
		# XXX

		# XXX down and up again
		}

	# Refresh status
	&$first_print($text{'save_refreshing'});
	&check_server_status($server, 0, 1);
	&save_managed_server($server);
	&$second_print(&text('save_refreshdone2', &describe_status($server)));
	}

&release_lock_server($server);
&webmin_log("boot", "server", $server->{'host'});
if (defined(&theme_select_server)) {
	&theme_select_server($newserver);
	}

&ui_print_footer("edit_serv.cgi?id=$in{'id'}", $text{'edit_return'});

