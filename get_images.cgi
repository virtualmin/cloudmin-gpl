#!/usr/local/bin/perl
# Downloads new server images from Virtualmin

require './server-manager-lib.pl';
&can_action_error(undef, "global");
&ReadParse();
@d = split(/\0/, $in{'d'});
@d || &error($text{'images_enone'});

if ($in{'get'}) {
	# Downloading images
	&ui_print_header(undef, $text{'images_gettitle'}, "");
	&obtain_lock_anything();
	@d || &error($text{'images_enone'});

	# Do each selected image, where needed
	@avail = &list_available_server_images();
	@images = &list_server_images();
	@prolics = &list_virtualmin_licences();

	foreach $id (@d) {
		($img) = grep { $_->{'id'} eq $id } @avail;
		($got) = grep { $_->{'id'} eq $id } @images;
		if (!$img && $got) {
			print &text('images_getlocal', $got->{'desc'}),"<p>\n";
			next;
			}
		if ($got && $got->{'partial'}) {
			print &text('images_getpartial', $got->{'desc'}),"<p>\n";
			next;
			}

		print &text('images_getting', $img->{'desc'},
					      $img->{'version'}),"<br>\n";
		if ($got && $got->{'version'} >= $img->{'version'}) {
			# Already the latest
			print &text('images_already',$got->{'version'}),"<p>\n";
			}
		else {
			# Download the .img file
			$got = &download_server_image($img);
			if (!ref($got)) {
				print &text('images_eget', $got),"<p>\n";
				next;
				}

			# Does it require Pro?
			if ($got->{'virtualmin'} eq 'pro' && !@prolics) {
				print &text('images_elicence',
					    'list_licences.cgi'),"<p>\n";
				&delete_server_image($got);
				next;
				}

			# Download all other files
			print "<ul>\n";
			$err = &download_server_image_files($got);
			print "</ul>\n";
			if ($err) {
				print &text('images_egetfiles', $err),"<p>\n";
				}
			else {
				# Refresh left frame if this was the first image
				@old = grep { $_->{'manager'} eq
					      $got->{'manager'} } @images;
				if (!@old &&defined(&theme_post_save_server)) {
					&theme_post_save_server();
					}

				print &text('images_got',
					    &nice_size($got->{'size'})),"<p>\n";
				}
			&save_server_image($got);
			}
		}
	&webmin_log("download", "images", scalar(@d));
	&ui_print_footer("list_images.cgi?mode=$in{'mode'}",
			 $text{'images_return'});
	}
elsif ($in{'copy'} || $in{'move'}) {
	# Copying or moving images to all storages
	&ui_print_header(undef, $in{'move'} ? $text{'images_movetitle'}
					    : $text{'images_copytitle'}, "");
	&obtain_lock_anything();

	@images = &list_server_images();
	@stors = &list_storages();
	foreach $id (@d) {
		($img) = grep { $_->{'id'} eq $id } @images;
		next if (!$img);
		$vhost = $img->{'vhost'} ? &get_managed_server($img->{'vhost'})
					 : undef;

		# Copy to storages the image is missing from
		&$first_print(&text('images_copying', $img->{'desc'}));
		&$indent_print();
		@dests = split(/\s+/, $img->{'dest'});
		foreach $stor (&list_storages()) {
			&$first_print(&text('icopy_copying',
				&nice_backup_destination($stor->{'dest'})));
			($destserver, $destpath) =
				&get_image_dest_path($stor->{'dest'}, $vhost);
			$should{$destserver->{'id'},$destpath} = 1;
			if (!$destserver) {
				# Destination makes no sense
				&$second_print($text{'icopy_tohost'});
				}
			else {
				# Actually try to copy
				$err = &transfer_image_files_to_storage(
						$img, $stor);
				if ($err) {
					&$second_print(&text('icopy_failed',
							     $err));
					}
				else {
					&$second_print($text{'create_done'});
					push(@dests, $stor->{'dest'});
					}
				}
			}

		# Delete from any storages that the image isn't supposed
		# to be in
		if ($in{'move'}) {
			$dcount = scalar(@dests);
			foreach $dest (@dests) {
				($destserver, $destpath) =
					&get_image_dest_path($dest);
				next if (!$destserver);
				next if ($should{$destserver->{'id'},
						 $destpath});
				&$first_print(&text('icopy_deleting',
					&nice_backup_destination($dest)));
				if ($dcount <= 1) {
					&$second_print($text{'icopy_left'});
					}
				elsif ($err = &delete_image_files_from_dest(
							$img, $dest)) {
					&$second_print(&text('icopy_dfailed',
							     $err));
					}
				else {
					&$second_print($text{'create_done'});
					$deldests{$dest} = 1;
					$dcount--;
					}
				}
			@dests = grep { !$deldests{$_} } @dests;
			}

		$img->{'dest'} = join(' ', &unique(@dests));
		&save_server_image($img);
		&$outdent_print();
		}

	&webmin_log($in{'move'} ? "move" : "copy", "images", scalar(@d));
	&ui_print_footer("list_images.cgi?mode=$in{'mode'}",
			 $text{'images_return'});
	}

