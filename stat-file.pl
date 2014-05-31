#!/usr/local/bin/perl

=head1 stat-file.pl

Displays information about a file on a managed system.

This command outputs all available information about a file on some remote
system, selected using the C<--host> flag. The file or directory to query
is specified with the C<--file> flag, followed by a filename. It can be used
to check if a file exists, its size or permissions.

=head1 Example usage

  cloudmin stat-file --host xencentos.home --file /etc/hosts
  Filename: /etc/hosts
  System: xencentos.home
  Device: 2065
  Inode: 2976446
  Permissions: rw-r--r--
  Octal permissions: 100644
  Hard links: 1
  GID: 999
  Size: 53
  Access time: 06/Sep/2010 19:19
  Modification time: 14/Jan/2010 11:51
  Change time: 14/Jan/2010 11:51
  Block size: 4096
  Block count: 8

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
$0 = "$pwd/stat-file.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";
@OLDARGV = @ARGV;

# Parse command line
while(@ARGV > 0) {
	my $a = shift(@ARGV);
	if ($a eq "--host") {
		$host = shift(@ARGV);
		}
	elsif ($a eq "--file") {
		$file = shift(@ARGV);
		}
	elsif ($a eq "--multiline") {
		$multiline = 1;
		}
	elsif ($a eq "--lookup-usernames") {
		$lookup = 1;
		}
	else {
		&usage("Unknown parameter $a");
		}
	}

# Get the server and check parameters
$host || &usage("Missing --host parameter");
$server = &find_one_managed_server($host);
$server || &usage("No system with hostname $host exists");
$file || &usage("Missing --file parameter");
&can_action_usage($server, "transfer");

# Mount if needed
$err = &mount_filesystem_if_needed($server);
if ($err) {
	print "ERROR: $err\n";
	exit(2);
	}

# Stat it
@st = &stat_file_on_server($server, $file, $lookup);
&umount_filesystem_if_needed($server);
if (@st == 1) {
	print "ERROR: $st[0]\n";
	exit(1);
	}
elsif (@st == 0) {
	print "ERROR: File not found\n";
	exit(2);
	}

# Show the deets
print "Filename: $file\n";
print "System: $server->{'host'}\n";
print "Device: $st[0]\n" if ($st[0]);
print "Inode: $st[1]\n" if ($st[1]);
print "Permissions: ",&make_unix_perms($st[2]),"\n" if ($st[2]);
print "Octal permissions: ",sprintf("%o", $st[2]),"\n" if ($st[2]);
print "Hard links: $st[3]\n" if ($st[3]);
if ($lookup) {
	print "User: $st[4]\n" if ($st[4] ne '');
	}
else {
	print "UID: $st[4]\n" if ($st[4] ne '');
	}
if ($lookup) {
	print "Group: $st[5]\n" if ($st[5] ne '');
	}
else {
	print "GID: $st[5]\n" if ($st[5] ne '');
	}
print "Size: $st[7]\n";
print "Access time: ",&make_date($st[8]),"\n" if ($st[8]);
print "Modification time: ",&make_date($st[9]),"\n" if ($st[9]);
print "Change time: ",&make_date($st[10]),"\n" if ($st[10]);
print "Block size: $st[11]\n" if ($st[11]);
print "Block count: $st[12]\n" if ($st[12]);
print "Link target: $st[14]\n" if ($st[14]);

&cloudmin_api_log(\@OLDARGV);

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Displays information about a file on a managed system.\n";
print "\n";
print "cloudmin stat-file --host name\n";
print "                   --file filename\n";
exit(1);
}


