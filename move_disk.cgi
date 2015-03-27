#!/usr/local/bin/perl
# Move a disk to new storage

require './server-manager-lib.pl';
&ReadParse();
&error_setup($text{'movedisk_err'});
&error_if_cloudmin_replica();
$server = &get_managed_server($in{'id'});
$server || &error($text{'edit_egone'});
$vhost = &get_parent_server($server);
&can_action_error($server, "disks");
&can_action_error($server, "storages");
$vhost = &get_parent_server($server);
&obtain_lock_server($server);

# Get the disk
$lfunc = "type_".$server->{'manager'}."_list_disks";
$disks = &$lfunc($server, 0);
ref($disks) || &error($disks);
($disk) = grep { $_->{'real'} eq $in{'real'} } @$disks;
$disk || &error($text{'disk_egone'});
&can_move_disk_storage($server, $disk) || &error($text{'movedisk_ecannot'});

if ($in{'storage_mode'} == 0) {
	# Get the storage
	$sfunc = "type_".$server->{'manager'}."_list_storages";
	$storages = &$sfunc($vhost, $server);
	ref($storages) || &error($storages);
	($storage) = grep { $_->{'id'} eq $in{'storage'} } @$storages;
	$storage || &error($text{'movedisk_estorage'});
	$storage->{'id'} eq $disk->{'storage_id'} &&
		&error($text{'movedisk_esame'});
	}
else {
	# Get the directory
	@dirs = &list_available_directories_for_manager($server->{'manager'});
	($dir) = grep { $_->{'dir'} && $_->{'dir'} eq $in{'directory'} } @dirs;
	$dir || &error($text{'movedisk_edirectory'});
	$storage = { 'id' => 'files',
		     'directory' => $in{'directory'} };
	}

&ui_print_unbuffered_header(&server_in($server), $text{'movedisk_title'}, "");

# Shut down if needed
$did_shutdown = 0;
if ($server->{'status'} ne 'down') {
	&$first_print($text{'mkimage_shutdown'});
	local $err = &shutdown_server($server);
	&check_server_status($server, 0, 1);
	&save_managed_server($server);
	if ($err) {
		&$second_print(&text('mkimage_eshutdown', $err));
		}
	else {
		&$second_print($text{'create_done'});
		}
	$did_shutdown = 1;
	}

if ($in{'storage_mode'} == 0) {
	&start_background_dot_printer(
		&text('movedisk_doings', "<tt>$disk->{'virt'}</tt>",
		      "<i>$storage->{'desc'}</i>"));
	}
else {
	&start_background_dot_printer(
		&text('movedisk_doingd', "<tt>$disk->{'virt'}</tt>",
		      "<tt>$storage->{'directory'}</tt>"));
	}

$err = &move_disk_storage($server, $disk, $storage);
&save_managed_server($server);
&release_lock_server($server);
&stop_background_dot_printer();

if ($err) {
	&$second_print(&text('movedisk_modifyfailed', $err));
	}
else {
	&$second_print(&text('movedisk_modifyok'));
	}

if ($did_shutdown) {
	# Start up after resizing
	&$first_print($text{'mkimage_startup'});
	local $err = &startup_server($server);
	&check_server_status($server, 0, 1);
	&save_managed_server($server);
	if ($err) {
		&$second_print(&text('mkimage_estartup', $err));
		}
	else {
		&$second_print($text{'create_done'});
		}
	}

if (!$err) {
	&webmin_log("move", "disk", $server->{'host'},
		    { 'real' => $disk->{'real'} });
	}

&ui_print_footer("list_disks.cgi?id=$in{'id'}", $text{'disks_return'},
		 "", $text{'index_return'});
