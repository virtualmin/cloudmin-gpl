#!/usr/local/bin/perl

=head1 transfer-file.pl

Transfer a file between two systems

This command copies a file between two systems managed by VM2, using a direct
copy with C<scp> where possible. The source system is specified with the 
C<--source> flag, and the target with C<--dest>. The file or directory to
copy is set with C<--file>. By default it will be copied to the same path
on the target, unless the C<--destfile> parameter followed by a new filename
is given.

=head1 Example usage

  ./transfer-file.pl --source xencentos.home --dest xensendmail.home --file /etc/hosts --destfile /tmp/hosts

=cut

package server_manager;
$main::no_acl_check++;
$ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
$ENV{'WEBMIN_VAR'} ||= "/var/webmin";
if ($0 =~ /^(.*\/)[^\/]+$/) {
	chdir($1);
	}
chop($pwd = `pwd`);
$0 = "$pwd/transfer-file.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";

# Parse command line
while(@ARGV > 0) {
	local $a = shift(@ARGV);
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
	else {
		&usage();
		}
	}

# Validate args
$srchost || &usage("Missing --source flag");
$desthost || &usage("Missing --dest flag");
$file || &usage("Missing --file flag");
$dest ||= $src;

# XXX get the servers

# XXX do the transfer

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Copies a file from one managed system to another.\n";
print "\n";
print "usage: transfer-file.pl --source hostname\n";
print "                        --dest hostname\n";
print "                        --file path\n";
rint "                         [--destfile path]\n";
exit(1);
}

