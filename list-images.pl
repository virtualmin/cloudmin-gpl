#!/usr/local/bin/perl

=head1 list-images.pl

Lists all downloaded system images

This command lists all images that are available for creating systems on the
Cloudmin master. By default it will show all of them in a table, but you can use
the C<--multiline> parameter to display more details in a machine-readable
format, or C<--name-only> to just show image IDs. To limit the list to images
for some virtualization type, use the C<--type> flag followed by a type code
like C<xen> or C<vservers>.

=head1 Example usage

  cloudmin list-images.pl --type xen
  ID                             Description
  ------------------------------ ------------------------------------------------
  xen-centos4.4-base             CentOS 4.4 Xen instance with base OS
  xen-centos4.4-virtualmin       CentOS 4.4 Xen instance with Virtualmin Pro
  xen-centos5.0-base             CentOS 5 Xen instance with base OS
  xen-centos5.0-virtualmin       CentOS 5 Xen instance with Virtualmin Pro
  xen-debian3.1-base             Debian 3.1 Xen instance with base OS
  xen-fc6-base                   Fedora Core 6 Xen instance with base OS
  xen-fc6-virtualmin             Fedora Core 6 Xen instance with Virtualmin Pro
  xen-ubuntu6.10-base            Ubuntu 6.10 Xen instance with base OS
  xen-ubuntu6.10-virtualmin      Ubuntu 6.10 Xen instance with Virtualmin Pro

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
$0 = "$pwd/list-images.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";

# Parse command line
while(@ARGV > 0) {
	my $a = shift(@ARGV);
	if ($a eq "--multiline") {
		$multi = 1;
		}
	elsif ($a eq "--name-only") {
		$nameonly = 1;
		}
	elsif ($a eq "--type") {
		$type = shift(@ARGV);
		}
	elsif ($a eq "--md5-verify") {
		$md5verify = 1;
		}
	else {
		&usage();
		}
	}

@images = sort { $b->{'priority'} <=> $a->{'priority'} ||
		 $a->{'id'} cmp $b->{'id'} } &list_server_images($type);
@avail = &list_available_server_images($type);
if ($multi) {
	# One block per image
	foreach $i (@images) {
		$tfunc = "type_".$i->{'manager'}."_desc";
		($avail) = grep { $_->{'id'} eq $i->{'id'} } @avail;
		print $i->{'id'},"\n";
		print "    Description: $i->{'desc'}\n";
		print "    System type: ",&$tfunc(),"\n";
		print "    Version: $i->{'version'}\n";
		if ($avail) {
			print "    Available version: $avail->{'version'}\n";
			print "    Source: Virtualmin\n";
			}
		else {
			print "    Source: Local\n";
			}
		print "    Compressed size: $i->{'size'}\n";
		if ($i->{'rawsize'}) {
			print "    Contents size: $i->{'rawsize'}\n";
			}
		if ($i->{'dest'}) {
			print "    Location: $i->{'dest'}\n";
			}
		@md5s = split(/\s+/, $i->{'md5'});
		if (@md5s && $md5s[0] ne "-" && $md5verify) {
			print "    MD5 expected checksum: ",
				join(" ", @md5s),"\n";
			@realmd5s = &get_image_md5s($i);
			print "    MD5 actual checksum: ",
				join(" ", @realmd5s),"\n";
			print "    MD5 status: ",
				&compare_md5_lists(\@md5s, \@realmd5s) ? "OK" : "Bad","\n";
			}
		}
	}
elsif ($nameonly) {
	# Just image IDs
	foreach $i (@images) {
		print $i->{'id'},"\n";
		}
	}
else {
	# One image per line
	$fmt = "%-30.30s %-48.48s\n";
	printf $fmt, "ID", "Description";
	printf $fmt, ("-" x 30), ("-" x 48);
	foreach $i (@images) {
		printf $fmt, $i->{'id'}, $i->{'desc'};
		}
	}

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Lists all downloaded system images.\n";
print "\n";
print "cloudmin list-images [--multiline | --name-only]\n";
print "                     [--type typename]\n";
print "                     [--md5-verify]\n";
exit(1);
}

