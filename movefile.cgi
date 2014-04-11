#!/usr/local/bin/perl
# Move some file or directory on a remote system

require './server-manager-lib.pl';
&foreign_require("file");
&ReadParse();
$server = &get_managed_server($in{'id'});
$server || &error($text{'edit_egone'});
&can_action_error($server, "transfer");

print "Content-type: text/plain\n\n";
$err = &temp_mount_filesystem_if_needed($server);
if (!$err) {
	$err = &rename_file_on_server($server, $in{'from'}, $in{'to'});
	}
print $err,"\n";

