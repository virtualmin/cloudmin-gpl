#!/usr/local/bin/perl
# Create a directory on a remote system

require './server-manager-lib.pl';
&foreign_require("file");
&ReadParse();
$server = &get_managed_server($in{'id'});
$server || &error($text{'edit_egone'});
&can_action_error($server, "transfer");

print "Content-type: text/plain\n\n";

$err = &make_dir_on_server($server, $in{'dir'}, 0777);
if ($err) {
	print $err,"\n";
	}
else {
	print "\n";
	print &file_info_line($server, $in{'dir'}),"\n";
	}


