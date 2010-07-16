#!/usr/local/bin/perl
# Change the boot mode for a system

require './server-manager-lib.pl';
&ReadParse();
&error_setup($text{'boot_err'});
$server = &get_managed_server($in{'id'});
$server || &error($text{'mkimage_egone'});
&can_action_error($server, "boot");

# Validate inputs
if ($in{'mode'}) {
	$lfunc = "type_".$server->{'manager'}."_list_boot_modes";
	$modes = &$lfunc($server);
	ref($modes) || &error($modes);
	($canmode) = grep { $_->{'id'} eq $in{'mode'} } @$modes;
	$canmode || &error($text{'boot_emode'});
	}
if ($in{'device'}) {
	$lfunc = "type_".$server->{'manager'}."_list_boot_devices";
	$devices = &$lfunc($server);
	ref($devices) || &error($devices);
	foreach $d (split(/\0/, $in{'device'})) {
		($candevice) = grep { $_->{'id'} eq $d } @$devices;
		$candevice || &error($text{'boot_edevice'});
		push(@candevices, $candevice);
		}
	}

&ui_print_unbuffered_header(&server_in($server), $text{'boot_title'}, "");
&obtain_lock_server($server);

# Change boot method
if ($in{'mode'}) {
	&$first_print(&text('boot_moding', "<i>$canmode->{'desc'}</i>"));
	$mfunc = "type_".$server->{'manager'}."_set_boot_mode";
	$err = &$mfunc($server, $in{'mode'});
	if ($err) {
		&$second_print(&text('boot_modefailed', $err));
		}
	else {
		&$second_print($text{'create_done'});
		}
	}

# Change boot device(s)
if ($in{'device'} && !$err) {
	&$first_print(&text('boot_devicing',
		join(", ", map { "<i>$_->{'desc'}</i>" } @candevices)));
	$dfunc = "type_".$server->{'manager'}."_set_boot_device";
	$err = &$dfunc($server, $in{'device_multi'} ?
				[ split(/\0/, $in{'device'}) ] : $in{'device'});
	if ($err) {
		&$second_print(&text('boot_devicefailed', $err));
		}
	else {
		&$second_print($text{'create_done'});
		}
	}

if (!$err) {
	# Reboot if requested
	if ($in{'reboot'}) {
		&$first_print($text{'mkimage_shutdown'});
		$err = &shutdown_server($server);
		if ($err) {
			&$second_print(&text('mkimage_eshutdown', $err));
			}
		else {
			&$second_print($text{'create_done'});
			}

		&$first_print($text{'mkimage_startup'});
		$err = &startup_server($server);
		if ($err) {
			&$second_print(&text('mkimage_estartup', $err));
			}
		else {
			&$second_print($text{'create_done'});
			}
		}

	# Refresh status
	&$first_print($text{'save_refreshing'});
	&check_server_status($server, 0, 1);
	&save_managed_server($server);
	&$second_print(&text('save_refreshdone2',
			     &describe_status($server, 1)));
	}

&release_lock_server($server);
&webmin_log("boot", "server", $server->{'host'});
if (defined(&theme_select_server)) {
	&theme_select_server($server);
	}
if (defined(&theme_post_save_server)) {
	&theme_post_save_server($server);
	}

&ui_print_footer("edit_serv.cgi?id=$in{'id'}", $text{'edit_return'});

