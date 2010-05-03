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

# Get disks or die
$dfunc = "type_".$server->{'manager'}."_list_disks";
$disks = &$dfunc($server);
ref($disks) || &error(&text('disks_eget', $disks));

&ui_print_header(&server_in($server), $text{'disks_title'}, "", "disks");

# Show a table
@links = ( "<a href='edit_disk.cgi?new=1&id=$in{'id'}'>".
	   "$text{'disks_add1'}</a>" );
if (&can_action($server, "devices") && $can != 2) {
	push(@links, "<a href='edit_disk.cgi?new=2&id=$in{'id'}'>".
		     "$text{'disks_add2'}</a>");
	}
if (@$disks) {
	# We have some to show
	unshift(@links, &select_all_link("d"), &select_invert_link("d"));
	@tds = ( "width=5" );
	print &ui_form_start("delete_disks.cgi", "post");
	print &ui_hidden("id", $in{'id'});
	print &ui_links_row(\@links);
	print &ui_columns_start([ "", $text{'disks_real'}, $text{'disks_virt'},
				  $text{'disks_type'}, $text{'disks_size'} ],
				100, 0, \@tds);
	foreach my $d (@$disks) {
		$rdesc = &describe_disk($d);
		$vdesc = defined(&mount::device_name) ?
				&mount::device_name($d->{'virt'}, 1) :
				"<tt>$d->{'virt'}</tt>";
		$canedit = !$d->{'device'} || $d->{'lv'} ||
			   &can_action($server, 'devices');
		$sched = &get_scheduled_change($server, "disk", $d->{'real'});
		print &ui_checked_columns_row([
		    $canedit ?
		     "<a href='edit_disk.cgi?id=$in{'id'}&real=$d->{'real'}'>".
		      "$rdesc</a>" : $rdesc,
		    $vdesc,
		    $d->{'lv'} ? $text{'disks_lvm'} :
		      $d->{'device'} ? $text{'disks_dev'} : $text{'disks_file'},
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

&ui_print_footer("edit_serv.cgi?id=$in{'id'}", $text{'edit_return'});

