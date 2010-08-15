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
	$in{'upload'} || &error($text{'mimage_eupload'});
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
&has_command_on_server($srcserver, "file") ||
	&error(&text('mimage_efilecmd', 'file'));

# Validate format
($fout, $ex, $err) = &execute_command_on_server(
	$srcserver, "file ".quotemeta($srcpath));
$fout =~ s/^\S+:\s+//;
$fout =~ s/\r|\n//g;
if ($fout =~ /(gzip|bzip2)\s+compressed/) {
	# Compressed .. need to un-compress first to validate format
	&$first_print($text{'mimage_gunzip'});
	$cmd = $1 eq "bzip2" ? "bunzip2" : "gunzip";
	my $uncompressedsrcpath = $srcpath.".uncompressed";
	($out, $ex, $err) = &execute_command_on_server($srcserver,
		"$cmd -c ".quotemeta($srcpath).
		" > ".quotemeta($uncompressedsrcpath));
	if ($ex || $err) {
		&$second_print(&text('mimage_egunzip',
				     &html_escape($err || $out)));
		goto FAILED;
		}
	if ($srcdelete) {
		&delete_file_on_server($srcserver, $srcpath);
		}
	$srcpath = $uncompressedsrcpath;
	$image->{'files'} .= ".uncompressed";
	$srcdelete = 1;
	@st = &stat_file_on_server($srcserver, $srcpath);
	&$second_print(&text('mimage_gunzipdone', &nice_size($st[7])));

	# Re-check format
	($fout, $ex, $err) = &execute_command_on_server(
		$srcserver, "file ".quotemeta($srcpath));
	$fout =~ s/^\S+:\s+//;
	$fout =~ s/\r|\n//g;
	}

if ($in{'format'} eq "cd") {
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
elsif ($in{'format'} eq 'qcow2' || $in{'format'} eq 'qcow' ||
       $in{'format'} eq 'vmdk') {
	# Must be a QCOW2, QCOW or VMware image
	($qout, $qex, $qerr) = &execute_command_on_server(
		$srcserver, "qemu-img info ".quotemeta($srcpath));
	$qout =~ /format:\s+(\S+)/ && $1 eq $in{'format'} ||
		&error(&text('mimage_efmt'.$in{'format'},
			     "<tt>".&html_escape($qex ? $fout :
					 $1 ? $1 : $qout)."</tt>"));
	}

# Convert from QCOW, QCOW2 or VMware to raw disk format
if ($in{'format'} eq 'qcow2' || $in{'format'} eq 'qcow' ||
    $in{'format'} eq 'vmdk') {
	&$first_print($text{'mimage_'.$in{'format'}});
	my $rawsrcpath = $srcpath.".disk";
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
	$image->{'nocompress'} = 1;
	$image->{'files'} .= ".disk";
	$image->{'format'} = 'disk';
	$srcdelete = 1;
	@st = &stat_file_on_server($srcserver, $srcpath);
	&$second_print(&text('mimage_qcow2done', &nice_size($st[7])));
	}

# Extract biggest partition from whole disk image
if ($image->{'format'} eq 'disk' && $in{'manager'} eq 'xen') {
	&$first_print($text{'mimage_part'});

	# Find the biggest partition
	my $parts = &list_disk_image_partitions($srcserver, $srcpath);
	if (!ref($parts)) {
		&$second_print(&text('mimage_eparts', $parts));
		goto FAILED;
		}
	my $bigp;
	foreach my $p (@$parts) {
		if ($p->{'type'} eq '83' && $p->{'offset'} &&
		    (!$bigp || $p->{'blocks'} > $bigp->{'blocks'})) {
			$bigp = $p;
			}
		}
	if (!$bigp) {
		&$second_print($text{'mimage_ebigp'});
		goto FAILED;
		}

	# Work out a good block size for dd
	$partsrcpath = $srcpath.".part";
	my $bs = 512;
	if (($bigp->{'start_bytes'} % 32256) == 0 &&
	    ($bigp->{'size_bytes'} % 32256) == 0) {
		# This seems to be the default for most disks
		$bs = 32256;
		}
	else {
		# Get largest size starting at 512
		for(my $bstry = 512;
		    ($bigp->{'start_bytes'} % $bstry == 0) &&
		    ($bigp->{'size_bytes'} % $bstry == 0);
		    $bstry *= 2) {
			$bs = $bstry;
			}
		}

	# Extract the filesystem with dd
	$bstart = int($bigp->{'start_bytes'} / $bs);
	$bcount = int($bigp->{'size_bytes'} / $bs);
	($out, $ex, $err) = &execute_command_on_server($srcserver,
		"dd if=".quotemeta($srcpath)." ".
		"of=".quotemeta($partsrcpath)." ".
		"bs=$bs skip=$bstart count=$bcount");
	if ($ex || $err) {
		&$second_print(&text('mimage_epartdd',
				     &html_escape($err || $out)));
		goto FAILED;
		}
	if ($srcdelete) {
		&delete_file_on_server($srcserver, $srcpath);
		}
	$srcpath = $partsrcpath;
	$image->{'nocompress'} = 1;
	$image->{'files'} .= ".part";
	$image->{'format'} = '';
	$srcdelete = 1;
	@st = &stat_file_on_server($srcserver, $srcpath);
	&$second_print(&text('mimage_partdone', &nice_size($st[7])));
	}

if ($image->{'nocompress'} && $in{'compress'}) {
	# Not currently compressed, compress it now
	&$first_print($text{'mimage_gzip'});
	@st = &stat_file_on_server($srcserver, $srcpath);
	$image->{'rawsize'} = $st[7];
	my $compsrcpath = $srcpath.".gz";
	($out, $ex, $err) = &execute_command_on_server($srcserver,
		"gzip -c ".quotemeta($srcpath)." >".quotemeta($compsrcpath));
	if ($ex || $err) {
		&$second_print(&text('mimage_egzip',
				     &html_escape($err || $out)));
		goto FAILED;
		}
	if ($srcdelete) {
		&delete_file_on_server($srcserver, $srcpath);
		}
	$srcpath = $compsrcpath;
	$image->{'nocompress'} = 0;
	$image->{'files'} .= ".gz";
	$srcdelete = 1;
	@st = &stat_file_on_server($srcserver, $srcpath);
	&$second_print(&text('mimage_gzipdone', &nice_size($image->{'rawsize'}),
						&nice_size($st[7])));
	}
elsif (!$image->{'nocompress'} && $in{'compress'}) {
	# Already compressed, work out un-compressed size
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
elsif ($image->{'nocompress'} && !$in{'compress'}) {
	# Not compressed and doesn't need to be .. raw size is just size
	$image->{'rawsize'} = $image->{'size'};
	}
elsif (!$image->{'nocompress'} && !$in{'compress'}) {
	# Already compressed, but user doesn't want it to be .. uncompress
	&$first_print($text{'mimage_gunzip'});
	my $compsrcpath = $srcpath;
	($srcpath =~ s/\.gz$//) || ($srcpath .= ".nogz");
	($out, $ex, $err) = &execute_command_on_server($srcserver,
		"gunzip -c ".quotemeta($srcpath)." >".quotemeta($compsrcpath));
	if ($ex || $err) {
		&$second_print(&text('mimage_egunzip',
				     &html_escape($err || $out)));
		goto FAILED;
		}
	if ($srcdelete) {
		&delete_file_on_server($srcserver, $srcpath);
		}
	$srcpath = $compsrcpath;
	$image->{'nocompress'} = 1;
	($image->{'files'} =~ s/\.gz$//) || ($image->{'files'} .= ".nogz");
	$srcdelete = 1;
	@st = &stat_file_on_server($srcserver, $srcpath);
	$image->{'rawsize'} = $st[7];
	&$second_print(&text('mimage_gunzipdone', &nice_size($st[7])));
	}

# Copy file to all storage locations
if ($in{'upload'}) {
	@stors = &list_storages();
	&$first_print(&text('mimage_copying',
		join(" , ", map { &nice_image_destination($_->{'dest'}) }
				@stors)));
	$okcount = $errcount = 0;
	@dests = ( );
	foreach $stor (@stors) {
		($destserver, $destpath) =
			&get_image_dest_path($stor->{'dest'});
		if ($destserver) {
			my $err = &transfer_file_between_servers(
				$srcserver, $destserver,
				$srcpath, $destpath."/".$image->{'files'}, 0,1);
			if (!$err) {
				&compute_storage_size($stor);
				&save_storage($stor);
				push(@dests, $stor->{'dest'});
				$okcount++;
				}
			else {
				&$first_print(&text('mimage_ecopy',
				    &nice_image_destination($stor->{'dest'}),
				    $err));
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
	}
else {
	# Just save current location as storage
	$image->{'dest'} = "vm2:".$srcserver->{'id'}.":".$srcpath;
	$image->{'dest'} =~ s/[^\/]+$//;
	$image->{'dest'} =~ s/\/$// if ($image->{'dest'} ne '/');
	$image->{'nodelete'} = 1;
	$srcdelete = 0;
	$okcount = 1;
	}

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

