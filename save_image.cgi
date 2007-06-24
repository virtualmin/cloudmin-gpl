#!/usr/local/bin/perl
# Deletes a local image

require './server-manager-lib.pl';
&ReadParse();
($got) = grep { $_->{'id'} eq $in{'id'} } &list_server_images();
$got || &error($text{'dimage_egone'});

if ($in{'delete'}) {
	&delete_server_image($got);
	}
&redirect("list_images.cgi");

