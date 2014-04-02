#!/usr/local/bin/perl
# Delete some file or directory

require './server-manager-lib.pl';
&foreign_require("file");
&ReadParse();
$server = &get_managed_server($in{'id'});
$server || &error($text{'edit_egone'});
&can_action_error($server, "transfer");

print "Content-type: text/plain\n\n";
$err = &delete_file_on_server($server, $in{'file'});
print $err,"\n";
