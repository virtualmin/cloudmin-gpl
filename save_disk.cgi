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
	}

if ($in{'delete'}) {
	# Remove the disk
	&ui_print_header(&server_in($server), $text{'disk_titled'}, "");
	&$first_print(&text('disk_deleting', "<tt>$disk->{'real'}</tt>"));
	$dfunc = "type_".$server->{'manager'}."_delete_disk";
	$err = &$dfunc($server, $disk);
	if ($err) {
		&$second_print(&text('disk_deletefailed', $err));
		}
	else {
		&$second_print(&text('disk_deleteok'));
		&show_reboot_message();
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
		# XXX
		}

	if ($in{'new'}) {
		# Create the disk
		}
	else {
		# Modify the size or devices, if we can
		}
	}

sub show_reboot_message
{
$rfunc = "type_".$server->{'manager'}."_need_disk_reboot";
if (defined(&$rfunc) && &$rfunc($server, $disk)) {
	print &ui_form_start("save_serv.cgi");
	print &ui_hidden("id", $in{'id'});
	print &ui_hidden("reboot", 1);
	print &ui_hidden("confirm", 1);
	print "<b>$text{'disk_needreboot'}</b><p>\n";
	print &ui_form_end([ [ undef, $text{'limits_reboot'} ] ]);
	}
}

