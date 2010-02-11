#!/usr/local/bin/perl

=head1 list-licences.pl

Lists all Virtualmin licences

This program displays a list of all licenses registered with Cloudmin, in a table
format. To show more details about each license, use the C<--multiline>
command-line argument. To just output serial numbers, use the C<--name-only>
flag.

=head1 Example usage

  cloudmin list-licences
  Serial     Key                  Domains    Systems    Used
  ---------- -------------------- ---------- ---------- ----------
  5555555    3rfafsfdsfsfds       Unlimited  Unlimited  6
  14433      HGHJJ7JJJ            250        1          0

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
$0 = "$pwd/list-licences.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";
&can_action_usage(undef, "global");

# Parse command line
while(@ARGV > 0) {
	my $a = shift(@ARGV);
	if ($a eq "--multiline") {
		$multi = 1;
		}
	elsif ($a eq "--name-only") {
		$nameonly = 1;
		}
	else {
		&usage();
		}
	}

@lics = &list_virtualmin_licences();
if ($multi) {
	# One block per licence
	foreach $l (@lics) {
		print $l->{'serial'},"\n";
		print "    Serial: $l->{'serial'}\n";
		print "    Key: $l->{'key'}\n";
		print "    Source: ",$l->{'vm2'} ? "Cloudmin" : "Virtualmin","\n";
		print "    Status: ",$l->{'invalid'} ? "Invalid" : "Valid","\n";
		print "    Max systems: ",$l->{'servers'} || "Unlimited","\n";
		print "    Max domains: ",$l->{'domains'} || "Unlimited","\n";
		print "    Used systems: ",scalar(@{$l->{'users'}}),"\n";
		if ($l->{'progress'}) {
			print "    Installing systems: ",$l->{'progress'},"\n";
			}
		print "    Remaining systems: ",
			$l->{'free'} < 0 ? "Unlimited" : $l->{'free'},"\n";
		if (@{$l->{'users'}}) {
			print "    System hostnames: ",
				join(" ", map { $_->{'host'} }
					      @{$l->{'users'}}),"\n";
			}
		}
	}
elsif ($nameonly) {
	# Just serial numbers
	foreach $l (@lics) {
		print $l->{'serial'},"\n";
		}
	}
else {
	# One line each
	$fmt = "%-10.10s %-20.20s %-10.10s %-10.10s %-10.10s\n";
	printf $fmt, "Serial", "Key", "Domains", "Systems", "Used";
	printf $fmt, ("-" x 10), ("-" x 20), ("-" x 10), ("-" x 10), ("-" x 10);
	foreach $l (@lics) {
		printf $fmt, $l->{'serial'}, $l->{'key'},
			     $l->{'domains'} || "Unlimited",
			     $l->{'servers'} || "Unlimited",
			     scalar(@{$l->{'users'}})+$l->{'progress'};
		}
	}

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Lists all registered Virtualmin licenses.\n";
print "\n";
print "cloudmin list-licences [--multiline | --name-only]\n";
exit(1);
}

