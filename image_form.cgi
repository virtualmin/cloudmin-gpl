#!/usr/local/bin/perl
# Show a form for creating a system image

require './server-manager-lib.pl';
&ReadParse();
($server) = grep { $_->{'id'} == $in{'id'} } &list_managed_servers();
$server || &error($text{'edit_egone'});
&can_action_error($server, "image");

&ui_print_header(&server_in($server), $text{'mkimage_title'}, "", "mkimage");

print $text{'mkimage_desc2'},"<p>\n";
if ($server->{'status'} ne 'down') {
	print $text{'mkimage_desc3'},"<p>\n";
	}

print &ui_form_start("create_image.cgi", "post");
print &ui_hidden("id", $in{'id'});
print &ui_table_start($text{'mkimage_header'}, undef, 2);

# System type
$tfunc = "type_".$server->{'manager'}."_desc";
print &ui_table_row($text{'mkimage_type'},
		    &$tfunc());

# Image ID (new or old)
@images = &list_server_images($server->{'manager'});
if (!$config{'vm2_overwrite'}) {
	@images = grep { !$_->{'vm2'} } @images;
	}
if (@images) {
	print &ui_table_row($text{'mkimage_id'},
	    &ui_radio("imageid_def", 0,
		[ [ 0, &text('mkimage_new',
			     &ui_textbox("imageid", undef, 30))."<br>" ],
		  [ 1, &text('mkimage_over',
			&ui_select("oldid", undef,
				   [ map { [ $_->{'id'} ] } @images ])) ],
		]));
	}
else {
	print &ui_table_row($text{'mkimage_id'},
			    &ui_textbox("imageid", undef, 30));
	}

# Description
print &ui_table_row($text{'mkimage_desc'},
		    &ui_textbox("desc", undef, 60));

# Version number
print &ui_table_row($text{'mkimage_version'},
		    &ui_opt_textbox("version", undef, 5,
				    $text{'mkimage_none'}));

# Clear serials?
print &ui_table_row($text{'newami_munge'},
		    &ui_yesno_radio("munge", 1));

# Compress image
print &ui_table_row($text{'mkimage_compress'},
		    &ui_yesno_radio("compress", 1));

print &ui_table_end();
print &ui_form_end([ [ undef, $text{'mkimage_ok'} ] ]);

&ui_print_footer("edit_serv.cgi?id=$in{'id'}", $text{'edit_return'});
