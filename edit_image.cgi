#!/usr/local/bin/perl
# Shows the details of a single image

require './server-manager-lib.pl';
&can_action_error(undef, "global");
&ui_print_header(undef, $text{'eimage_title'}, "", "editimage");
&ReadParse();
($avail) = grep { $_->{'id'} eq $in{'id'} } &list_available_server_images();
($got) = grep { $_->{'id'} eq $in{'id'} } &list_server_images();
$i = $avail || $got;

if ($got) {
	print &ui_form_start("save_image.cgi");
	print &ui_hidden("id", $in{'id'});
	}
print &ui_table_start($text{'eimage_header'}, undef, 2);

print &ui_table_row($text{'eimage_id'}, $i->{'id'});

print &ui_table_row($text{'eimage_desc'}, $i->{'desc'});

$tfunc = "type_".$i->{'manager'}."_desc";
print &ui_table_row($text{'eimage_type'}, &$tfunc());

print &ui_table_row($text{'eimage_status'},
		    $got && $got->{'partial'} ? $text{'images_partial'} :
		    $got && !$avail ? $text{'images_local'} :
		    !$got && $avail ? $text{'images_down'} :
		    $got->{'version'} < $i->{'version'} ?
			"<font color=#aaaa00>".
			  &text('images_new', $i->{'version'})."</font>" :
			"<font color=#00aa00>$text{'images_avail'}</font>");

print &ui_table_row($text{'eimage_size'},
		    &nice_size($i->{'size'}));

if ($i->{'rawsize'}) {
	print &ui_table_row($text{'eimage_rawsize'},
			    &nice_size($i->{'rawsize'}));
	}

# If we have downloaded the image, shown more details
if ($got) {
	print &ui_table_row($text{'eimage_files'},
			    "<tt>$got->{'files'}</tt>");

	@users = grep { $_->{'image'} eq $i->{'id'} } &list_managed_servers();
	$users = @users == 0 ? $text{'keys_nousers'} :
		 @users > 8 ? &text('keys_manyusers', scalar(@users)) :
		   join(", ", map { "<tt><a href='edit_serv.cgi?".
				    "id=$_->{'id'}'>$_->{'host'}</a></tt>" }
				  @users);
	print &ui_table_row($text{'eimage_users'}, $users);
	}

# MD5 checksum, if we have it
@md5s = split(/\s+/, $i->{'md5'});
if (@md5s && $md5s[0] ne "-") {
	print &ui_table_row($text{'eimage_md5'},
		"<tt>".join(" ", @md5s)."</tt>");
	}

print &ui_table_end();
if ($got) {
	print &ui_form_end([ [ "delete", $text{'eimage_delete'} ] ]);
	}

&ui_print_footer("list_images.cgi", $text{'images_return'});
