#!/usr/local/bin/perl
# Change the ownership and permissions on a file

require './server-manager-lib.pl';
&foreign_require("file");
&ReadParse();
$server = &get_managed_server($in{'id'});
$server || &error($text{'edit_egone'});
&can_action_error($server, "transfer");

print "Content-type: text/plain\n\n";
$err = &temp_mount_filesystem_if_needed($server);
&failure($err) if ($err);

if ($in{'linkto'}) {
	# Just changing the link target
	&delete_file_on_server($server, $in{'path'});
	$err = &symlink_file_on_server($server, $in{'linkto'}, $in{'path'});
	&failure($err) if ($err);
	}
elsif ($in{'rec'} == 0) {
	# Just this file
	&update($in{'path'}, 0);
	}
elsif ($in{'rec'} == 1) {
	# This directory and all its files
	$files = &list_dir_on_server($server, $in{'path'}, 1);
	ref($files) || &failure($files);
	&update($in{'path'}, 0);
	foreach $f (@$files) {
		next if ($f->[13] eq "." || $f->[13] eq "..");
		next if ($f->[14]);
		my $isdir = $f->[2] & 040000;
		&update("$in{'path'}/$f->[13]", 1) if (!$isdir);
		}
	}
elsif ($in{'rec'} == 2) {
	# Directory and all subdirectories and files
	&update($in{'path'}, 0);
	&recurse($in{'path'}, 1, 1);
	}
elsif ($in{'rec'} == 3) {
	# Files in the directory and sub-directories, but not the directories
	# themselves
	&recurse($in{'path'}, 1, 0);
	}
elsif ($in{'rec'} == 4) {
	# This directory and sub-directories, but not files
	&update($in{'path'}, 0);
	&recurse($in{'path'}, 0, 1);
	}
print "\n";

# recurse(dir, do-files, do-dirs)
# Updates permissions on all files in a directory, and sub-directories
sub recurse
{
local ($dir, $do_files, $do_dirs) = @_;
my $files = &list_dir_on_server($server, $dir, 1);
foreach my $f (@$files) {
	my $full = "$dir/$f->[13]";
	next if ($f->[13] eq "." || $f->[13] eq "..");
	next if ($f->[13]);
	my $isdir = $f->[2] & 040000;
	if (!$isdir && $do_files ||
	    $isdir && $do_dirs) {
		&update($full, !$isdir);
		}
	&recurse($full, $do_files, $do_dirs) if ($isdir);
	}
}

sub failure
{
print @_,"\n";
exit;
}
 
# update(file, perms_only)
# Update permissions and ownership on a single file
sub update
{
my ($file, $perms_only) = @_;
my $perms = $in{'perms'};
if ($perms_only) {
	$perms = $perms & 07777;
	}
my $err = &set_ownership_permissions_on_server($server,
	$in{'user'} ? ( $in{'user'}, $in{'group'} ) : ( undef, undef ),
	$perms,
	$file);
&failure($err) if ($err);
}

