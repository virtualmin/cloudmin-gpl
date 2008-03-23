#!/usr/local/bin/perl
# Add, modify or remote a virtual disk

require './server-manager-lib.pl';
&ReadParse();
@servers = &list_managed_servers();
&error_setup($text{'disk_err'});
($server) = grep { $_->{'id'} == $in{'id'} } @servers;
$server || &error($text{'edit_egone'});

# Get the disk
$lfunc = "type_".$server->{'manager'}."_list_disks";
$disks = &$lfunc($server, 1);
ref($disks) || &error($disks);
if (!$in{'new'}) {
	($disk) = grep { $_->{'real'} eq $in{'oldreal'} } @$disks;
	$disk || &error($text{'disk_egone'});
	$olddisk = { %$disk };
	}

if ($in{'delete'}) {
	# Remove the disk, after asking for confirmation
	&ui_print_header(&server_in($server), $text{'disk_titled'}, "");
	if ($in{'confirm'}) {
		# Do it
		&$first_print(&text('disk_deleting',
				    "<tt>$disk->{'real'}</tt>"));
		$dfunc = "type_".$server->{'manager'}."_delete_disk";
		$err = &$dfunc($server, $disk);
		if ($err) {
			&$second_print(&text('disk_deletefailed', $err));
			}
		else {
			&$second_print(&text('disk_deletedok'));
			&show_disk_reboot_message($server, $disk);
			}
		}
	else {
		# Ask first
		print "<center>\n";
		print &ui_form_start("save_disk.cgi");
		print &ui_hidden("id", $in{'id'});
		print &ui_hidden("oldreal", $in{'oldreal'});
		print &ui_hidden("delete", 1);
		$desc = "<tt>$disk->{'real'}</tt>";
		if ($disk->{'device'}) {
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
else {
	# Validate inputs, and update the disk hash
	if ($in{'new'}) {
		$disk = { };
		}

	# Real disk device
	if ($in{'new'} == 2) {
		# From device menu
		if ($in{'real'}) {
			$disk->{'real'} = $in{'real'};
			}
		else {
			$in{'other'} =~/^\/\S+$/ || &error($text{'disk_ereal'});
			$disk->{'real'} = $in{'other'};
			}
		}
	else {
		# Just from text box
		$in{'real'} =~ /^\/\S+$/ || &error($text{'disk_ereal'});
		$disk->{'real'} = $in{'real'};
		}
	if ($in{'new'}) {
		$disk->{'device'} = ($disk->{'real'} =~ /^\/dev\//);
		}

	# Device on virtual system
	$in{'virt'} =~ /^\/\S+$/ || &error($text{'disk_evirt'});
	$disk->{'virt'} = $in{'virt'};

	# New or current size
	if (defined($in{'size'})) {
		$in{'size'} =~ /^\d+$/ || &error($text{'disk_esize'});
		$disk->{'size'} = $in{'size'}*$in{'size_units'};
		}

	# New filesystem and mount point
	if ($in{'new'}) {
		$disk->{'fs'} = $in{'fs'};
		if ($in{'mount_def'} == 0) {
			$in{'mount'} =~ /^\/\S+$/ ||
				&error($text{'disk_emount'});
			$disk->{'mount'} = $in{'mount'};
			}
		elsif ($in{'mount_def'} == 1) {
			$in{'fs'} eq 'swap' || $in{'new'} == 2 ||
				&error($text{'disk_eswap'});
			}
		}

	if ($in{'new'}) {
		# Create the disk
		&ui_print_header(&server_in($server), $text{'disk_titlec'}, "");
		&$first_print(&text('disk_creating',
				    "<tt>$disk->{'real'}</tt>"));
		$cfunc = "type_".$server->{'manager'}."_create_disk";
		$err = &$cfunc($server, $disk);
		if ($err) {
			&$second_print(&text('disk_createfailed', $err));
			}
		else {
			&$second_print(&text('disk_createok'));
			&show_disk_reboot_message($server, $disk);
			}
		}
	else {
		# Modify the size or devices, if we can
		&ui_print_header(&server_in($server), $text{'disk_titlem'}, "");
		&$first_print(&text('disk_modifying',
				    "<tt>$disk->{'real'}</tt>"));
		$cfunc = "type_".$server->{'manager'}."_modify_disk";
		$err = &$cfunc($server, $disk, $olddisk);
		if ($err) {
			&$second_print(&text('disk_modifyfailed', $err));
			}
		else {
			&$second_print(&text('disk_modifyok'));
			&show_disk_reboot_message($server, $disk);
			}
		}

	&ui_print_footer("list_disks.cgi?id=$in{'id'}", $text{'disks_return'},
			 "", $text{'index_return'});
	}


