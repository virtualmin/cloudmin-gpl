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
		$disk = &$nfunc($server, $disks, $in{'new'} == 2);
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
if ($disk->{'device'} && !$disk->{'lv'}) {
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
$vhost = &get_parent_server($server);
if ($disk->{'fixedreal'}) {
	# Cannot be edited
	$realsel = $disk->{'real'} ? &describe_disk($disk)
				   : $text{'disk_autoreal'};
	$txt = 'disk_real';
	print &ui_hidden("fixedreal", 1);
	}
elsif ($in{'new'} == 2) {
	# Show device selector from host, if we can
	if (($vhost->{'status'} eq 'virt' || $vhost->{'status'} eq 'novirt') &&
	    &remote_foreign_check($vhost, "raid")) {
		&remote_foreign_require($vhost, "raid", "raid-lib.pl");
		@rdisks = &remote_foreign_call($vhost, "raid",
				"find_free_partitions", [ ], 1, 1);
		if (@rdisks) {
			$realsel = &ui_select("real", $rdisks[0]->[0],
				[ @rdisks, [ "", $text{'disk_other'} ] ])." ".
				&ui_textbox("other", undef, 30);
			}
		}
	$realsel ||= &ui_textbox("real", $disk->{'real'}, 50);
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
($diskfree, $disktotal) = &host_free_disk($vhost, $server->{'manager'},$server);
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
       (!$disk->{'device'} || $disk->{'lv'} || $disk->{'storage'})) {
	# Current size of the file, which can be changed
	print &ui_table_row($text{'disk_size0'},
		&ui_bytesbox("size", $disk->{'size'}, 8)." ".$freemsg);
	}
elsif (!$in{'new'} && $disk->{'size'}) {
	# Real device size, if we can get it
	print &ui_table_row($text{'disk_size'},
		&nice_size($disk->{'size'}));
	}

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

$root = $disk->{'mount'} eq '/' ? 1 : 0;
print &ui_table_end();
print &ui_form_end($in{'new'} ? [ [ undef, $text{'create'} ] ]
		      : [ [ undef, $text{'save'} ],
			  $fsck ? ( [ 'fsck', $text{'disk_fsck'} ] ) : ( ),
			  $root ? ( ) : ( [ 'delete', $text{'delete'} ] ) ]);

# Scheduled expansion form
if (!$in{'new'} &&
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

		$button = [ 'save', $text{'disk_ssave'} ];
		}

	print &ui_table_end();
	print &ui_form_end([ $button ]);
	}

&ui_print_footer("list_disks.cgi?id=$in{'id'}", $text{'disks_return'},
		 "", $text{'index_return'});

