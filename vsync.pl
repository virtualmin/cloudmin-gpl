#!/usr/local/bin/perl
# Run a replication and email the results

$no_acl_check++;
require './server-manager-lib.pl';

# Parse command line
while(@ARGV) {
	$a = shift(@ARGV);
	if ($a eq "--id") {
		$vsyncid = shift(@ARGV);
		}
	else {
		&usage();
		}
	}
$vsyncid || &usage();
$vsync = &get_virtualmin_sync($vsyncid);
$vsync || &usage("No replication config with ID $vsyncid found");
$src = &get_managed_server($vsync->{'src'});
@doms = split(/\s+/, $vsync->{'doms'});

# Execute it, capturing the output
$capture_print = undef;
&set_all_capture_text_print();
$ok = &sync_virtualmin_domains($vsync);

# Send email on failure
if (!$ok && $vsync->{'email'}) {
	&foreign_require("mailboxes");
	&mailboxes::send_text_mail(
		&get_global_from_address($src),
		$vsync->{'email'},
		undef,
		&text('vsync_fsubject', scalar(@doms), $src->{'host'}),
		$capture_print,
		);
	}

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Executes a single Virtualmin virtual server replication.\n";
print "\n";
print "vsync.pl --id number\n";
exit(1);
}

