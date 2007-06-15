#!/usr/local/bin/perl
# Lists all available system images

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
	else {
		&usage();
		}
	}

@images = sort { $a->{'id'} cmp $b->{'id'} } &list_server_images($type);
if ($multi) {
	# One block per image
	foreach $i (@images) {
		$tfunc = "type_".$i->{'manager'}."_desc";
		print $i->{'id'},"\n";
		print "    Description: $i->{'desc'}\n";
		print "    System type: ",&$tfunc(),"\n";
		print "    Version: $i->{'version'}\n";
		print "    Compressed size: $i->{'size'}\n";
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
exit(1);
}

