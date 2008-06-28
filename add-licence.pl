#!/usr/local/bin/perl

=head1 add-licence.pl

Adds one Virtualmin licence to the pool

This command adds a new license to the pool of those managed by VM2. It must
have been already purchased from the Virtualmin website, and you must have the
serial number and key. These are specified to the command using the
C<--serial> and C<--key> parameters respectively, and will be validated before
it is added to the license pool.

=head1 Example usage

  ./add-licence.pl --serial 213323 --key fdsdsfdffdsff
  The Virtualmin license with serial 213323 and key fdsdsfdffdsff has been added.

=cut 

package server_manager;
$main::no_acl_check++;
$ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
$ENV{'WEBMIN_VAR'} ||= "/var/webmin";
if ($0 =~ /^(.*\/)[^\/]+$/) {
	chdir($1);
	}
chop($pwd = `pwd`);
$0 = "$pwd/add-licence.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";

# Parse command line
while(@ARGV > 0) {
	local $a = shift(@ARGV);
	if ($a eq "--serial") {
		$serial = shift(@ARGV);
		}
	elsif ($a eq "--key") {
		$key = shift(@ARGV);
		}
	else {
		&usage();
		}
	}

# Validate inputs
$serial && $key || &usage();
@lics = &list_virtualmin_licences();
($clash) = grep { $_->{'serial'} eq $serial } @lics;
$clash && &usage("A license with serial number $serial is already registered");
$ok = &check_virtualmin_serial($serial, $key);
$ok == 1 || &usage("The specified serial number and key are not valid");

# Add it
push(@lics, { 'serial' => $serial, 'key' => $key });
&save_virtualmin_licences(\@lics);
print "The Virtualmin license with serial $serial and key $key has been added.\n";

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Adds a valid existing Virtualmin license.\n";
print "\n";
print "usage: add-licence.pl --serial number\n";
print "                      --key string\n";
exit(1);
}

