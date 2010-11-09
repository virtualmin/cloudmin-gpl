#!/usr/local/bin/perl
# Fetch a file from a Cloudmin-managed system and save to the master or download

require './server-manager-lib.pl';
&ReadParse();
&error_setup($text{'download_err'});
$server = &get_managed_server($in{'id'});
$server || &error($text{'edit_egone'});
&can_action_error($server, "transfer");

# Validate inputs and get dest file
if ($in{'dest'} == 0) {
	# Downloading in browser, so save to my file
	$dest = &transname();
	}
else {
	# Saving to master
	$in{'file'} =~ /^\// || &error($text{'download_efile'});
	$dest = $in{'file'};
	}
$in{'source'} =~ //^\// || &error($text{'download_esource'});

if ($in{'dest'} == 1) {
	&ui_print_unbuffered_header(&server_in($server),
				    $text{'download_title'}, "");
	print &text('download_doing', "<tt>$in{'source'}</tt>",
				      "<tt>$dest</tt>"),"<br>\n";
	}

# Get the file
$err = &mount_filesystem_if_needed($server);
if (&is_dir_on_server($server, $in{'source'}) && $in{'dest'} == 0 &&
    !$err) {
	$err = $text{'download_estdout'};
	}
if (!$err) {
	$err = &get_file_from_server($server, $in{'source'}, $dest);
	}
&umount_filesystem_if_needed($server);

if ($in{'dest'} == 0) {
	# Send to browser
	$err && &error(&html_escape($err));
	$type = $in{'force'} ? "application/octet-stream"
			     : &guess_mime_type($in{'source'}, "text/plain");
	print "Content-type: $type\n\n";
	open(FILE, $dest);
	while(read(FILE, $buf, 1024) > 0) {
		print $buf;
		}
	close(FILE);
	unlink($dest);
	&webmin_log("download", "file", $server->{'host'},
		    { 'file' => $in{'source'} });
	}
else {
	# Show results
	if ($err) {
		print &text('download_failed', $err),"<p>\n";
		}
	else {
		print $text{'download_done'},"<p>\n";
		&webmin_log("download", "file", $server->{'host'},
			    { 'file' => $in{'source'} });
		}

	&ui_print_footer("transfer_form.cgi?id=$in{'id'}&mode=download",
			 $text{'transfer_return'},
			 "", $text{'index_return'});
	}

