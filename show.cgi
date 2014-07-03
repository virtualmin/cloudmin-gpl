#!/usr/local/bin/perl
# show.cgi
# Output some file for the browser

require './server-manager-lib.pl';
&ReadParse();
$in{'id'} =~ s/\0.*$//;
$server = &get_managed_server($in{'id'});
$server || &error($text{'edit_egone'});
if (!&can_action($server, "transfer")) {
	$err = "You are not allowed to transfer files";
	}
else {
	$err = &temp_mount_filesystem_if_needed($server);
	}

if ($err) {
	print "Content-type: text/plain\n\n";
	print $err,"\n";
	return;
	}

use POSIX;
$p = $ENV{'PATH_INFO'};
($p =~ /^\s*\|/ || $p =~ /\|\s*$/ || $p =~ /\0/) &&
	&error($text{'view_epathinfo'});
if ($in{'type'}) {
	# Use the supplied content type
	$type = $in{'type'};
	$download = 1;
	}
elsif ($in{'format'} == 1) {
	# Type comes from compression format
	$type = "application/zip";
	}
elsif ($in{'format'} == 2) {
	$type = "application/x-gzip";
	}
elsif ($in{'format'} == 3) {
	$type = "application/x-tar";
	}
else {
	# Try to guess type from filename
	$type = &guess_mime_type($p, undef);
	if (!$type) {
		# No idea .. use the 'file' command
		$out = &execute_command_on_server($server,
			"file ".quotemeta(&resolve_links($p)), 1);
		if ($out =~ /text|script/) {
			$type = "text/plain";
			}
		else {
			$type = "application/unknown";
			}
		}
	}

# If just testing existence, simply stat the file
if ($in{'test'}) {
	print "Content-type: text/plain\n\n";
	@st = &stat_file_on_server($server, $p);
	if (@st == 1) {
		print $st[0],"\n";
		}
	elsif (!@st) {
		print "File does not exist!\n";
		}
	else {
		print "\n";
		}
	return;
	}

# Download the file
$temp = &transname();
$err = &get_file_from_server($server, $p, $temp);
if ($err) {
	print "Content-type: text/plain\n\n";
	print $err,"\n";
	return;
	}
@st = stat($temp);

# Read and print it
print "X-no-links: 1\n";
print "Content-length: $st[7]\n";
print "Content-Disposition: Attachment\n" if ($download);
print "X-Content-Type-Options: nosniff\n";
&print_content_type($type);
open(FILE, $temp);
if ($type =~ /^text\/html/i && !$in{'edit'}) {
	while(read(FILE, $buf, 1024)) {
		$data .= $buf;
		}
	print &filter_javascript($data);
	}
else {
	while(read(FILE, $buf, 1024)) {
		print $buf;
		}
	}
close(FILE);
&unlink_file($temp);
