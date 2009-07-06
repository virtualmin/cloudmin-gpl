#!/usr/local/bin/perl
# Delete several virtual disks

require './server-manager-lib.pl';
&ReadParse();
@servers = &list_managed_servers();
&error_setup($text{'ddisk_err'});
($server) = grep { $_->{'id'} == $in{'id'} } @servers;
$server || &error($text{'edit_egone'});
&check_server_status($server, 0, 1);	# In case state has changed
&can_action_error($server, "disks");
@d = split(/\0/, $in{'d'});

# Get the disks
$lfunc = "type_".$server->{'manager'}."_list_disks";
$disks = &$lfunc($server, 1);
ref($disks) || &error($disks);
%d = map { $_, 1 } @d;
$disks = [ grep { $d{$_->{'real'}} } @$disks ];
@$disks || &error($text{'ddisk_enone'});

# Validate editablility
foreach $disk (@$disks) {
	if ($device->{'device'} && !$disk->{'lv'}) {
		&can_action_error($server, "devices");
		}
	}

# Remove the disk, after asking for confirmation
&ui_print_header(&server_in($server), $text{'ddisk_title'}, "");
if ($in{'confirm'}) {
	# Do it
	&obtain_lock_server($server);
	foreach $disk (@$disks) {
		&$first_print(&text('disk_deleting',
				    "<tt>$disk->{'real'}</tt>"));
		$dfunc = "type_".$server->{'manager'}."_delete_disk";
		$err = &$dfunc($server, $disk);
		if ($err) {
			&$second_print(&text('disk_deletefailed', $err));
			}
		else {
			&$second_print(&text('disk_deletedok'));
			}
		}
	&show_disk_reboot_message($server, $disks->[0]);
	&release_lock_server($server);
	&save_managed_server($server);
	}
else {
	# Ask first
	print "<center>\n";
	print &ui_form_start("delete_disks.cgi");
	print &ui_hidden("id", $in{'id'});
	$totalsize = 0;
	foreach $disk (@$disks) {
		print &ui_hidden("d", $disk->{'real'});
		$totalsize += $disk->{'size'} if (!$disk->{'device'});
		}
	if (!$totalsize) {
		print &text('ddisk_rusure2', scalar(@$disks)),"<p>\n";
		}
	else {
		print &text('ddisk_rusure', scalar(@$disks),
			    &nice_size($totalsize)),"<p>\n";
		}
	print &ui_form_end([ [ "confirm", $text{'ddisk_deleteok'} ] ]);
	print "</center>\n";
	}
&ui_print_footer("list_disks.cgi?id=$in{'id'}", $text{'disks_return'},
		 "", $text{'index_return'});

