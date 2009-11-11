#!/usr/local/bin/perl
# Updates or deletes a system image

require './server-manager-lib.pl';
&can_action_error(undef, "global");
&ReadParse();
($img) = grep { $_->{'id'} eq $in{'id'} } &list_server_images();
$img || &error($text{'dimage_egone'});
&obtain_lock_anything();

if ($in{'delete'}) {
	# Just delete
	&delete_server_image($img);
	&webmin_log("delete", "image", $img->{'id'});
	&redirect("list_images.cgi");
	}
elsif ($in{'copy'}) {
	# Copy to all default storage locations
	&ui_print_header(undef, $text{'icopy_title'}, "");

	@dests = split(/\s+/, $img->{'dest'});
	foreach $stor (&list_storages()) {
		&$first_print(&text('icopy_copying',
			&nice_backup_destination($stor->{'dest'})));
		($destserver, $destpath) =
			&get_image_dest_path($stor->{'dest'});
		if (!$destserver) {
			# Destination makes no sense
			&$second_print($text{'icopy_tohost'});
			}
		else {
			# Actually try to copy
			$err = &transfer_image_files_to_storage($img, $stor);
			if ($err) {
				&$second_print(&text('icopy_failed', $err));
				}
			else {
				&$second_print($text{'create_done'});
				push(@dests, $stor->{'dest'});
				}
			}
		}
	$img->{'dest'} = join(' ', &unique(@dests));
	&save_server_image($img);

	&webmin_log("copy", "image", $img->{'id'});
	&ui_print_footer("list_images.cgi", $text{'images_return'});
	}
else {
	# Update description and OS
	&error_setup($text{'eimage_err'});
	$in{'desc'} =~ /\S/ || &error($text{'eimage_edesc'});
	$img->{'desc'} = $in{'desc'};
	$img->{'type'} = $in{'type'};
	&save_server_image($img);
	&webmin_log("modify", "image", $img->{'id'});
	&redirect("list_images.cgi");
	}

