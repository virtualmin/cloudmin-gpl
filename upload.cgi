#!/usr/local/bin/perl
# Upload a file to a Cloudmin system

require './server-manager-lib.pl';
&ReadParseMime();
&error_setup($text{'upload_err'});
$server = &get_managed_server($in{'id'});
$server || &error($text{'edit_egone'});
&can_action_error($server, "transfer");

# Validate inputs, and get the file
if ($in{'source'} == 0) {
	$in{'local'} || &error($text{'upload_elocal'});
	$in{'local_filename'} =~ s/^.*[\\\/]//;
	$source = &transname($in{'local_filename'});
	$sourcename = $in{'local_filename'};
	&open_tempfile(SOURCE, ">$source", 0, 1);
	&print_tempfile(SOURCE, $in{'local'});
	&close_tempfile(SOURCE);
	}
else {
	-f $in{'file'} || &error($text{'upload_efile'});
	$source = $in{'file'};
	$sourcename = $source;
	}
$in{'dest'} =~ /^\// || &error($text{'upload_edest'});

# Do the upload
&ui_print_unbuffered_header(&server_in($server), $text{'upload_title'}, "");

print &text('upload_doing', "<tt>$sourcename</tt>",
			    "<tt>$in{'dest'}</tt>"),"<br>\n";
$err = &put_file_to_server($server, $source, $in{'dest'});
if ($err) {
	print &text('upload_failed', $err),"<p>\n";
	}
else {
	print $text{'upload_done'},"<p>\n";
	&webmin_log("upload", "file", $server->{'host'},
		    { 'file' => $in{'dest'} });
	}

&ui_print_footer("transfer_form.cgi?id=$in{'id'}&mode=upload",
		 $text{'transfer_return'},
		 "", $text{'index_return'});

