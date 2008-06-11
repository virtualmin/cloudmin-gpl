#!/usr/local/bin/perl
# Lists all downloaded system images

package server_manager;
$main::no_acl_check++;
$ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
$ENV{'WEBMIN_VAR'} ||= "/var/webmin";
if ($0 =~ /^(.*\/)[^\/]+$/) {
	chdir($1);
	}
chop($pwd = `pwd`);
$0 = "$pwd/list-images.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";

# Parse command line
while(@ARGV > 0) {
	local $a = shift(@ARGV);
	if ($a eq "--multiline") {
		$multi = 1;
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
print "usage: list-images.pl [--multiline]\n";
print "                      [--type typename]\n";
print "                      [--md5-verify]\n";
exit(1);
}

