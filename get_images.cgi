#!/usr/local/bin/perl
# Downloads new server images from Virtualmin

require './server-manager-lib.pl';
&ReadParse();
&ui_print_header(undef, $text{'images_gettitle'}, "");

@d = split(/\0/, $in{'d'});
@d || &error($text{'images_enone'});

# Do each selected image, where needed
@avail = &list_available_server_images();
@images = &list_server_images();

foreach $id (@d) {
	($img) = grep { $_->{'id'} eq $id } @avail;
	($got) = grep { $_->{'id'} eq $id } @images;
	if (!$img && $got) {
		print &text('images_getlocal', $got->{'desc'}),"<p>\n";
		next;
		}

	print &text('images_getting', $img->{'desc'},
				      $img->{'version'}),"<br>\n";
	if ($got && $got->{'version'} >= $img->{'version'}) {
		# Already the latest
		print &text('images_already', $got->{'version'}),"<p>\n";
		}
	else {
		# Download the .img file
		$got = &download_server_image($img);
		if (!ref($got)) {
			print &text('images_eget', $got),"<p>\n";
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
			# Refresh left frame if this was the first Xen image
			@old = grep { $_->{'manager'} eq $got->{'manager'} }
				    @images;
			if (!@old &&defined(&theme_post_save_server)) {
				&theme_post_save_server();
				}

			print &text('images_got',
				    &nice_size($got->{'size'})),"<p>\n";
			}
		}
	}

&ui_print_footer("list_images.cgi", $text{'images_return'});

