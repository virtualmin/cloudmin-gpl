#!/usr/local/bin/perl
# Show a form for creating an image from a CD iso or raw disk

require './server-manager-lib.pl';
&error_setup($text{'mimage_err'});
&can_action_error(undef, "global");
&ReadParse();

# Validate inputs
# XXX

&ui_print_unbuffered_header(undef, $text{'mimage_title'}, "");

# Create image object
# XXX

# Copy file to all storage locations
# XXX
