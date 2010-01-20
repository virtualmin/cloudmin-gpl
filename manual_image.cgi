#!/usr/local/bin/perl
# Show a form for creating an image from a CD iso or raw disk

require './server-manager-lib.pl';
&error_setup($text{'mimage_err'});
&can_action_error(undef, "global");
&ReadParse();

# Validate inputs and create object
$image = { 'manager' => 'xen',
	   'format' => $in{'format'},
	   'type' => $in{'type'} };
if ($in{'file_mode'} == 0) {
	$srcserver = &get_this_managed_server();
	$srcpath = $in{'file'};
	-r $srcpath && !-d $srcpath || &error($text{'mimage_efile'};
	}
else {
	$srcserver = &get_managed_server($in{'server'});
	$srcserver || &error($text{'mimage_eserver'});
	$srcpath = $in{'serverfile'};
	$srcpath =~ /^\/\S/ || &error($text{'mimage_eserverfile'});
	}
@st = &stat_file_on_server($srcserver, $srcpath);
@st || &error($text{'mimage_efile'});
$in{'imageid'} =~ /^\S+$/ || &error($text{'mkimage_eid'});
($clash) = grep { $_->{'id'} eq $in{'imageid'} } &list_server_images();
$clash && &error($text{'mkimage_eclash'});
$image->{'id'} = $in{'imageid'};
$in{'desc'} =~ /\S/ || &error($text{'mkimage_edesc'});
$image->{'desc'} = $in{'desc'};

&ui_print_unbuffered_header(undef, $text{'mimage_title'}, "");

# Check if compressed
# XXX

# Validate format
# XXX

# Copy file to all storage locations
# XXX

# Save image object
&generate_image_size($image);
get_image_md5s($image);
&save_server_image($image);

# Update storage sizes
# compute_storage_size(&storage)

