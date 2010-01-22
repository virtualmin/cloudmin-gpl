#!/usr/local/bin/perl
# Show a form for creating an image from a CD iso or raw disk

require './server-manager-lib.pl';
&can_action_error(undef, "global");
&ui_print_header(undef, $text{'mimage_title'}, "", "manualimage");
&ReadParse();

print &ui_form_start("manual_image.cgi", "post");
print &ui_hidden("manager", $in{'manager'});
print &ui_hidden("mode", $in{'mode'});
print &ui_table_start($text{'mimage_header'}, undef, 2);

# Virtualization type
$dfunc = "type_".$in{'type'}."_desc";
print &ui_table_row($text{'mimage_type'}, &$dfunc());

# Image type (CD or disk)
print &ui_table_row($text{'mimage_format'},
	&ui_radio("format", "cd", [ [ "cd", $text{'mimage_cd'} ],
				    [ "disk", $text{'mimage_disk'} ],
				    [ "", $text{'mimage_part'} ] ]));

# Operating system
print &ui_table_row($text{'eimage_os'},
	    &ui_select("type", 'unknown',
	      [ map { [ $_->[0], $_->[1] ] }
		sort { $a->[1] cmp $b->[1] } @servers::server_types ]));

# Location of file (local, or on some managed system)
@servers = grep { $_->{'id'} ne '0' &&
		  &can_ssh_status($_) } &list_managed_servers_sorted();
print &ui_table_row($text{'mimage_file'},
	&ui_radio_table("file_mode", 0,
		[ [ 0, $text{'mimage_file0'},
		    &ui_filebox("file", undef, 40) ],
		  [ 1, $text{'mimage_file1'},
		    &ui_select("server", undef,
		       [ map { [ $_->{'id'}, $_->{'short_host'} ] } @servers ]).
		    " ".
		    &ui_textbox("serverfile", undef, 40) ] ]));

# Unique ID
print &ui_table_row($text{'mkimage_id'},
		    &ui_textbox("imageid", undef, 30));

# Description
print &ui_table_row($text{'mkimage_desc'},
		    &ui_textbox("desc", undef, 60));

print &ui_table_end();
print &ui_form_end([ [ undef, $text{'create'} ] ]);

&ui_print_footer("list_images.cgi", $text{'images_return'},
		 "", $text{'index_return'});

