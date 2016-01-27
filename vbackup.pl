#!/usr/local/bin/perl
# Run a Virtualmin backup and email the results

package server_manager;
$main::no_acl_check++;
require './server-manager-lib.pl';
&exit_if_cloudmin_replica();

# Parse command line
while(@ARGV) {
	$a = shift(@ARGV);
	if ($a eq "--id") {
		$vbackupid = shift(@ARGV);
		}
	else {
		&usage("Unknown parameter $a");
		}
	}
$vbackupid || &usage("No backup ID specified");
$vbackup = &get_virtualmin_backup($vbackupid);
$vbackup || &usage("No backup config with ID $vbackupid found");
@srcs = &get_virtualmin_backup_srcs($vbackup);
@doms = split(/\s+/, $vbackup->{'doms'});

# Execute it, capturing the output
$capture_print = undef;
&set_all_capture_text_print();
$ok = &backup_virtualmin_domains($vbackup);

# Send email on failure
@emails = ( );
push(@emails, $vbackup->{'email'}) if ($vbackup->{'email'});
push(@emails, $config{'bw_email'}) if ($vbackup->{'emailmaster'} &&
				       $config{'bw_email'});
if (!$ok && @emails) {
	&foreign_require("mailboxes");
	$srcnames = join(" ", map { $_->{'host'} } @srcs);
	foreach $email (@emails) {
		&mailboxes::send_text_mail(
			&get_global_from_address($src),
			@emails,
			undef,
			&text(@doms ? 'vbackup_fsubject' : 'vbackup_fsubject2',
			      scalar(@doms), $srcnames),
			$capture_print,
			);
		}
	}

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Executes a single Virtualmin virtual server backup.\n";
print "\n";
print "vbackup.pl --id number\n";
exit(1);
}

