#!/usr/local/bin/perl
# Copy some file or directory

require './server-manager-lib.pl';
&foreign_require("file");
&ReadParse();
$server = &get_managed_server($in{'id'});
$server || &error($text{'edit_egone'});
&can_action_error($server, "transfer");

print "Content-type: text/plain\n\n";
$err = &temp_mount_filesystem_if_needed($server);
if ($err) {
	print $err,"\n";
	return;
	}

@st = &stat_file_on_server($server, $in{'from'});
if ($st[14]) {
	# Copying a link, so just re-create it
	&delete_file_on_server($server, $in{'to'});
	$err = &symlink_file_on_server($server, $st[14], $in{'to'});
	}
else {
	# Copy the file
	if (&is_dir_on_server($server, $in{'from'})) {
		$err = &transfer_directory_between_servers($server, $server,
						      $in{'from'}, $in{'to'});
		}
	else {
		$err = &transfer_file_between_servers($server, $server,
						      $in{'from'}, $in{'to'});
		}
	}
if ($err) {
	print $err,"\n";
	}
else {
	print "\n";
	print &file_info_line($server, $in{'to'}),"\n";
	}
