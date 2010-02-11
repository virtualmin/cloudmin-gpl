#!/usr/local/bin/perl

=head1 delete-owner.pl

Delete an existing Cloudmin system owner

This command deletes a single owner account, identified with the C<--name>
parameter. No confirmation is requested, but none of the systems he owns
are effected.

=head1 Example usage

  cloudmin delete-owner --name freeman
  Deleted Cloudmin system owner freeman

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
$0 = "$pwd/create-owner.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";
@OLDARGV = @ARGV;
&usage_if_cloudmin_replica();
&can_action_usage(undef, "global");

# Parse command line
while(@ARGV > 0) {
	my $a = shift(@ARGV);
	if ($a eq "--name") {
		$name = shift(@ARGV);
		}
	else {
		&usage();
		}
	}

# Get the owner
$name || &usage("Missing --name parameter");
($owner) = grep { $_->{'name'} eq $name } &list_system_owners();
$owner || &usage("No system owner named $name exists");

# Delete him
&delete_system_owner($owner);
print "Deleted Cloudmin system owner $name\n";
&cloudmin_api_log(\@OLDARGV);

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Deletes an existing Cloudmin system owner.\n";
print "\n";
print "cloudmin delete-owner --name username\n";
exit(1);
}

