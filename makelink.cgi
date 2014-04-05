#!/usr/local/bin/perl
# Create a symbolic link on a remote system

require './server-manager-lib.pl';
&foreign_require("file");
&ReadParse();
$server = &get_managed_server($in{'id'});
$server || &error($text{'edit_egone'});
&can_action_error($server, "transfer");

print "Content-type: text/plain\n\n";
$err = &symlink_file_on_server($server, $in{'to'}, $in{'from'});
if ($err) {
	print $err, "\n";
	}
else {
	print "\n";
	print &file_info_line($server, $in{'from'}),"\n";
	}

