#!/usr/local/bin/perl
# Actually create a new system image

require './server-manager-lib.pl';
&ReadParse();
&error_setup($text{'mkimage_err'});
($server) = grep { $_->{'id'} == $in{'id'} } &list_managed_servers();
$server || &error($text{'mkimage_egone'});
&can_action_error($server, "image");

# Validate inputs
$in{'desc'} =~ /\S/ || &error($text{'mkimage_edesc'});
if (!$in{'imageid_def'}) {
	$in{'imageid'} =~ /^\S+$/ || &error($text{'mkimage_eid'});
	($clash) = grep { $_->{'id'} eq $in{'imageid'} } &list_server_images();
	$clash && &error($text{'mkimage_eclash'});
	$imageid = $in{'imageid'};
	}
else {
	$imageid = $in{'oldid'};
	}

# Create initial image hash
$image = { 'id' => $imageid,
	   'desc' => $in{'desc'},
	   'manager' => $server->{'manager'},
	   'nocompress' => !$in{'compress'},
	 };
$image->{'version'} = $in{'version'} if (!$in{'version_def'});
$info = &get_server_collected($server);
if ($info && $info->{'minfo'} && $info->{'minfo'}->{'version'}) {
	$image->{'virtualmin'} =
		$info->{'minfo'}->{'version'} =~ /gpl/i ||
		$info->{'minfo'}->{'virtualmin'} eq 'gpl' ? 'gpl' : 'pro';
	}

&ui_print_unbuffered_header(&server_in($server), $text{'mkimage_title'}, "");

# Select temp dir for image on parent host
&$first_print($text{'mkimage_temping'});
$pfunc = "type_".$server->{'manager'}."_parent";
$vhost = &$pfunc($server);
($tempok, $temp) = &create_image_files_tempdir($vhost, $image->{'id'});
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

# Convert the remote system into an image file - this will output progress
$ifunc = "type_".$server->{'manager'}."_create_image";
if (!&$ifunc($server, $image, $temp, $in{'munge'} ? 0 : 2)) {
	goto FAILED;
	}

# Transfer the image file to the master
&$first_print($text{'mkimage_fetching'});
$err = &fetch_image_files($vhost, $image, $temp, 1);
if ($err) {
	&$second_print(&text('mkimage_failed', $err));
	}
else {
	&$second_print($text{'create_done'});

	# Save the new image file
	&generate_image_md5s($image);
	&save_server_image($image);
	}

# Cleanup the image on the host
$ifunc = "type_".$server->{'manager'}."_cleanup_image";
if (!&$ifunc($server, $image, $temp)) {
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
&ui_print_footer("edit_serv.cgi?id=$in{'id'}", $text{'edit_return'});

