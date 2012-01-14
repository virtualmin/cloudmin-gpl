#!/usr/local/bin/perl
# Show the virtual disks on some system

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

# Get disks or die
$dfunc = "type_".$server->{'manager'}."_list_disks";
$disks = &$dfunc($server);
ref($disks) || &error(&text('disks_eget', $disks));

&ui_print_header(&server_in($server), $text{'disks_title'}, "", "disks");

# Find possible medias
$mfunc = "type_".$server->{'manager'}."_list_disk_medias";
if (defined(&$mfunc)) {
	$medias = &$mfunc($server, $disk);
	if (ref($medias)) {
		%mediamap = map { $_->{'id'}, $_->{'desc'} } @$medias;
		}
	}

# Build disk creation links, with storages
$sfunc = "type_".$server->{'manager'}."_list_storages";
if (&can_action($server, "storage") && defined(&$sfunc)) {
	$storages = &$sfunc($vhost);
	if (ref($storages) && @$storages > 1) {
		foreach $s (@$storages) {
			push(@links, "<a href='edit_disk.cgi?new=1&".
				     "id=$in{'id'}&storage=$s->{'id'}'>".
				     "$s->{'adddesc'}</a>");
			}
		}
	}
if (!@links) {
	# Default storage only
	@links = ( "<a href='edit_disk.cgi?new=1&id=$in{'id'}'>".
		   "$text{'disks_add1'}</a>" );
	}
if (&can_action($server, "devices") && $can != 2) {
	push(@links, "<a href='edit_disk.cgi?new=2&id=$in{'id'}'>".
		     "$text{'disks_add2'}</a>");
	}

if (@$disks) {
	# We have some to show
	@tds = ( "width=5" );
	print &ui_form_start("delete_disks.cgi", "post");
	print &ui_hidden("id", $in{'id'});
	print &ui_links_row(\@links);
	print &ui_columns_start([ "",
				  $text{'disks_real'},
				  $text{'disks_virt'},
				  $text{'disks_type'},
				  %mediamap ? ( $text{'disks_media'} ) : ( ),
				  $text{'disks_size'} ],
				100, 0, \@tds);
	foreach my $d (@$disks) {
		$rdesc = &describe_disk($server, $d);
		$vdesc = defined(&mount::device_name) ?
				&mount::device_name($d->{'virt'}, 1) :
				"<tt>$d->{'virt'}</tt>";
		$canedit = !$d->{'device'} || $d->{'lv'} || $d->{'storage'} ||
			   &can_action($server, 'devices');
		$sched = &get_scheduled_change($server, "disk", $d->{'real'});
		print &ui_checked_columns_row([
		    $canedit ?
		     "<a href='edit_disk.cgi?id=$in{'id'}&real=$d->{'real'}'>".
		      "$rdesc</a>" : $rdesc,
		    $vdesc,
		    $d->{'lv'} ? $text{'disks_lvm'} :
		     $d->{'storage'} && $server->{'manager'} eq 'citrix' ?
			$text{'disks_storagetype'} :
		      $d->{'device'} ? $text{'disks_dev'} : $text{'disks_file'},
		    %mediamap ? ( $mediamap{$d->{'media'}} || $d->{'media'})
			      : ( ),
		    ($d->{'size'} ? &nice_size($d->{'size'}) : undef).
		    ($sched ? " ".&text('disks_sched',
					&nice_size($sched->{'size'})) : ""),
		    ], \@tds, "d", $d->{'real'}, 0, !$canedit);
		}
	print &ui_columns_end();
	print &ui_links_row(\@links);
	print &ui_form_end([ [ undef, $text{'disks_delete'} ] ]);
	}
else {
	# No disks?!
	print "<b>$text{'disks_none'}</b><p>\n";
	print &ui_links_row(\@links);
	}

# Show form for default directory for new disks
if (&indexof($server->{'manager'}, @diskfile_server_management_types) >= 0 &&
    defined(&list_directories)) {
	@dirs = &list_available_directories_for_manager($server->{'manager'});
	$sel = &directory_selector($server->{'manager'},
				   $server->{'new_directory'});
	if ($sel && (@dirs > 1 ||
		     $dirs[0]->{'dir'} ne $server->{'new_directory'})) {
		@dirs = &list_directories();
		print &ui_form_start("save_diskdir.cgi");
		print &ui_hidden("id", $in{'id'});
		print &ui_table_start($text{'disks_dheader'}, undef, 2);

		# Current dir, if set
		if ($server->{'new_directory'}) {
			($dir) = grep { $_->{'dir'} eq
					  $server->{'new_directory'} } @dirs;
			$dmesg = $dir ? $dir->{'dir'}." (".$dir->{'desc'}.")"
				      : $server->{'new_directory'};
			}
		elsif ($vhost->{$server->{'manager'}.'_vg'}) {
			$dmesg = &text('disks_ddeflvm',
				       $vhost->{$server->{'manager'}.'_vg'});
			}
		else {
			$dmesg = &text('disks_ddef',
				       $vhost->{$server->{'manager'}.'_dir'});
			}
		print &ui_table_row($text{'disks_dold'}, $dmesg);

		# Host default location
		if ($server->{'new_directory'}) {
			if ($vhost->{$server->{'manager'}.'_vg'}) {
				$hmesg = &text('disks_hdeflvm',
				       $vhost->{$server->{'manager'}.'_vg'});
				}
			else {
				$hmesg = &text('disks_hdef',
				       $vhost->{$server->{'manager'}.'_dir'});
				}
			print &ui_table_row($text{'disks_dhost'}, $hmesg);
			}

		# New dir
		print &ui_table_row($text{'disks_dnew'}, $sel);

		print &ui_table_end();
		print &ui_form_end([ [ undef, $text{'save'} ] ]);
		}
	}

&ui_print_footer("edit_serv.cgi?id=$in{'id'}", $text{'edit_return'});

