#!/usr/local/bin/perl
# Swap the position of two custom links

require './server-manager-lib.pl';
&ReadParse();
&can_action_error(undef, "global");

@links = &list_custom_links();
$idx = $in{'idx'};
$idx2 = $idx + ($in{'up'} ? -1 : 1);
($links[$idx], $links[$idx2]) = ($links[$idx2], $links[$idx]);
&save_custom_links(\@links);
&webmin_log("move", "links");
&redirect("edit_newlinks.cgi?refresh=1");

