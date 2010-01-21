#!/usr/local/bin/perl
# Shows a list of server images that are available from Virtualmin and locally

require './server-manager-lib.pl';
&can_action_error(undef, "global");
&ui_print_header(undef, $text{'images_title'}, "", "images");
&ReadParse();

# Get all the available and my images
@avail = &list_available_server_images();
%got_avail = map { $_->{'id'}, $_ } @avail;
@images = &list_server_images();
%got_images = map { $_->{'id'}, $_ } @images;
@combined = @images;
%incombined = map { $_->{'id'}, $_ } @combined;
foreach $i (@avail) {
	push(@combined, $i) if (!$incombined{$i->{'id'}});
	}

# Show links for display mode
print "<b>$text{'images_mode'}</b>\n";
@links = ( );
$in{'mode'} ||= 'all';
foreach $m ("all", "got", "avail", "local", "virtualmin") {
	$msg = $text{'images_mode_'.$m};
	if ($m ne $in{'mode'}) {
		$msg = "<a href='list_images.cgi?mode=$m'>$msg</a>";
		}
	push(@links, $msg);
	}
print &ui_links_row(\@links),"<p>\n";

# Apply mode
if ($in{'mode'} eq 'got') {
	# Only those we have downloaded
	@combined = grep { $got_images{$_->{'id'}} } @combined;
	}
elsif ($in{'mode'} eq 'avail') {
	# Only those we don't have yet
	@combined = grep { !$got_images{$_->{'id'}} } @combined;
	}
elsif ($in{'mode'} eq 'local') {
	# Only those made locally
	@combined = grep { !$got_avail{$_->{'id'}} } @combined;
	}
elsif ($in{'mode'} eq 'virtualmin') {
	# Only those supplied by Virtualmin
	@combined = grep { $got_avail{$_->{'id'}} } @combined;
	}

# Build list of creation links
@links = ( &select_all_link("d"), &select_invert_link("d") );
foreach $t (@virtual_server_management_types) {
	$mfunc = "type_".$t."_can_manual_image";
	if (defined(&$mfunc) && &$mfunc()) {
		push(@links, "<a href='manual_image_form.cgi?type=$t'>".
			     &text('images_create', $text{$t.'_typedesc'}).
			     "</a>");
		}
	}

# Show table of images
print &ui_form_start("get_images.cgi", "post");
print &ui_hidden("mode", $in{'mode'});
print &ui_links_row(\@links);
@tds = ( "width=5" );
$anymissing = $anymissing_dests = $anyextra_dests = 0;
@stors = &list_storages();
$ss = scalar(@stors);
print &ui_columns_start([ "",
			  $text{'images_desc'},
			  $text{'images_manager'},
			  $text{'images_status'},
			  $text{'images_size'},
			  $text{'images_stors'} ]);
foreach $i (sort { $a->{'desc'} cmp $b->{'desc'} } @combined) {
	$tfunc = "type_".$i->{'manager'}."_desc";
	($avail) = grep { $_->{'id'} eq $i->{'id'} } @avail;
	($got) = grep { $_->{'id'} eq $i->{'id'} } @images;
	if ($avail && !$got) {
		$anymissing++;
		}

	# Work out destinations and if any are missing or extra
	if ($got) {
		@dests = split(/\s+/, $got->{'dest'});
		($missing_dests, $extra_dests) =
			&image_storage_mismatches($got, \@stors);
		$anymissing_dests += $missing_dests;
		$anyextra_dests += $extra_dests;
		$stormsg = &text('images_of', scalar(@dests), $ss);
		if ($missing_dests) {
			$stormsg = "<font color=#ff0000>$stormsg</font>";
			}
		}
	else {
		$stormsg = undef;
		}
	print &ui_checked_columns_row([
		"<a href='edit_image.cgi?id=$i->{'id'}&mode=$in{'mode'}'>".
		  "$i->{'desc'}</a>",
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
		$stormsg,
		], \@tds, "d", $i->{'id'});
	}
print &ui_columns_end();
print &ui_links_row(\@links);
print &ui_form_end([
	$anymissing ? ( [ "get", $text{'images_get'} ] ) : ( ),
	$anymissing_dests ? ( [ "copy", $text{'images_copy'} ] ) : ( ),
	$anyextra_dests ? ( [ "move", $text{'images_move'} ] ) : ( ),
	]);

&ui_print_footer("", $text{'index_return'});

