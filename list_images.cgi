#!/usr/local/bin/perl
# Shows a list of server images that are available from Virtualmin and locally

require './server-manager-lib.pl';
&can_action_error(undef, "global");
&ui_print_header(undef, $text{'images_title'}, "", "images");

# Get all the available and my images
@avail = &list_available_server_images();
@images = &list_server_images();
@combined = @images;
%incombined = map { $_->{'id'}, $_ } @combined;
foreach $i (@avail) {
	push(@combined, $i) if (!$incombined{$i->{'id'}});
	}

@links = ( &select_all_link("d"), &select_invert_link("d") );
print &ui_form_start("get_images.cgi", "post");
print &ui_links_row(\@links);
@tds = ( "width=5" );
print &ui_columns_start([ "",
			  $text{'images_desc'},
			  $text{'images_manager'},
			  $text{'images_status'},
			  $text{'images_size'} ]);
foreach $i (sort { $a->{'desc'} cmp $b->{'desc'} } @combined) {
	$tfunc = "type_".$i->{'manager'}."_desc";
	($avail) = grep { $_->{'id'} eq $i->{'id'} } @avail;
	($got) = grep { $_->{'id'} eq $i->{'id'} } @images;
	print &ui_checked_columns_row([
		"<a href='edit_image.cgi?id=$i->{'id'}'>$i->{'desc'}</a>",
		&$tfunc(),
		$got && $got->{'partial'} ?
			&text('images_partial',
			      &nice_size($got->{'partialsize'})) :
		$got && !$avail ?
			"<font color=#00aa00>$text{'images_local'}</font>" :
		!$got ? $text{'images_down'} :
		$avail && $got->{'version'} < $avail->{'version'} ?
			"<font color=#aaaa00>".
			  &text('images_new', $avail->{'version'})."</font>" :
			"<font color=#00aa00>$text{'images_avail'}</font>",
		&nice_size($got && !$got->{'partial'} ? $got->{'size'}
						      : $avail->{'size'}),
		], \@tds, "d", $i->{'id'});
	}
print &ui_columns_end();
print &ui_links_row(\@links);
print &ui_form_end([ [ undef, $text{'images_get'} ] ]);

&ui_print_footer("", $text{'index_return'});


