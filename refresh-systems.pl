#!/usr/local/bin/perl
# Updates the status of multiple systems, and displays the results

package virtual_server;
$main::no_acl_check++;
$ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
$ENV{'WEBMIN_VAR'} ||= "/var/webmin";
if ($0 =~ /^(.*\/)[^\/]+$/) {
	chdir($1);
	}
chop($pwd = `pwd`);
$0 = "$pwd/refresh-systems.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";

# Parse command line
while(@ARGV > 0) {
	local $a = shift(@ARGV);
	if ($a eq "--system") {
		push(@names, shift(@ARGV));
		}
	elsif ($a eq "--all-systems") {
		$all = 1;
		}
	elsif ($a eq "--regenerate") {
		$regen = 1;
		}
	else {
		&usage();
		}
	}

# Work out who to refresh
if (!$all) {
	foreach my $n (@names) {
		$server = &get_managed_server_by("host", $n);
		push(@servers, $server) if ($server);
		}
	}
else {
	@servers = &list_managed_servers();
	}
@servers || &usage("No systems specified");

# Do the parallel refresh and print
&parallel_server_function($servers,
	sub { &check_server_status($_[0], $regen);
	      &save_managed_server($_[0]);
	      $desc = $text{'status_'.$_[0]->{'status'}};
	      print "$_[0]->{'host'}: $_[0]->{'status'} ($desc)\n" });

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Refreshes the status of some or all managed systems.\n";
print "\n";
print "usage: refresh-systems.pl [--all-systems] | [--system name]*\n";
print "                          [--regenerate]*\n";
exit(1);
}

