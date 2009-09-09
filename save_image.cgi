#!/usr/local/bin/perl
# Deletes a system image

require './server-manager-lib.pl';
&can_action_error(undef, "global");
&ReadParse();
($got) = grep { $_->{'id'} eq $in{'id'} } &list_server_images();
$got || &error($text{'dimage_egone'});
&obtain_lock_anything();

if ($in{'delete'}) {
	&delete_server_image($got);
	&webmin_log("delete", "image", $got->{'id'});
	}
&redirect("list_images.cgi");

