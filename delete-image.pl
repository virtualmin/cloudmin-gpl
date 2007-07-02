#!/usr/local/bin/perl
# Deletes a local image from the syste,

package server_manager;
$main::no_acl_check++;
$ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
$ENV{'WEBMIN_VAR'} ||= "/var/webmin";
if ($0 =~ /^(.*\/)[^\/]+$/) {
	chdir($1);
	}
chop($pwd = `pwd`);
$0 = "$pwd/delete-image.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";

# Parse command line
while(@ARGV > 0) {
	local $a = shift(@ARGV);
	if ($a eq "--id") {
		$id = shift(@ARGV);
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

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Deletes one downloaded system image.\n";
print "\n";
print "usage: delete-image.pl --id image-id\n";
exit(1);
}

