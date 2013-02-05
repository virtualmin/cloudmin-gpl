#!/usr/local/bin/perl
# Actually create a new system image

require './server-manager-lib.pl';
&ReadParse();
&error_setup($text{'mkimage_err'});
$server = &get_managed_server($in{'id'});
$server || &error($text{'mkimage_egone'});
&can_action_error($server, "image");

# Validate inputs
if (!$in{'imageid_def'} || !defined($in{'oldid'})) {
	# Creating a new image ID
	$in{'imageid'} =~ /^\S+$/ || &error($text{'mkimage_eid'});
	($clash) = grep { $_->{'id'} eq $in{'imageid'} } &list_server_images();
	$clash && &error($text{'mkimage_eclash'});
	$imageid = $in{'imageid'};
	}
else {
	# Over-writing old
	$imageid = $in{'oldid'};
	($clash) = grep { $_->{'id'} eq $in{'oldid'} } &list_server_images();
	$clash || &error($text{'mkimage_eclash2'});
	}

# Create initial image hash
$image = { 'id' => $imageid,
	   'manager' => $server->{'manager'},
	   'nocompress' => !$in{'compress'},
	   'type' => $server->{'type'},
	 };
if ($in{'version_def'} == 1) {
	$image->{'version'} = $in{'version'};
	}
elsif ($in{'version_def'} == 2) {
	$clash && $clash->{'version'} || &error($text{'mkimage_einc'});
	$image->{'version'} = $clash->{'version'} + 0.1;
	}
if ($in{'desc_def'}) {
	$clash && $clash->{'desc'} || error($text{'mkimage_edesc2'});
	$image->{'desc'} = $clash->{'desc'};
	}
else {
	$in{'desc'} =~ /\S/ || &error($text{'mkimage_edesc'});
	$image->{'desc'} = $in{'desc'};
	}
$info = &get_server_collected($server);
if ($info && $info->{'minfo'} && $info->{'minfo'}->{'version'}) {
	$image->{'virtualmin'} =
		$info->{'minfo'}->{'version'} =~ /gpl/i ||
		$info->{'minfo'}->{'virtualmin'} eq 'gpl' ? 'gpl' : 'pro';
	}
if ($info && $info->{'kernel'}) {
	$image->{'arch'} = $info->{'kernel'}->{'arch'};
	}

# Check if the VM is suitable for imaging
$cfunc = "type_".$server->{'manager'}."_check_image";
if (defined(&$cfunc)) {
	my $err = &$cfunc($server, $image);
	$err && &error(&text('mkimage_echeck', $err));
	}

&ui_print_unbuffered_header(&server_in($server), $text{'mkimage_title'}, "");
&obtain_lock_server($server);

# Work out the system on which the image will be created. This may be the
# host, or an iSCSI server
$vhost = &get_parent_server($server);
$imageserver = $vhost;
$ofunc = "type_".$server->{'manager'}."_get_image_server";
if (defined(&$ofunc)) {
       $imageserver = &$ofunc($server);
       }

# Select temp dir for image on parent host
&$first_print($text{'mkimage_temping'});
$image->{'vhost'} = $vhost->{'id'};
$err = &set_image_location($image, $vhost);
if ($err) {
	&$second_print(&text('mkimage_edest', $err));
	goto FAILED;
	}
($tempok, $temp) = &create_image_files_tempdir($imageserver, $image->{'id'});
if (!$tempok) {
	&$second_print(&text('mkimage_failed', $temp));
	goto FAILED;
	}
else {
	&$second_print($text{'create_done'});
	}

$sfunc = "type_".$server->{'manager'}."_no_shutdown";
$noshut = defined(&$sfunc) && &$sfunc($server);
if ($server->{'status'} ne 'down' && !$noshut) {
	# Shut it down
	&$first_print($text{'mkimage_shutdown'});
	$err = &shutdown_server($server);
	if ($err) {
		&$second_print(&text('mkimage_eshutdown', $err));
		goto FAILED;
		}
	else {
		&$second_print($text{'create_done'});
		}
	$server->{'status'} = 'down';
	&save_managed_server($server);
	$shutdown = 1;
	}

# Validate first disk, if any
$dfunc = "type_".$server->{'manager'}."_list_disks";
$cffunc = "type_".$server->{'manager'}."_can_fsck";
$ffunc = "type_".$server->{'manager'}."_fsck_disk";
if (defined(&$dfunc) && defined(&$cffunc)) {
	&$first_print($text{'mkimage_fsck'});
	$disks = &$dfunc($server, 1);
	if (!ref($disks)) {
		$disks = &$dfunc($server, 0);
		}
	if (!ref($disks)) {
		&$second_print(&text('mkimage_efsckdisks', $disks));
		}
	elsif (!@$disks) {
		&$second_print($text{'mkimage_efscknone'});
		}
	elsif (!&$cffunc($server, $disks->[0])) {
		&$second_print($text{'mkimage_efsckcannot'});
		}
	else {
		($ok, $out) = &$ffunc($server, $disks->[0]);
		if ($ok == 2) {
			&$second_print($text{'fsck_fixed'});
			}
		elsif ($ok == 1) {
			&$second_print($text{'fsck_ok'});
			}
		else {
			&$block_print($out);
			&$second_print($text{'fsck_bad'});
			goto FAILED;
			}
		}
	}

# Convert the remote system into an image file - this will output progress
$ifunc = "type_".$server->{'manager'}."_create_image";
if (!&$ifunc($server, $image, $temp, $in{'munge'} ? 0 : 2, $imageserver)) {
	goto FAILED;
	}

# Transfer the image file to the master
&start_background_dot_printer(&text('mkimage_fetching',
                    &nice_image_destination($image->{'dest'})));
$err = &fetch_image_files($imageserver, $image, $temp, 1, $server);
&stop_background_dot_printer();
if ($err) {
	&$second_print(&text('mkimage_failed', $err));
	}
else {
	&$second_print($text{'create_done'});

	# Save the new image file
	&generate_image_md5s($image);
	&generate_image_size($image);
	&save_server_image($image);
	}

# Cleanup the image on the host
$ifunc = "type_".$server->{'manager'}."_cleanup_image";
if (!&$ifunc($server, $image, $temp, $imageserver)) {
	goto FAILED;
	}

if ($shutdown) {
	&$first_print($text{'mkimage_startup'});
	($ok, $err) = &startup_server($server);
	if (!$ok) {
		&$second_print(&text('mkimage_estartup', $err));
		goto FAILED;
		}
	else {
		&$second_print($text{'create_done'});
		}

	# Re-check status
	&$first_print($text{'save_refreshing'});
	&check_server_status($server);
	&save_managed_server($server);
	&$second_print($text{'create_done'});
	}

FAILED:
&release_lock_server($server);
&webmin_log("image", "server", $server->{'host'},
	    'cmd' => $image->{'id'});
&ui_print_footer("edit_serv.cgi?id=$in{'id'}", $text{'edit_return'});

