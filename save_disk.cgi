#!/usr/local/bin/perl
# Add, modify or remote a virtual disk

require './server-manager-lib.pl';
&ReadParse();
&error_setup($text{'disk_err'});
&error_if_cloudmin_replica();
$server = &get_managed_server($in{'id'});
$server || &error($text{'edit_egone'});
$vhost = &get_parent_server($server);
&check_server_status($server, 0, 1);	# In case state has changed
&can_action_error($server, "disks");
&obtain_lock_server($server);

# Get the disk
$lfunc = "type_".$server->{'manager'}."_list_disks";
$disks = &$lfunc($server, 1);
if (!ref($disks)) {
	# Try again without asking for mounts
	$disks = &$lfunc($server, 0);
	}
ref($disks) || &error($disks);
if (!$in{'new'}) {
	($disk) = grep { $_->{'real'} eq $in{'oldreal'} } @$disks;
	$disk || &error($text{'disk_egone'});
	$olddisk = { %$disk };
	$r = $disk->{'realdesc'} || $disk->{'real'};
	}

if ($in{'delete'}) {
	# Remove the disk, after asking for confirmation
	&ui_print_header(&server_in($server), $text{'disk_titled'}, "");
	if ($in{'confirm'}) {
		# Do it
		&$first_print(&text('disk_deleting', "<tt>$r</tt>"));
		$dfunc = "type_".$server->{'manager'}."_delete_disk";
		$err = &$dfunc($server, $disk);
		if ($err) {
			&$second_print(&text('disk_deletefailed', $err));
			}
		else {
			&$second_print(&text('disk_deletedok'));
			&show_disk_reboot_message($server, $disk);
			}
		&save_managed_server($server);
		&webmin_log("delete", "disk", $server->{'host'},
			    { 'real' => $disk->{'real'} });
		}
	else {
		# Ask first
		print "<center>\n";
		print &ui_form_start("save_disk.cgi");
		print &ui_hidden("id", $in{'id'});
		print &ui_hidden("oldreal", $in{'oldreal'});
		print &ui_hidden("delete", 1);
		$desc = "<tt>$r</tt>";
		if ($disk->{'device'} &&
		    !$disk->{'lv'} && !$disk->{'storage'}) {
			print &text('disk_rusure2', $desc),"<p>\n";
			}
		else {
			print &text('disk_rusure', $desc,
				    &nice_size($disk->{'size'})),"<p>\n";
			}
		if ($disk->{'mount'} && $disk->{'fs'} ne 'swap') {
			print &text('disk_rusuremount',
				    "<tt>$disk->{'mount'}</tt>",
				    uc($disk->{'fs'})),"<p>\n";
			}
		print &ui_form_end([ [ "confirm", $text{'disk_deleteok'} ] ]);
		print "</center>\n";
		}
	&ui_print_footer("list_disks.cgi?id=$in{'id'}", $text{'disks_return'},
			 "", $text{'index_return'});
	}
elsif ($in{'detach'}) {
	# Detach from system, after asking first
	&ui_print_header(&server_in($server), $text{'disk_titledt'}, "");
	if ($in{'confirm'}) {
		# Do it
		&$first_print(&text('disk_detaching',
				    "<tt>$r</tt>"));
		$dfunc = "type_".$server->{'manager'}."_delete_disk";
		$err = &$dfunc($server, $disk, 1);
		if ($err) {
			&$second_print(&text('disk_detachfailed', $err));
			}
		else {
			&$second_print(&text('disk_detachedok'));
			&show_disk_reboot_message($server, $disk);
			}
		&save_managed_server($server);
		&webmin_log("detach", "disk", $server->{'host'},
			    { 'real' => $disk->{'real'} });
		}
	else {
		# Ask first
		print "<center>\n";
		print &ui_form_start("save_disk.cgi");
		print &ui_hidden("id", $in{'id'});
		print &ui_hidden("oldreal", $in{'oldreal'});
		print &ui_hidden("detach", 1);
		$desc = "<tt>$r</tt>";
		print &text('disk_rusure3', $desc),"<p>\n";
		if ($disk->{'mount'} && $disk->{'fs'} ne 'swap') {
			print &text('disk_rusuremount',
				    "<tt>$disk->{'mount'}</tt>",
				    uc($disk->{'fs'})),"<p>\n";
			}
		print &ui_form_end([ [ "confirm", $text{'disk_detachok'} ] ]);
		print "</center>\n";
		}
	&ui_print_footer("list_disks.cgi?id=$in{'id'}", $text{'disks_return'},
			 "", $text{'index_return'});

	}
elsif ($in{'fsck'}) {
	# Check the disk
	&ui_print_header(&server_in($server), $text{'fsck_title'}, "");

	&$first_print(&text('fsck_doing', uc($disk->{'fs'}),
					  "<tt>$r</tt>"));
	$ffunc = "type_".$server->{'manager'}."_fsck_disk";
	($ok, $out) = &$ffunc($server, $disk);
	&$block_print($out);
	&$second_print($ok == 0 ? $text{'fsck_bad'} :
		       $ok == 1 ? $text{'fsck_ok'} : $text{'fsck_fixed'});

	&ui_print_footer("list_disks.cgi?id=$in{'id'}", $text{'disks_return'},
			 "", $text{'index_return'});
	}
else {
	# Validate inputs, and update the disk hash

	# Storage location
	$sfunc = "type_".$server->{'manager'}."_list_storages";
	if (defined(&$sfunc) && defined($in{'storage'}) &&
	    &can_action($server, "storage")) {
		$storages = &$sfunc($vhost);
		ref($storages) || &error($storages);
		($gotstorage) = grep { $_->{'id'} eq $in{'storage'}} @$storages;
		$gotstorage || &error($text{'disk_estorage'});
		}

	# Create initial disk object
	if ($in{'new'}) {
		$nfunc = "type_".$server->{'manager'}."_new_disk";
		if (defined(&$nfunc)) {
			$disk = &$nfunc($server, $disks, $in{'new'} == 2,
					$gotstorage);
			}
		else {
			$disk = { };
			}
		}

	# Real disk device
	if ($disk->{'fixedreal'}) {
		# Do nothing, as no real device is needed
		}
	elsif ($in{'new'} == 2) {
		# From device menu
		if ($in{'real'}) {
			$disk->{'real'} = $in{'real'};
			}
		else {
			$in{'other'} =~/^\/\S+$/ || &error($text{'disk_ereal'});
			$disk->{'real'} = $in{'other'};
			}
		}
	elsif ($in{'new'} == 1 && &can_action($server, "devices")) {
		if ($disk->{'vg'}) {
			# From LV name text box
			$in{'lv'} =~ /^[A-Za-z0-9\.\-\_]+$/ ||
				&error($text{'disk_elv'});
			$disk->{'lv'} = $in{'lv'};
			$disk->{'real'} = '/dev/'.$disk->{'vg'}.
					  '/'.$disk->{'lv'};
			}
		else {
			# From image file text box
			$in{'real'} =~ /^\/\S+$/ || &error($text{'disk_ereal'});
			$disk->{'real'} = $in{'real'};
			}
		$disk->{'overwrite'} = $in{'overwrite'};
		}
	if ($in{'new'}) {
		$disk->{'device'} = ($disk->{'real'} =~ /^\/dev\//);
		}

	# Device on virtual system
	$in{'virt'} =~ /^\/\S+$/ || &error($text{'disk_evirt'});
	$disk->{'virt'} = $in{'virt'};

	# New or current size. Make sure it comes in under the owner's limit,
	# and the host's free space.
	if (defined($in{'size'})) {
		$in{'size'} =~ /^\d+$/ || &error($text{'disk_esize'});
		$incr = $in{'size'}*$in{'size_units'};
		if (!$in{'new'}) {
			$incr -= $disk->{'size'};
			}
		$limits = &get_owner_limits();
		if ($limits && $limits->{'max_disk'} &&
		    $limits->{'disk'} + $incr > $limits->{'max_disk'}) {
			&error(&text('disk_elimit',
			       &nice_size($limits->{'max_disk'}),
			       &nice_size($limits->{'disk'})));
			}
		$hostfree = &host_free_disk($vhost, $server->{'manager'},
					    $server);
		if ($hostfree && $incr > $hostfree) {
			&error(&text('disk_ehostlimit',
				     &nice_size($hostfree)));
			}
		$disk->{'size'} = $in{'size'}*$in{'size_units'};
		}

	# Disk media
	$mfunc = "type_".$server->{'manager'}."_list_disk_medias";
	if (defined(&$mfunc) && defined($in{'media'})) {
		$medias = &$mfunc($server, $disk);
		ref($medias) || &error($medias);
		($gotmedia) = grep { $_->{'id'} eq $in{'media'} } @$medias;
		$gotmedia || &error($text{'disk_emedia'});
		$disk->{'media'} = $in{'media'};
		}

	# New filesystem and mount point
	if ($in{'new'}) {
		$disk->{'fs'} = $in{'fs'};
		if ($in{'mount_def'} == 0) {
			$in{'mount'} =~ /^\/\S+$/ ||
				&error($text{'disk_emount'});
			$disk->{'mount'} = $in{'mount'};
			}
		elsif ($in{'mount_def'} == 2) {
			$in{'fs'} eq 'swap' || $in{'new'} == 2 ||
				&error($text{'disk_eswap'});
			$disk->{'mount'} = 'swap';
			}
		}

	$wfunc = "type_".$server->{'manager'}."_can_safely_resize_disk";
	if ($in{'new'}) {
		# Create the disk
		&ui_print_header(&server_in($server), $text{'disk_titlec'}, "");
		if ($disk->{'fixedreal'}) {
			&$first_print(&text('disk_creating2'));
			}
		elsif ($in{'new'} == 2) {
			&$first_print(&text('disk_creating3',
					    "<tt>$disk->{'real'}</tt>"));
			}
		else {
			&$first_print(&text('disk_creating',
					    "<tt>$disk->{'real'}</tt>"));
			}
		$cfunc = "type_".$server->{'manager'}."_create_disk";
		$err = &$cfunc($server, $disk, scalar(@$disks) ? 0 : 1);
		&save_disk_include($server, $disk, $in{'include'});
		&save_managed_server($server);
		if ($err) {
			&$second_print(&text('disk_createfailed', $err));
			}
		else {
			&$second_print(&text('disk_createok'));
			&show_disk_reboot_message($server, $disk);
			&webmin_log("create", "disk", $server->{'host'},
				    { 'real' => $disk->{'real'} });
			}
		}
	elsif (!$in{'force'} &&
	       $disk->{'size'} != $olddisk->{'size'} &&
	       defined(&$wfunc) &&
	       ($err = &$wfunc($server, $disk))) {
		# Show a warning before resizing
		&ui_print_header(&server_in($server), $text{'disk_titlem'}, "");

		print &ui_confirmation_form(
			"save_disk.cgi",
			$text{'disk_sizewarn'}."\n".$err,
			[ map { [ $_, $in{$_} ] } keys %in ],
			[ [ "force", $text{'disk_sizeok'} ] ],
			);
		}
	else {
		# Modify the size or devices, if we can
		&ui_print_header(&server_in($server), $text{'disk_titlem'}, "");
		&$first_print(&text('disk_modifying',
				    "<tt>$disk->{'real'}</tt>"));
		$cfunc = "type_".$server->{'manager'}."_modify_disk";
		$err = &$cfunc($server, $disk, $olddisk);
		&save_disk_include($server, $disk, $in{'include'});
		&save_managed_server($server);
		if ($err) {
			&$second_print(&text('disk_modifyfailed', $err));
			}
		else {
			&$second_print(&text('disk_modifyok'));
			&show_disk_reboot_message($server, $disk);
			&webmin_log("modify", "disk", $server->{'host'},
				    { 'real' => $disk->{'real'} });
			}
		}

	&ui_print_footer("list_disks.cgi?id=$in{'id'}", $text{'disks_return'},
			 "", $text{'index_return'});
	}

&release_lock_server($server);

