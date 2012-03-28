#!/usr/local/bin/perl

=head1 delete-image.pl

Deletes an image from the master system

This command simply removes one of the existing images on your Cloudmin master.
The image ID is specified with the C<--id> parameter.

=head1 Example usage

  cloudmin delete-image --id xen-centos-test1
  Image xen-centos-test1 successfully deleted.

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
$0 = "$pwd/delete-image.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";
@OLDARGV = @ARGV;
&can_action_usage(undef, "global");
&usage_if_cloudmin_replica();

# Parse command line
while(@ARGV > 0) {
	my $a = shift(@ARGV);
	if ($a eq "--id") {
		$id = shift(@ARGV);
		}
	elsif ($a eq "--multiline") {
		$multiline = 1;
		}
	else {
		&usage();
		}
	}
$id || &usage();

# Get the image
($image) = grep { $_->{'id'} eq $id } &list_server_images();
$image || &usage("No image with ID $id was found");

# Delete it
&delete_server_image($image);
print "Image $id successfully deleted.\n";
&cloudmin_api_log(\@OLDARGV);

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Deletes one downloaded system image.\n";
print "\n";
print "cloudmin delete-image --id image-id\n";
exit(1);
}

