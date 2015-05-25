#!/usr/local/bin/perl

=head1 list-system-locks.pl

Output a table of all running actions in Cloudmin.

This can be used to find any long-running, backgrounded or abandoned actions
that may be holding locks on virtual systems. These can be killed with the 
C<kill> command run on the Cloudmin master.

This command only takes a single optional parameter - C<--multiline>, to
request output in a more detailed parsable format.

=head1 Example usage

  cloudmin list-system-locks
  Hostname                       Script               PID        Age       
  ------------------------------ -------------------- ---------- ----------
  kvmfreebsd8.home               status.pl            1867       02 mins
  kvmfreebsd8template.home       status.pl            1863       03 mins

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
		$s = $l->{'server'};
		$nice = &nice_hour_mins_secs(time() - $l->{'time'});
		print $l->{'pid'},"\n";
		print "    Hostname: $s->{'host'}\n";
		print "    System ID: $s->{'id'}\n";
		print "    Lock time: ",&make_date($l->{'time'}),"\n";
		print "    Lock age: ",$nice,"\n";
		print "    Locked by command: ",$l->{'cmd'},"\n";
		if ($l->{'short'}) {
			print "    Locked by script: ",$l->{'short'},"\n";
			}
		print "    Safe to kill: ",($l->{'safe'} == 2 ? "Yes" :
					    $l->{'safe'} == 1 ? "Maybe" : "No"),
					   "\n";
		}
	}
else {
	# Show one lock per line
	$fmt = "%-30.30s %-20.20s %-10.10s %-16.16s\n";
	printf $fmt, "Hostname", "Script", "PID", "Age";
	printf $fmt, ("-" x 30), ("-" x 20), ("-" x 10), ("-" x 16);
	foreach $l (@locks) {
		$s = $l->{'server'};
		$nice = &nice_hour_mins_secs(time() - $l->{'time'});
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

