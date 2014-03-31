#!/usr/local/bin/perl
# Return information about the root directory

require './server-manager-lib.pl';
&ReadParse();
$server = &get_managed_server($in{'id'});
$server || &error($text{'edit_egone'});
&can_action_error($server, "transfer");
print "Content-type: text/plain\n\n";
print &file_info_line($server, "/"),"\n";
