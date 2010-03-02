#!/usr/local/bin/perl

=head1 transfer-command.pl

Run a command on one system with a file on another system as either input
or output.

This command captures the output of some command run on a system managed
by Cloudmin, and saves it to a file on another system. The source system is
specified with the C<--source> flag, and the target with C<--dest>.
The command to run is set with the C<--cmd> flag, and the destination file
with the C<--destfile> parameter followed by a new filename.

Alternately, it can run a command whose input is the contents of a file on
another system. In this case, use the C<--sourcefile> flag to specify the
input to the command, which will be taken from the C<--source> system and
run on the C<--dest> system.

=head1 Example usage

  cloudmin transfer-command --source xencentos.home --dest xensendmail.home --cmd 'tar cvzf - /etc' --dest /backup/etc.tar.gz
  Transferring output from tar cvzf - /etc on xencentos.home to /backup/etc.tar.gz on xensendmail.home ..
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
	elsif ($a eq "--cmd") {
		$cmd = shift(@ARGV);
		}
	elsif ($a eq "--destfile") {
		$dest = shift(@ARGV);
		}
	elsif ($a eq "--sourcefile") {
		$src = shift(@ARGV);
		}
	else {
		&usage();
		}
	}

# Validate args
$srchost || &usage("Missing --source flag");
$desthost || &usage("Missing --dest flag");
$cmd || &usage("Missing --cmd flag");
$dest || $src || &usage("Missing --destfile or --sourcefile flag");
$dest && $src && &usage("Only one of --destfile or --sourcefile is allowed");

# Get the servers
$srcserver = &get_managed_server_by("host", $srchost);
$destserver = &get_managed_server_by("host", $desthost);
$srcserver || &usage("No system named $srchost exists");
$destserver || &usage("No system named $desthost exists");
&can_action_usage([ $srcserver, $destserver ], "run");

# Do the transfer
if ($dest) {
	print "Transferring output from $cmd on $srcserver->{'host'} to ",
	      "$dest on $destserver->{'host'} ..\n";
	$err = &pipe_command_to_server($srcserver, $destserver, $cmd, $dest);
	}
else {
	print "Running $cmd on $destserver->{'host'} with input from $src on ",
	      "$srcserver->{'host'} ..\n";
	$err = &pipe_command_from_server($srcserver, $destserver, $cmd, $src);
	}
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
print "Run a command with a file on another system as either input or output\n";
print "\n";
print "cloudmin transfer-command --source hostname\n";
print "                          --dest hostname\n";
print "                          --cmd \"command\"\n";
print "                          --destfile path | --sourcefile path\n";
exit(1);
}

