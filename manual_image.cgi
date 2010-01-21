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
	-r $srcpath && !-d $srcpath || &error($text{'mimage_efile'});
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
$img->{'files'} = $srcpath;
$img->{'files'} =~ s/^.*\///;

# Validate format
if (&has_command_on_server($srcserver, "file")) {
	$fout = &execute_command_on_server(
		$srcserver, "file ".quotemeta($srcpath));
	$fout =~ s/^\S+:\s+//;
	$fout =~ s/\r|\n//g;
	if ($fout =~ /gzip\s+compressed/) {
		# Assume underlying format is OK
		$image->{'nocompress'} = 0;
		}
	elsif ($in{'format'} eq "cd") {
		# CD must have an iso 9660 filesystem
		$fout =~ /iso\s+9660/i ||
			&error(&text('mimage_ecd',
				     "<tt>".&html_escape($fout)."</tt>"));
		}
	elsif ($in{'format'} eq '') {
		# Partition image must be something Linux
		# XXX
		}
	}

&ui_print_unbuffered_header(undef, $text{'mimage_title'}, "");

# Copy file to all storage locations
&$first_print($text{'mimage_copying'});
$okcount = $errcount = 0;
@dests = ( );
foreach $stor (&list_storages()) {
	($destserver, $destpath) = &get_image_dest_path($stor->{'dest'});
	if ($destserver) {
		my $err = &transfer_file_between_servers(
			$srcserver, $destserver,
			$srcpath, $destpath."/".$img->{'files'}, 0, 1);
		if (!$err) {
			&compute_storage_size($stor);
			&save_storage($stor);
			push(@dests, $stor->{'dest'});
			$okcount++;
			}
		else {
			&$first_print(&text('mimage_ecopy',
			    &nice_image_destination($stor->{'dest'}), $err));
			$errcount++;
			}
		}
	}
if (!$okcount) {
	&$second_print($text{'mimage_nocopy'});
	}
elsif ($errcount) {
	&$second_print($text{'mimage_somecopy'});
	}
else {
	&$second_print($text{'mimage_allcopy'});
	}
$image->{'dest'} = join(" ", @dests);

# Save image object
if ($okcount) {
	&$first_print($text{'mimage_saving'});
	&generate_image_size($image);
	get_image_md5s($image);
	&save_server_image($image);
	&$second_print($text{'create_done'});
	}

&ui_print_footer("list_images.cgi", $text{'images_return'},
		 "", $text{'index_return'});

