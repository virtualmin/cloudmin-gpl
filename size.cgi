#!/usr/local/bin/perl
# Returns the size in bytes, number of files and number of dirs in a directory
# on a remote system

require './server-manager-lib.pl';
&foreign_require("file");
&ReadParse();
$server = &get_managed_server($in{'id'});
$server || &error($text{'edit_egone'});
&can_action_error($server, "transfer");

print "Content-type: text/plain\n\n";
($size, $files, $dirs) = &disk_usage_on_server($server, $in{'dir'}, 1);
if ($size !~ /^\d+$/) {
	print $size,"\n";
	}
else {
	print "\n";
	print $size," ",$files," ",$dirs," ",&nice_size($size),"\n";
	}

