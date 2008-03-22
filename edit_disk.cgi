#!/usr/local/bin/perl
# Show the details of one disk, or allow one to be added

require './server-manager-lib.pl';
&ReadParse();
@servers = &list_managed_servers();
($server) = grep { $_->{'id'} == $in{'id'} } @servers;
$server || &error($text{'edit_egone'});
if (&foreign_check("mount")) {
	&foreign_require("mount", "mount-lib.pl");
	}

# Show title and get the disk
$disks = &type_xen_list_disks($server, 1);
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
	$disk = grep { $_->{'real'} eq $in{'real'} } @$disks;
	$disk || &error($text{'disk_egone'});
	&ui_print_header(&server_in($server), $text{'disk_title0'}, "", "disk");
	}

# Show form with disk details
print &ui_form_start("save_disk.cgi", "post");
print &ui_hidden("new", $in{'new'});
print &ui_hidden("id", $in{'id'});
if (!$in{'new'}) {
	print &ui_hidden("oldreal", $disk->{'real'});
	}
print &ui_table_start($text{'disk_header'}, "width=100%", 2);

# Real file on host system
# XXX why are in-use disks being shown?
$vhost = &get_parent_server($server);
if ($in{'new'} == 2) {
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
	}
$realsel ||= &ui_textbox("real", $disk->{'real'}, 50);
print &ui_table_row(&text($in{'new'} == 2 ? 'disk_real' : 'disk_real2',
			  "<tt>$vhost->{'host'}</tt>"), $realsel);

# Device on virtual system
print &ui_table_row($text{'disk_virt'},
	&ui_textbox("virt", $disk->{'virt'}, 30));

# Size of file
if ($in{'new'} == 1) {
	# File size to create
	print &ui_table_row($text{'disk_size1'},
		&ui_bytesbox("size", 1024*1024*1024, 8));
	}
elsif (!$in{'new'} && !$disk->{'device'}) {
	# Current size of the file, which can be changed
	print &ui_table_row($text{'disk_size0'},
		&ui_bytesbox("size", $disk->{'size'}, 8));
	}
elsif (!$in{'new'} && $disk->{'size'}) {
	# Real device size, if we can get it
	print &ui_table_row($text{'disk_size'},
		&nice_size($disk->{'size'}));
	}

# Current use on virtual system
if (!$in{'new'} && $disk->{'mount'}) {
	&ui_table_row($text{'disk_use'},
		&text('disk_used', "<tt>$disk->{'mount'}</tt>",
		      $text{'fs_'.$disk->{'fs'}} || uc($disk->{'fs'})));
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
		&ui_opt_textbox("mount", $disk->{'mount'}, 30,
				$text{'disk_nomount'}, $text{'disk_dirmount'}));
	}

print &ui_table_end();
print &ui_form_end($in{'new'} ? [ [ undef, $text{'create'} ] ]
		   	      : [ [ undef, $text{'save'} ],
			          [ 'delete', $text{'delete'} ] ]);

&ui_print_footer("list_disks.cgi?id=$in{'id'}", $text{'disks_return'},
		 "", $text{'index_return'});

