#!/usr/local/bin/perl

=head1 transfer-file.pl

Transfer a file between two systems

This command copies a file between two systems managed by Cloudmin, using a
direct copy with C<scp> where possible. The source system is specified with the 
C<--source> flag, and the target with C<--dest>. The file or directory to
copy is set with C<--file>. By default it will be copied to the same path
on the target, unless the C<--destfile> parameter followed by a new filename
is given.

To double-check that the file was transferred correctly, use the 
C<--checksum> flag. This will trigger an md5 checksum on the source and
destination files.

If the file being copied is actually a device (such as a partition or LVM
logical volume), use the C<--device> flag to have Cloudmin transfer it in the
correct way.

By default Cloudmin will transfer the file directly from the source system
to the destination. However, you can force the transfer to go via the master
system instead with the C<--via-master> flag.

=head1 Example usage

  cloudmin transfer-file --source xencentos.home --dest xensendmail.home --file /etc/hosts --destfile /tmp/hosts
  Copying /etc/hosts on xencentos.home to /tmp/hosts on xensendmail.home ..
  .. done

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
$0 = "$pwd/transfer-file.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";
@OLDARGV = @ARGV;

# Parse command line
while(@ARGV > 0) {
	my $a = shift(@ARGV);
	if ($a eq "--source") {
		$srchost = shift(@ARGV);
		}
	elsif ($a eq "--dest") {
		$desthost = shift(@ARGV);
		}
	elsif ($a eq "--file") {
		$src = shift(@ARGV);
		}
	elsif ($a eq "--destfile") {
		$dest = shift(@ARGV);
		}
	elsif ($a eq "--device-file") {
		$device = 1;
		}
	elsif ($a eq "--checksum") {
		$checksum = 1;
		}
	elsif ($a eq "--checksum-size") {
		$checksumsize = shift(@ARGV);
		}
	elsif ($a eq "--via-master") {
		$viamaster = 1;
		}
	elsif ($a eq "--multiline") {
		$multiline = 1;
		}
	else {
		&usage("Unknown parameter $a");
		}
	}

# Validate args
$srchost || &usage("Missing --source flag");
$desthost || &usage("Missing --dest flag");
$src || &usage("Missing --file flag");
$dest ||= $src;

# Get the servers
$srcserver = &get_managed_server_by("host", $srchost);
$destserver = &get_managed_server_by("host", $desthost);
$srcserver || &usage("No system named $srchost exists");
$destserver || &usage("No system named $desthost exists");
&can_action_usage([ $srcserver, $destserver ], "transfer");

# Do the transfer
print "Copying $src on $srcserver->{'host'} to $dest on $destserver->{'host'} ..\n";
$err = &transfer_file_between_servers($srcserver, $destserver, $src, $dest,
				      $device, $checksum, $checksumsize,
				      $viamaster);
if ($err) {
	print ".. copy failed : $err\n";
	exit(1);
	}
else {
	print ".. done\n";
	&cloudmin_api_log(\@OLDARGV);
	}

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Copies a file from one managed system to another.\n";
print "\n";
print "cloudmin transfer-file --source hostname\n";
print "                       --dest hostname\n";
print "                       --file path\n";
print "                      [--destfile path]\n";
print "                      [--device-file]\n";
print "                      [--checksum [--checksum-size bytes]]\n";
print "                      [--via-master]\n";
exit(1);
}

