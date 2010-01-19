#!/usr/local/bin/perl
# Show a form for creating an image from a CD iso or raw disk

require './server-manager-lib.pl';
&can_action_error(undef, "global");
&ui_print_header(undef, $text{'mimage_title'}, "", "manualimage");
&ReadParse();

print &ui_form_start("manual_image.cgi", "post");
print &ui_table_start($text{'mimage_header'}, undef, 2);

# Virtualization type
# XXX

# Image type (CD or disk)
# XXX

# Location of file (local, or on some managed system)
# XXX

# Description
# XXX

# Unique ID
# XXX

print &ui_table_end();
print &ui_form_end([ [ undef, $text{'create'} ] ]);

