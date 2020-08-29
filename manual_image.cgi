#!/usr/local/bin/perl
# Show a form for creating an image from a CD iso or raw disk

require './server-manager-lib.pl';
&error_setup($text{'mimage_err'});
&can_action_error(undef, "global");
&ReadParse();

&ui_print_unbuffered_header(undef, $text{'import_title'}, "");

# Validate inputs and create object
if ($in{'source'} == 0) {
	# From local or remote file
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
	if ($in{'format'} eq 'cd' && defined($in{'hvm'}) && !$in{'hvm'}) {
		&error($text{'mkimage_ehvmcd'});
		}
	$image->{$in{'manager'}.'_hvm'} = $in{'hvm'};

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

	# Copy device (like /dev/cdrom) to temp file
	if ($srcpath =~ /^\/dev\//) {
		my $regularsrcpath = &tempname_on_server(
					$srcserver, $in{'manager'}."-image-$$");
		&$first_print(&text('mimage_regular', $regularsrcpath));
		my $err = &transfer_file_between_servers($srcserver, $srcserver,
				$srcpath, $regularsrcpath, 1);
		if ($err) {
			&delete_file_on_server($srcserver, $regularsrcpath);
			&$second_print(&text('mimage_eregular', &html_escape($err)));
			goto FAILED;
			}
		if ($srcdelete) {
			&delete_file_on_server($srcserver, $srcpath);
			}
		$srcpath = $regularsrcpath;
		$image->{'files'} = $in{'manager'}."-image-$$";
		$srcdelete = 1;
		&remote_finished();	# In case of timeout
		@st = &stat_file_on_server($srcserver, $srcpath);
		&$second_print(&text('mimage_regulardone', &nice_size($st[7])));
		}
	}
else {
	# From stacklet
	$image = { 'manager' => $in{'manager'},
		   'nocompress' => 1,
		   };

	# Validate the image selected
	my $stacklets = &list_stacklet_images(
				undef, $in{'stackuser'}, $in{'stackpass'});
	ref($stacklets) || &error(&text('mkimage_estacklet', $stacklets));
	my ($stacklet) = grep { $_->{'guid'}->{'content'} eq $in{'stacklet'} }
			      @$stacklets;
	$stacklet || &error(&text('mkimage_eguid', $in{'stacklet'}));
	$image->{'desc'} = $stacklet->{'description'};
	$image->{'src'} = 'stacklet';

	# Pick an image ID and OS type
	my $url = $stacklet->{'enclosure'}->{'url'};
	if ($url =~ /\/([^\/]+)$/) {
		$image->{'id'} = $1;
		while($image->{'id'} =~ s/\.(raw|img|tar|gz|bz2)$//) { }
		}
	else {
		$image->{'id'} = $stacklet->{'guid'}->{'content'};
		}
	my ($distro) = grep { $_->{'domain'} eq 'distro' }
			    @{$stacklet->{'category'}};
	foreach my $t (@servers::server_types) {
		if ($distro && $distro->{'content'} =~ /$t->[0]/i) {
			$image->{'type'} = $t->[0];
			last;
			}
		}
	$image->{'arch'} = $url =~ /x86[\-_]64/ ? 'x86_64' : 'x86';
	$image->{'files'} = $image->{'id'}.".disk";

	# Check for an ID clash
	($clash) = grep { $_->{'id'} eq $image->{'id'} } &list_server_images();
	$clash && &error(&text('mkimage_estackclash', $image->{'id'}));

	# Download the image from stacklet
	my $temp = &transname();
	my $err;
	if ($url =~ /^(http|https):/) {
		# Download via HTTP
		&start_background_dot_printer(
			&text('mkimage_stackdownload', $url));
		my ($host, $port, $page, $ssl) = &parse_http_url($url);
		&http_download($host, $port, $page, $temp, \$err,
			       undef, $ssl);
		}
	elsif ($url =~ /^ftp:\/\/([^\/]+)(\/\S+)$/) {
		# Download via FTP
		&start_background_dot_printer(
			&text('mkimage_stackdownload', $url));
		my ($host, $page, $port) = ($1, $2, 21);
		if ($stacklet->{'stackuser'}) {
			# Use encrypted FTP download
			&ftp_encrypted_download($host, $page, $temp, \$err,
					        undef,
						$stacklet->{'stackuser'},
						$stacklet->{'stackpass'});
			}
		else {
			# Use regular FTP
			&ftp_download($host, $page, $temp, \$err);
			}
		&stop_background_dot_printer();
		}
	else {
		# Invaid URL!
		&error($text{'mkimage_estackurl'});
		}
	if ($err) {
		&$second_print(&text('mkimage_estackdownload', $err));
		goto FAILED;
		}
	else {
		my @st = stat($temp);
		&$second_print(&text('mkimage_stacksize', &nice_size($st[7])));
		}

	# Un-compress the tar.bz2 file
	&$first_print($text{'mkimage_stackuntar'});
	$tempdir = &transname();
	&make_dir($tempdir, 0700);
	$out = &backquote_command("(cd ".quotemeta($tempdir)." && ".
				  " bunzip2 -c ".quotemeta($temp)." | ".
				  "tar xf -) 2>&1");
	if ($?) {
		&$second_print(&text('mkimage_estackuntar',
				     &html_escape($out)));
		goto FAILED;
		}

	# Find the image file in the extracted directory
	$srcserver = &get_this_managed_server();
	($srcpath) = glob("$tempdir/*.img");
	if (!$srcpath) {
		&$second_print($text{'mkimage_estackimgfile'});
		goto FAILED;
		}
	&$second_print($text{'setup_done'});

	# Set format for later validation
	($fout, $ex, $err) = &execute_command_on_server(
		$srcserver, "file ".quotemeta($srcpath));
	$in{'format'} = $fout =~ /boot\s+sector/ ? 'disk' : '';
	$image->{'format'} = $in{'format'};
	$in{'upload'} = 1;
	}

# Validate format
($fout, $ex, $err) = &execute_command_on_server(
	$srcserver, "file ".quotemeta($srcpath));
$fout =~ s/^\S+:\s+//;
$fout =~ s/\r|\n//g;
if ($fout =~ /(gzip|bzip2)\s+compressed/) {
	# Compressed .. need to un-compress first to validate format
	&$first_print($text{'mimage_gunzip'});
	$cmd = $1 eq "bzip2" ? "bunzip2" : "gunzip";
	my $uncompressedsrcpath;
	if ($srcpath =~ /^(.*)\.gz$/) {
		$uncompressedsrcpath = $1;
		}
	else {
		$uncompressedsrcpath = $srcpath.".uncompressed";
		}
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
	if ($image->{'files'} !~ s/\.gz$//) {
		$image->{'files'} .= ".uncompressed";
		}
	$srcdelete = 1;
	&remote_finished();	# In case of timeout
	@st = &stat_file_on_server($srcserver, $srcpath);
	&$second_print(&text('mimage_gunzipdone', &nice_size($st[7])));

	# Re-check format
	($fout, $ex, $err) = &execute_command_on_server(
		$srcserver, "file ".quotemeta($srcpath));
	$fout =~ s/^\S+:\s+//;
	$fout =~ s/\r|\n//g;
	}

&$first_print($text{'mimage_validating'});
if ($in{'format'} eq "cd") {
	# CD must have an iso 9660 filesystem
	$fout =~ /iso\s+9660/i || $fout =~ /x86\s+boot\s+sector/i ||
	    $fout =~ /MBR\s+boot\s+sector/i ||
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
elsif ($in{'format'} eq 'tar') {
	# Must be a tar file now
	$fout =~ /tar\s+archive/i ||
		&error(&text('mimage_etar',
			     "<tt>".&html_escape($fout)."</tt>"));
	}
&$second_print(&text('mimage_validated', $text{'mimage_fmt'.$in{'format'}} ||
					 uc($in{'format'})));

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
	&remote_finished();	# In case of timeout
	@st = &stat_file_on_server($srcserver, $srcpath);
	&$second_print(&text('mimage_qcow2done', &nice_size($st[7])));
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
	&remote_finished();	# In case of timeout
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
	&remote_finished();	# In case of timeout
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
	&remote_finished();	# In case of timeout
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
if ($srcpath eq $in{'file'} && $in{'file_mode'} == 0) {
	# Was converted back to original filename, so don't delete
	$srcdelete = 0;
	}
if ($srcdelete) {
	&delete_file_on_server($srcserver, $srcpath);
	}

&ui_print_footer("list_images.cgi?mode=$in{'mode'}&search=".
		 &urlize($in{'search'}), $text{'images_return'},
		 "", $text{'index_return'});

