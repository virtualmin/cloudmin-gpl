#!/usr/local/bin/perl
# Show a form for creating an image from a CD iso or raw disk

require './server-manager-lib.pl';
&error_setup($text{'mimage_err'});
&can_action_error(undef, "global");
&ReadParse();

&ui_print_unbuffered_header(undef, $text{'mimage_title'}, "");

# Validate inputs and create object
$image = { 'manager' => $in{'manager'},
	   'format' => $in{'format'},
	   'type' => $in{'type'},
	   'nocompress' => 1 };
$in{'imageid'} =~ /^\S+$/ || &error($text{'mkimage_eid'});
($clash) = grep { $_->{'id'} eq $in{'imageid'} } &list_server_images();
$clash && &error($text{'mkimage_eclash'});
$image->{'id'} = $in{'imageid'};
$in{'desc'} =~ /\S/ || &error($text{'mkimage_edesc'});
$image->{'desc'} = $in{'desc'};

# Get the file
if ($in{'file_mode'} == 0) {
	# On Cloudmin master
	$srcserver = &get_this_managed_server();
	$srcpath = $in{'file'};
	-r $srcpath && !-d $srcpath || &error($text{'mimage_efile'});
	}
elsif ($in{'file_mode'} == 1) {
	# On another system
	$srcserver = &get_managed_server($in{'server'});
	$srcserver || &error($text{'mimage_eserver'});
	$srcpath = $in{'serverfile'};
	$srcpath =~ /^\/\S/ || &error($text{'mimage_eserverfile'});
	}
else {
	# Download from a URL
	$in{'url'} =~ /^(http|https):\/\// ||
		&error($text{'mimage_eurl'});
	($host, $port, $page, $ssl) = &parse_http_url($in{'url'});
	$host && $page || &error($text{'mimage_eurl'});
	$srcserver = &get_this_managed_server();
	$srcpage = $page;
	$srcpage =~ s/^.*[\\\/]//;
	$srcpath = &transname($srcpage);
	$progress_callback_url = $in{'url'};
	&http_download($host, $port, $page, $srcpath, undef,
			\&progress_callback, $ssl);
	$srcdelete = 1;
	}
$image->{'files'} = $srcpath;
$image->{'files'} =~ s/^.*\///;
@st = &stat_file_on_server($srcserver, $srcpath);
@st || &error($text{'mimage_efile'});

# Validate format
if (&has_command_on_server($srcserver, "file")) {
	($fout, $ex, $err) = &execute_command_on_server(
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
		$fout =~ /(ext(\d+)|reiserfs|xfs|jfs)\s+filesystem/i ||
			&error(&text('mimage_epart',
				     "<tt>".&html_escape($fout)."</tt>"));
		}
	elsif ($in{'format'} eq 'disk') {
		# Whole disk must have a boot sector
		$fout =~ /boot\s+sector/i ||
			&error(&text('mimage_edisk',
				     "<tt>".&html_escape($fout)."</tt>"));
		}
	elsif ($in{'format'} eq 'qcow2' || $in{'format'} eq 'qcow') {
		# Must be a QCOW2 or QCOW image
		($qout, $qex, $qerr) = &execute_command_on_server(
			$srcserver, "qemu-img info ".quotemeta($srcpath));
		$qout =~ /format:\s+(\S+)/ && $1 eq $in{'format'} ||
			&error(&text('mimage_efmt'.$in{'format'},
				     "<tt>".&html_escape($qex ? $fout :
						 $1 ? $1 : $qout)."</tt>"));
		}
	}

# Convert to raw format first
if ($in{'format'} eq 'qcow2' || $in{'format'} eq 'qcow') {
	&$first_print($text{'mimage_'.$in{'format'}});
	my $rawsrcpath = $srcpath.".raw";
	my $rawfile = $image->{'files'}.".raw";
	($out, $ex, $err) = &execute_command_on_server($srcserver,
		"qemu-img convert -f $in{'format'} ".quotemeta($srcpath).
		" -O raw ".quotemeta($rawsrcpath));
	if ($ex || $err) {
		&$second_print(&text('mimage_eqcow2',
				     &html_escape($err || $out)));
		goto FAILED;
		}
	if ($srcdelete) {
		&delete_file_on_server($srcserver, $srcpath);
		}
	$srcpath = $rawsrcpath;
	$image->{'files'} = $rawfile;
	$image->{'format'} = 'raw';
	@st = &stat_file_on_server($srcserver, $srcpath);
	$image->{'rawsize'} = $st[7];
	$srcdelete = 1;
	&$second_print(&text('mimage_qcow2done', &nice_size($st[7])));
	}

# Work out un-compressed size if needed
if (!$image->{'nocompress'}) {
	&$first_print($text{'mimage_rawsize'});
	($out, $ex, $err) = &execute_command_on_server($srcserver,
		"gunzip -c ".quotemeta($srcpath)." | wc -c");
	if ($out =~ /^(\d+)/) {
		$image->{'rawsize'} = $1;
		&$second_print(&text('mimage_rawsized',
				     &nice_size($image->{'rawsize'})));
		}
	else {
		&error(&text('mimage_erawsize', $err || $out));
		}
	}

# Copy file to all storage locations
@stors = &list_storages();
&$first_print(&text('mimage_copying',
	join(" , ", map { &nice_image_destination($_->{'dest'}) } @stors)));
$okcount = $errcount = 0;
@dests = ( );
foreach $stor (@stors) {
	($destserver, $destpath) = &get_image_dest_path($stor->{'dest'});
	if ($destserver) {
		my $err = &transfer_file_between_servers(
			$srcserver, $destserver,
			$srcpath, $destpath."/".$image->{'files'}, 0, 1);
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
	if ($image->{'nocompress'}) {
		$image->{'rawsize'} = $image->{'size'};
		}
	get_image_md5s($image);
	&save_server_image($image);
	&webmin_log("manual", "image", $image->{'id'});
	&$second_print($text{'create_done'});
	}

# Clean up downloaded file
FAILED:
if ($srcdelete) {
	&delete_file_on_server($srcserver, $srcpath);
	}

&ui_print_footer("list_images.cgi?mode=$in{'mode'}", $text{'images_return'},
		 "", $text{'index_return'});

