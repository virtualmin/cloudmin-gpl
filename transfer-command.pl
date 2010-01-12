#!/usr/local/bin/perl

=head1 transfer-command.pl

Transfer the output of some command to another system.

This command captures the output of some command run on a system managed
by Cloudmin, and saves it to a file on another system. The source system is
specified with the C<--source> flag, and the target with C<--dest>.
The command to run is set with the C<--cmd> flag, and the destination file
with the C<--destfile> parameter followed by a new filename.

=head1 Example usage

  cloudmin transfer-command --source xencentos.home --dest xensendmail.home --cmd 'tar cvzf - /etc' --dest /backup/etc.tar.gz
  XXX

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
	elsif ($a eq "--cmd") {
		$cmd = shift(@ARGV);
		}
	elsif ($a eq "--destfile") {
		$dest = shift(@ARGV);
		}
	else {
		&usage();
		}
	}

# Validate args
$srchost || &usage("Missing --source flag");
$desthost || &usage("Missing --dest flag");
$cmd || &usage("Missing --cmd flag");
$dest || &usage("Missing --destfile flag");

# Get the servers
$srcserver = &get_managed_server_by("host", $srchost);
$destserver = &get_managed_server_by("host", $desthost);
$srcserver || &usage("No system named $srchost exists");
$destserver || &usage("No system named $desthost exists");

# Do the transfer
print "Transferring output from $cmd on $srcserver->{'host'} to $dest on $destserver->{'host'} ..\n";
$err = &pipe_command_to_server($srcserver, $destserver, $cmd, $dest);
if ($err) {
	print ".. copy failed : $err\n";
	}
else {
	print ".. done\n";
	&cloudmin_api_log(\@OLDARGV);
	}

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Transfer the output of some command to another system.\n";
print "\n";
print "cloudmin transfer-command --source hostname\n";
print "                          --dest hostname\n";
print "                          --cmd \"command\"\n";
print "                          --destfile path\n";
exit(1);
}

