#!/usr/local/bin/perl
# Updates or deletes a system image

require './server-manager-lib.pl';
&can_action_error(undef, "global");
&error_if_cloudmin_replica();
&ReadParse();
($img) = grep { $_->{'id'} eq $in{'id'} } &list_server_images();
$img || &error($text{'dimage_egone'});
&obtain_lock_anything();

if ($in{'delete'}) {
	# Just delete
	&delete_server_image($img);
	&webmin_log("delete", "image", $img->{'id'});
	}
else {
	# Update description and OS
	&error_setup($text{'eimage_err'});
	$in{'desc'} =~ /\S/ || &error($text{'eimage_edesc'});
	$img->{'desc'} = $in{'desc'};
	$img->{'type'} = $in{'type'};
	&save_server_image($img);
	&webmin_log("modify", "image", $img->{'id'});
	}
&redirect("list_images.cgi?mode=$in{'mode'}");
