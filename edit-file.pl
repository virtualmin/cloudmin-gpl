#!/usr/local/bin/perl

=head1 edit-file.pl

Edits a file on a single system

This script can be used to fetch a single file from a Cloudmin managed system and
either save it on the master, upon which an editor is launched on the downloaded
file. Once the editor exits, the file is re-uploaded to the original system.
The source is selected with the C<--host> flag, which must be followed by a
hostname or IP address. The file to edit is selected with the C<--file> flag.

For OpenVZ, Vservers and Zones systems, the file transfer will be done via the
host system, which works even if the virtual system is down. However, you can
force a transfer via SSH from the target system with the C<--force-ssh> flag.

=head1 Example usage

  cloudmin edit-file --host xencentos.home --file /etc/hosts

=cut

package server_manager;
$main::no_acl_check++;
$ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
$ENV{'WEBMIN_VAR'} ||= "/var/webmin";
if ($0 =~ /^(.*)\/[^\/]+$/) {
	chdir($pwd = $1);
	}
else {
	chop($pwd = `pwd`);
	}
$0 = "$pwd/install-webmin.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";
@OLDARGV = @ARGV;
$ENV{'VIRTUALMIN_REMOTE_API'} &&
	&usage("This cannot cannot be called from the remote API");

# Parse command line
while(@ARGV > 0) {
	my $a = shift(@ARGV);
	if ($a eq "--host") {
		$host = shift(@ARGV);
		}
	elsif ($a eq "--source" || $a eq "--file") {
		$source = shift(@ARGV);
		}
	elsif ($a eq "--multiline") {
		$multiline = 1;
		}
	else {
		&usage("Unknown parameter $a");
		}
	}

# Get the server and check parameters
$host || &usage("Missing --host parameter");
$server = &find_one_managed_server($host);
$server || &usage("No system with hostname $host exists");
$source || &usage("Missing --file parameter");
$editor = $ENV{'EDITOR'} || "vim" || "vi";
@edw = split(/\s+/, $editor);
&has_command($edw[0]) || &usage("No editor was found! Set the EDITOR environment ".
				"variable to the appropriate command");
&can_action_usage($server, "transfer");

# Mount if needed
$err = &mount_filesystem_if_needed($server);
if ($err) {
	print "ERROR: $err\n";
	exit(2);
	}

# Work out temp file
$destdir = &transname();
&make_dir($destdir, 0700);
$sourcefile = $source;
$sourcefile =~ s/^.*\///;
$dest = $destdir."/".$sourcefile;

# Get the file
$newfile = 0;
if (&is_dir_on_server($server, $source)) {
	# Cannot edit a dir
	$err = "A directory cannot be edited";
	}
else {
	# Check if the file exists, and if so download it
	@st = &stat_file_on_server($server, $source);
	if (@st == 1) {
		$err = $st[0];
		}
	elsif (@st) {
		$err = &get_file_from_server($server, $source, $dest, 0, $forcessh);
		}
	else {
		$newfile = 1;
		}
	}
if ($err) {
	&umount_filesystem_if_needed($server);
	print "ERROR: Download failed $err\n";
	exit(1);
	}

# Run an editor
@oldst = stat($dest);
$ex = system("$editor $dest");
if ($ex) {
	&umount_filesystem_if_needed($server);
	print "ERROR: Editor $editor failed\n";
	exit(1);
	}
@newst = stat($dest);
if (!@newst) {
	&umount_filesystem_if_needed($server);
	print "ERROR: File was not saved\n";
	exit(1);
	}
if ($newst[7] == $oldst[7] && $newst[9] == $oldst[9]) {
	&umount_filesystem_if_needed($server);
	print "OK: No change to $source\n";
	exit(0);
	}

# Re-upload the file
$err = &put_file_to_server($server, $dest, $source, 0, $forcessh);
&umount_filesystem_if_needed($server);
if ($err) {
	print "ERROR: Upload failed : $err\n";
	exit(1);
	}
if ($newfile) {
	print "OK Created $source\n";
	}
else {
	print "OK Saved $source\n";
	}

&cloudmin_api_log(\@OLDARGV);

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Edits a file on a single system.\n";
print "\n";
print "cloudmin edit-file --host name\n";
print "                   --file path\n";
print "                  [--force-ssh]\n";
exit(1);
}

