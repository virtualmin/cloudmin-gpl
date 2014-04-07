#!/usr/local/bin/perl
# Extract a zip, tar, tar.gz or tar.bz file on a remote server

require './server-manager-lib.pl';
&foreign_require("file");
&ReadParse();
$server = &get_managed_server($in{'id'});
$server || &error($text{'edit_egone'});
&can_action_error($server, "transfer");

print "Content-type: text/plain\n\n";
if (!&can_ssh_status($server)) {
	print $text{'filemanager_eextract'},"\n";
	return;
	}

# Work out the extraction command
$path = $in{'file'};
if ($path !~ /^\// || $path !~ /^(.*\/)/) {
	print $text{'filemanager_epath'},"\n";
        return;
	}
local $dir = $1;
local $qdir = quotemeta($dir);
local $qpath = quotemeta($path);
if ($path =~ /\.zip$/i) {
	# Extract zip file
	$cmd = "unzip -o $qpath";
	}
elsif ($path =~ /\.tar$/i) {
	# Extract un-compressed tar file
	$cmd = "tar xf $qpath";
	}
elsif ($path =~ /\.(tar\.gz|tgz|tar\.bz|tbz|tar\.bz2|tbz2)$/i) {
	# Extract gzip or bzip2-compressed tar file
	$zipper = $path =~ /bz(2?)$/i ? "bunzip2" : "gunzip";
	$cmd = "$zipper -c $qpath | tar xf -";
	}
elsif ($path =~ /\.gz$/i) {
	# Uncompress gzipped file
	$final = $path;
	$final =~ s/\.gz$//;
	$qfinal = quotemeta($final);
	$cmd = "gunzip -c $qpath >$qfinal";
	}
else {
	print $file::text{'zip_ename'},"\n";
	return;
	}

# Run it
$cmd = "(cd $qdir && $cmd) 2>&1 </dev/null";
($out, $ex, $err) = &execute_command_on_server($server, $cmd);
if ($err) {
	print $err,"\n";
	}
elsif ($ex) {
	print $out,"\n";
	}
else {
	if ($in{'delete'}) {
		&delete_file_on_server($server, $path);
		}
	print "\n";
	}
