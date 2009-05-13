#!/usr/local/bin/perl

=head1 delete-licence.pl

Removes one Virtualmin licence from the pool

If you no longer want a license to be used when creating new Virtualmin
systems, this command can remove it from the Cloudmin license pool. It will not
effect any existing systems using the license though. The only parameter is
C<--serial>, which must be followed by a serial number.

=head1 Example usage

  ./delete-licence.pl --serial 55555
  The Virtualmin license with serial 55555 has been removed.

=cut

package server_manager;
$main::no_acl_check++;
$ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
$ENV{'WEBMIN_VAR'} ||= "/var/webmin";
if ($0 =~ /^(.*\/)[^\/]+$/) {
	chdir($1);
	}
chop($pwd = `pwd`);
$0 = "$pwd/delete-licence.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";

# Parse command line
while(@ARGV > 0) {
	local $a = shift(@ARGV);
	if ($a eq "--serial") {
		$serial = shift(@ARGV);
		}
	else {
		&usage();
		}
	}

# Validate inputs
$serial || &usage();
@lics = &list_virtualmin_licences();
($lic) = grep { $_->{'serial'} eq $serial } @lics;
$lic || &usage("No license with serial nunber $serial exists");

# Delete it
@lics = grep { $_ ne $lic } @lics;
&save_virtualmin_licences(\@lics);
print "The Virtualmin license with serial $serial has been removed.\n";

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Removes a registered Virtualmin license.\n";
print "\n";
print "cloudmin delete-licence --serial number\n";
exit(1);
}

