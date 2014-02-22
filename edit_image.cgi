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
	print &ui_hidden("mode", $in{'mode'});
	print &ui_hidden("search", $in{'search'});
	}
print &ui_table_start($text{'eimage_header'}, undef, 2, [ "nowrap" ]);

print &ui_table_row($text{'eimage_id'}, $i->{'id'});

# Description
if ($got) {
	print &ui_table_row($text{'eimage_desc'},
		&ui_textbox("desc", $i->{'desc'}, 40));
	}
else {
	print &ui_table_row($text{'eimage_desc'}, $i->{'desc'});
	}

# Version we have locally, if any
if ($got && $got->{'version'}) {
	print &ui_table_row($text{'eimage_version'}, $got->{'version'});
	}

# Version available, if any
if ($avail && $avail->{'version'}) {
	print &ui_table_row($text{'eimage_aversion'}, $avail->{'version'});
	}

# Creation date
if ($got && $got->{'created'}) {
	print &ui_table_row($avail ? $text{'eimage_dtime'}
				   : $text{'eimage_ctime'},
			    &make_date($got->{'created'}));
	}

# OS type
($os) = grep { $_->[0] eq $i->{'type'} } @servers::server_types;
if ($got) {
	print &ui_table_row($text{'eimage_os'},
		    &ui_select("type", $got->{'type'} || 'unknown',
		      [ map { [ $_->[0], $_->[1] ] }
			sort { $a->[1] cmp $b->[1] } @servers::server_types ]));
	}
elsif ($os) {
	print &ui_table_row($text{'eimage_os'}, $os->[1]);
	}

# VPS type
$tfunc = "type_".$i->{'manager'}."_desc";
print &ui_table_row($text{'eimage_type'}, &$tfunc());

# Format
if ($got && $got->{'format'}) {
	print &ui_table_row($text{'eimage_format'},
		$text{'mimage_fmt'.$got->{'format'}});
	}

# Status (available or not)
print &ui_table_row($text{'eimage_status'},
		    $got && $got->{'partial'} ?
			&text('images_partial',
                              &nice_size($got->{'partialsize'})) :
		    $got && !$avail ? $text{'images_local'} :
		    !$got && $avail ? $text{'images_down'} :
		    $got->{'version'} < $avail->{'version'} ?
			"<font color=#aaaa00>".
			  &text('images_new', $avail->{'version'})."</font>" :
			"<font color=#00aa00>$text{'images_avail'}</font>");

# Compressed size
print &ui_table_row($text{'eimage_size'},
		    &nice_size($i->{'size'}));

# Un-compressed size
if ($i->{'rawsize'}) {
	print &ui_table_row($text{'eimage_rawsize'},
			    &nice_size($i->{'rawsize'}));
	}

# If we have downloaded the image, shown more details
if ($got) {
	# Files it contains
	print &ui_table_row($text{'eimage_files'},
			    "<tt>$got->{'files'}</tt>");

	# Storage locations
	print &ui_table_row($text{'eimage_dest'},
		join("<br>\n", map { &nice_image_destination($_) }
				   split(/\s+/, $got->{'dest'})));

	# Delete files when removing?
	print &ui_table_row($text{'eimage_nodelete'},
		&ui_yesno_radio("nodelete", !$i->{'nodelete'}));

	# Default image
	print &ui_table_row(&text('eimage_default', &$tfunc()),
		&ui_yesno_radio("default", $got->{'default'}));

	# Clear keys when creating system
	print &ui_table_row($text{'eimage_keepkeys'},
		&ui_yesno_radio("keepkeys", $got->{'keepkeys'}));

	# Systems using it
	@users = grep { $_->{'image'} eq $i->{'id'} } &list_managed_servers();
	$users = @users == 0 ? $text{'keys_nousers'} :
		 @users > 8 ? &text('keys_manyusers', scalar(@users)) :
		   join(", ", map { "<tt><a href='edit_serv.cgi?".
				    "id=$_->{'id'}'>$_->{'host'}</a></tt>" }
				  @users);
	print &ui_table_row($text{'eimage_users'}, $users);

	# Post-creation scripts
	print &ui_table_row($text{'eimage_postcmdon'},
		&ui_textbox("postcmdon", $got->{'postcmdon'}, 60));
	print &ui_table_row($text{'eimage_postcmdoff'},
		&ui_textbox("postcmdoff", $got->{'postcmdoff'}, 60));
	}

# MD5 checksum, if we have it
@md5s = split(/\s+/, $i->{'md5'});
if (@md5s && $md5s[0] ne "-") {
	print &ui_table_row($text{'eimage_md5'},
		"<tt>".join(" ", @md5s)."</tt>");
	}

# Check if can convert
if ($got) {
	$cfunc = "type_".$i->{'manager'}."_can_convert_image";
	@convs = defined(&$cfunc) ? &$cfunc($got) : ();
	@convs = grep { $server_management_types{$_->{'manager'}} } @convs;
	@copts = map { [ $_->{'manager'}, $text{$_->{'manager'}.'_typedesc'} ] }
		     @convs;
	}

print &ui_table_end();
if ($got) {
	print &ui_form_end([ [ '', $text{'save'} ],
			     [ 'delete', $text{'eimage_delete'} ],
			     @convs ? ( [ 'convert', $text{'eimage_convert'},
					  &ui_select("convto", undef, \@copts) ]
				      ) : ( ),
			   ]);
	}

&ui_print_footer("list_images.cgi?mode=$in{'mode'}&search=".
		 &urlize($in{'search'}), $text{'images_return'});
