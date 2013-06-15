#!/usr/local/bin/perl
# Show the details of one disk, or allow one to be added

require './server-manager-lib.pl';
&ReadParse();
$server = &get_managed_server($in{'id'});
$server || &error($text{'edit_egone'});
&can_action_error($server, "disks");
if (&foreign_check("mount")) {
	&foreign_require("mount", "mount-lib.pl");
	}
$cfunc = "type_".$server->{'manager'}."_can_disks";
$can = &$cfunc($server);
$vhost = &get_parent_server($server);

# Get the storage location
$sfunc = "type_".$server->{'manager'}."_list_storages";
if (defined(&$sfunc) && $in{'new'} && &can_action($server, "storage") &&
    $in{'storage'}) {
	$storages = &$sfunc($vhost, $server);
	ref($storages) || &error($storages);
	($gotstorage) = grep { $_->{'id'} eq $in{'storage'} } @$storages;
	$gotstorage || &error($text{'disk_estorage'});
	}

# Show title and get the disk
$lfunc = "type_".$server->{'manager'}."_list_disks";
$disks = &$lfunc($server, 2);
if (!ref($disks)) {
	# Try again without asking for mounts
	$disks = &$lfunc($server, 0);
	}
ref($disks) || &error(&text('disks_eget', $disks));
if ($in{'new'}) {
	&ui_print_header(&server_in($server), $text{'disk_title'.$in{'new'}},
			 "", "disk".$in{'new'});
	$nfunc = "type_".$server->{'manager'}."_new_disk";
	if (defined(&$nfunc)) {
		$disk = &$nfunc($server, $disks, $in{'new'} == 2,
				$gotstorage);
		}
	else {
		$disk = { };
		}
	}
else {
	($disk) = grep { $_->{'real'} eq $in{'real'} } @$disks;
	$disk || &error($text{'disk_egone'});
	&ui_print_header(&server_in($server), $text{'disk_title'}, "", "disk");
	$ffunc = "type_".$server->{'manager'}."_can_fsck";
	$fsck = &$ffunc($server, $disk);
	}

# Make sure owner can edit devices
if ($disk->{'device'} && !$disk->{'lv'} && !$disk->{'storage'}) {
	&can_action_error($server, "devices");
	}

# Show form with disk details
print &ui_form_start("save_disk.cgi", "post");
print &ui_hidden("new", $in{'new'});
print &ui_hidden("id", $in{'id'});
if (!$in{'new'}) {
	print &ui_hidden("oldreal", $disk->{'real'});
	}
print &ui_table_start($text{'disk_header'}, undef, 2);

# Real file on host system
if ($disk->{'fixedreal'}) {
	# Cannot be edited
	$realsel = $disk->{'real'} ? &describe_disk($server, $disk)
				   : $text{'disk_autoreal'};
	$txt = 'disk_real';
	print &ui_hidden("fixedreal", 1);
	}
elsif ($in{'new'} == 2) {
	# Show device selector from host, if we can
	if ($vhost->{'id'} eq '0') {
		# Can select file locally
		$b = &file_chooser_button("other");
		}
	if (($vhost->{'status'} eq 'virt' || $vhost->{'status'} eq 'novirt') &&
	    &remote_foreign_check($vhost, "raid")) {
		&remote_foreign_require($vhost, "raid", "raid-lib.pl");
		@rdisks = &remote_foreign_call($vhost, "raid",
				"find_free_partitions", [ ], 1, 1);
		if (@rdisks) {
			$realsel = &ui_radio_table("real_mode", 0,
				[ [ 0, $text{'disk_part'},
				    &ui_select("real", $rdisks[0]->[0],
					       \@rdisks,
					       1, 0, 0, 0, $js) ],
				  [ 1, $text{'disk_other'},
				       &ui_textbox("other", undef, 50).$b ] ]);
			}
		}
	if (!$realsel) {
		$realsel = &ui_hidden("real_mode", 1).
			   &ui_textbox("other", $disk->{'real'}, 50).$b;
		}
	$txt = 'disk_real1';
	}
elsif ($in{'new'} == 1 && &can_action($server, "devices")) {
	if ($disk->{'lv'}) {
		# On LVM, show field for LV name
		$realsel = &ui_textbox("lv", $disk->{'lv'}, 20);
		$txt = 'disk_real2lvm';
		}
	else {
		# Show field for image file
		$realsel = &ui_textbox("real", $disk->{'real'}, 50);
		$txt = 'disk_real2';
		}
	$realsel .= " ".&ui_checkbox("overwrite", 1,
			     $disk->{'lv'} ? $text{'disk_overwrite2'}
					   : $text{'disk_overwrite'}, 0);
	}
elsif ($disk->{'change'} && &can_action($server, "devices")) {
	# Real file can be changed, like for a CD
	if ($vhost->{'id'} eq '0') {
		# Can select file locally
		$b = &file_chooser_button("real");
		}
	$realsel = &ui_textbox("real", $disk->{'real'}, 50).$b;
	$txt = 'disk_real';
	}
else {
	# Cannot edit real file for existing disks
	if ($disk->{'lv'} && $disk->{'real'} =~ /^\/dev\/(\S+)\/(\S+)$/) {
		$realsel = "<tt>$2</tt>";
		$txt = 'disk_reallvm';
		}
	else {
		$realsel = "<tt>$disk->{'real'}</tt>";
		$txt = 'disk_real';
		}
	}
print &ui_table_row(&text($txt, "<tt>$vhost->{'host'}</tt>"), $realsel);

# Device on virtual system
print &ui_table_row($text{'disk_virt'},
	&ui_textbox("virt", $disk->{'virt'}, 30));

# Get current disk used and free on host
$freemsg = "";
($diskfree, $disktotal) = &host_free_disk($vhost, $server->{'manager'},
					  $server, $disk);
if ($diskfree) {
	$freemsg = &text('disk_sizefree', &nice_size($disktotal),
					  &nice_size($diskfree));
	}

# Size of file
if ($in{'new'} == 1) {
	# File size to create
	print &ui_table_row($text{'disk_size1'},
		&ui_bytesbox("size", 1024*1024*1024, 8)." ".$freemsg);
	}
elsif (!$in{'new'} &&
       (!$disk->{'device'} || $disk->{'lv'} || $disk->{'storage'}) &&
       !$disk->{'fixedsize'}) {
	# Current size of the file, which can be changed
	print &ui_table_row($text{'disk_size0'},
		&ui_bytesbox("size", $disk->{'size'}, 8)." ".$freemsg);
	}
elsif (!$in{'new'} && $disk->{'size'}) {
	# Real device size, if we can get it
	print &ui_table_row($text{'disk_size'},
		&nice_size($disk->{'size'}));
	}

# Media type, if supported
$mfunc = "type_".$server->{'manager'}."_list_disk_medias";
if (defined(&$mfunc)) {
	$medias = &$mfunc($server, $disk);
	ref($medias) || &error($medias);
	print &ui_table_row($text{'disk_media'},
		&ui_select("media", $disk->{'media'},
			   [ map { [ $_->{'id'}, $_->{'desc'} ] } @$medias ]));
	}

# Caching mode, if supported
$cfunc = "type_".$server->{'manager'}."_list_disk_caches";
if (defined(&$cfunc)) {
	$caches = &$cfunc($server);
	ref($caches) || &error($caches);
	$c = $disk->{'cache'};
	if ($c) {
		($obj) = grep { $_->{'id'} eq $c ||
				$_->{'alt'} eq $c } @$caches;
		$c = $obj->{'id'} if ($obj);
		}
	else {
		($obj) = grep { $_->{'default'} } @$caches;
		$c = $obj->{'id'};
		}
	print &ui_table_row($text{'disk_cache'},
		&ui_select("cache", $c,
			   [ map { [ $_->{'id'}, $_->{'desc'} ] } @$caches ],
			   1, 0, 1));
	}

# Storage location, if supported
if ($gotstorage) {
	print &ui_table_row($text{'disk_storage'}, $gotstorage->{'desc'});
	print &ui_hidden("storage", $in{'storage'});
	}

# iSCSI information
if ($disk->{'iscsi_ip'}) {
	print &ui_table_row($text{'disk_istate'},
		$disk->{'iscsi_connect'} ? $text{'disk_istate1'} :
			"<font color=red>$text{'disk_istate0'}</font>");
	if ($disk->{'iscsi_server'} ne '') {
		my $iserver = &get_managed_server($disk->{'iscsi_server'});
		print &ui_table_row($text{'disk_iserver'},
				    $iserver->{'host'});
		}
	else {
		print &ui_table_row($text{'disk_iserver'},
			&text('disk_iunknown', $disk->{'iscsi_ip'}));
		}
	print &ui_table_row($text{'disk_itarget'},
			    $disk->{'iscsi_target'});
	}

# Disk format
print &ui_table_row($text{'disk_format'},
	$text{'mimage_fmt'.$disk->{'format'}});

# Current use on virtual system
if (!$in{'new'} && $disk->{'fs'} eq 'swap') {
	# Virtual memory
	print &ui_table_row($text{'disk_use'}, $text{'disk_useswap'});
	}
elsif (!$in{'new'} && $disk->{'mount'}) {
	# Filesystem mount
	print &ui_table_row($text{'disk_use'},
		&text('disk_used', "<tt>$disk->{'mount'}</tt>",
		      $text{'fs_'.$disk->{'fs'}} || uc($disk->{'fs'})));
	}

# Filesystem size and free space
if (!$in{'new'} && $disk->{'df_size'}) {
	print &ui_table_row($text{'disk_fssize'},
		&text('disk_fssizeu', &nice_size($disk->{'df_size'}),
				      &nice_size($disk->{'df_used'})));
	}

# Include in backups?
if (!$disk->{'swap'}) {
	$inc = $in{'new'} ? 1 : &get_disk_include($server, $disk);
	print &ui_table_row($text{'disk_include'},
			    &ui_yesno_radio("include", $inc));
	}

# Offer to mkfs
if ($in{'new'}) {
	$ffunc = "type_".$server->{'manager'}."_list_disk_filesystems";
	@fs = &$ffunc($server);
	print &ui_table_row($text{'disk_mkfs'},
		&ui_select("fs", $disk->{'device'} ? "" : $fs[0],
			   [ [ "", $text{'disk_mkfs_none'} ],
			     map { [ $_, $text{'fs_'.$_} ] } @fs ]));
	}

# Offer to mount
if ($in{'new'}) {
	print &ui_table_row($text{'disk_mount'},
		&ui_radio("mount_def", 1,
			  [ [ 1, $text{'disk_nomount'} ],
			    [ 2, $text{'disk_swapmount'} ],
			    [ 0, $text{'disk_dirmount'} ] ])." ".
		&ui_textbox("mount", undef, 30));
	}

# Work out if deletion and detaching is allowed. The root filesystem cannot
# be removed, and disk can only be detached if the user is allowed to add them,
# and the file is not a device (for which deletion does the same thing)
$root = $disk->{'mount'} eq '/' ? 1 : 0;
$detach = !$root && &can_action($server, "devices") &&
	  !($disk->{'device'} && !$disk->{'lv'} && !$disk->{'storage'});
$connect = $disk->{'iscsi_ip'} && !$disk->{'iscsi_connect'};
$disconnect = $disk->{'iscsi_ip'} && $disk->{'iscsi_connect'};

print &ui_table_end();
print &ui_form_end($in{'new'} ? [ [ undef, $text{'create'} ] ]
		      : [ [ undef, $text{'save'} ],
			  $fsck ? ( [ 'fsck', $text{'disk_fsck'} ] ) : ( ),
			  $detach ? ( [ 'detach', $text{'disk_detach'} ] ) : (),
			  $connect ? ( [ 'connect', $text{'disk_connect'} ] ) : (),
			  $disconnect ? ( [ 'disconnect', $text{'disk_disconnect'} ] ) : (),
			  $root ? ( ) : ( [ 'delete', $text{'delete'} ] ) ]);

# Scheduled expansion form
if (!$in{'new'} && !$disk->{'fixedsize'} && 
    (!$disk->{'device'} || $disk->{'lv'} || $disk->{'storage'})) {
	$sched = &get_scheduled_change($server, "disk", $disk->{'real'});
	print &ui_hr();
	print &ui_form_start("save_disksched.cgi", "post");
	print &ui_hidden("id", $in{'id'});
	print &ui_hidden("real", $disk->{'real'});
	print &ui_table_start($text{'disk_sheader'}, undef, 2);

	if ($sched) {
		# Already scheduled, show button to remove
		print &ui_table_row(undef, $text{'disk_sdesc2'}, 2);

		# Current time
		print &ui_table_row($text{'disk_snow'},
			&make_date(time(), 0, "dd/mon/yyyy"));

		# When it will be run
		@tm = localtime($sched->{'time'});
		print &ui_table_row($text{'disk_sdate'},
			&make_date($sched->{'time'}, 1));

		print &ui_table_row($text{'disk_stime'},
			sprintf("%2.2d:%2.2d", $tm[2], $tm[1]));

		# New size
		print &ui_table_row($text{'disk_ssize'},
			&nice_size($sched->{'size'}));

		$button = [ 'delete', $text{'disk_sdelete'} ];
		}
	else {
		# Not scheduled yet, show form to add
		print &ui_table_row(undef, $text{'disk_sdesc'}, 2);

		# Current time
		print &ui_table_row($text{'disk_snow'},
			&make_date(time(), 0, "dd/mon/yyyy"));

		# When to run
		@now = localtime(time()+(24*60*60));
		print &ui_table_row($text{'disk_sdate'},
			&ui_textbox("day", $now[3], 2)."/".
			&ui_select("month", $now[4],
				   [ map { [ $_, $text{"smonth_".($_+1)} ] }
					 ( 0 .. 11 ) ])."/".
			&ui_textbox("year", $now[5]+1900, 4).
			&date_chooser_button("day", "month", "year"));

		print &ui_table_row($text{'disk_stime'},
			&ui_textbox("hour", "03", 2).":".
			&ui_textbox("min", "00", 2));

		# New size
		print &ui_table_row($text{'disk_ssize'},
			&ui_bytesbox("size", $disk->{'size'}, 8)." ".$freemsg);

		# Resize even if unsafe?
		print &ui_table_row($text{'disk_sforce'},
			&ui_yesno_radio("force", 0));

		$button = [ 'save', $text{'disk_ssave'} ];
		}

	print &ui_table_end();
	print &ui_form_end([ $button ]);
	}

# Show form to move disk to a new storage
$sfunc = "type_".$server->{'manager'}."_list_storages";
if (&can_action($server, "storage") && &can_move_disk_storage($server, $disk) &&
    $server->{'status'} eq 'down' && defined(&$sfunc) &&
    ref($storages = &$sfunc($vhost, $server))) {
	print &ui_hr();
        print &ui_form_start("move_disk.cgi", "post");
	print &ui_hidden("id", $in{'id'});
	print &ui_hidden("real", $disk->{'real'});
	print &ui_table_start($text{'disk_mheader'}, undef, 2);

	# Current storage
	print &ui_table_row($text{'disk_oldstorage'},
		$disk->{'storage'});

	# New storage
	print &ui_table_row($text{'disk_newstorage'},
		&ui_select("storage", $disk->{'storage_id'},
		   [ map { [ $_->{'id'}, $_->{'desc'} ] } @$storages ]));

	print &ui_table_end();
	print &ui_form_end([ [ undef, $text{'disk_move'} ] ]);
	}

&ui_print_footer("list_disks.cgi?id=$in{'id'}", $text{'disks_return'},
		 "", $text{'index_return'});

