#!/usr/local/bin/perl

=head1 list-system-locks.pl

Output a table of all running actions in Cloudmin.

=head1 Example usage

  cloudmin list-system-locks
  XXX

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
$0 = "$pwd/list-systems.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";

# Parse command line
while(@ARGV > 0) {
	my $a = shift(@ARGV);
	if ($a eq "--multiline") {
		$multi = 1;
		}
	else {
		&usage("Unknown parameter $a");
		}
	}
@locks = &list_running_actions();

if ($multi) {
	# Show a block for each lock
	foreach $l (@locks) {
		print $l->{'pid'},"\n";
		# XXX
		}
	}
else {
	# Show one lock per line
	$fmt = "%-30.30s %-20.20s %-10.10s %-20.20s\n";
	printf $fmt, "Hostname", "Script", "PID", "Age";
	printf $fmt, ("-" x 30), ("-" x 20), ("-" x 10), ("-" x 20);
	foreach $l (@locks) {
		$s = $l->{'server'};
		printf $fmt, $s->{'host'}, $l->{'short'}, $l->{'pid'}, $nice;
		}
	}

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Output a table of all running actions in Cloudmin.\n";
print "\n";
print "cloudmin list-system-locks [--multiline]\n";
exit(1);
}

sub prnt_size
{
return $bytes ? $_[0] : &nice_size($_[0]);
}

