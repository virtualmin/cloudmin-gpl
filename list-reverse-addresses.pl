#!/usr/local/bin/perl

=head1 list-reverse-addresses.pl

Lists IP to name DNS mappings for some system

This command outputs a list of IP to hostname mappings in DNS for some
managed system, selected using the C<--host> command-line parameter. By
default they are shown in a table, but you can select a more parsable format
with the optional C<--multiline> parameter.

=head1 Example usage

  cloudmin list-reverse-addresses --host vvirtualmin.home
  IP Address      DNS domain                     Hostname
  --------------- ------------------------------ ------------------------------
  193.9.101.238   101.9.193.in-addr.arpa         openvztest.home
  193.9.101.41    101.9.193.in-addr.arpa         NONE

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
$0 = "$pwd/list-reverse-addresses.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";

# Parse command line
while(@ARGV > 0) {
	my $a = shift(@ARGV);
	if ($a eq "--host") {
		$host = shift(@ARGV);
		}
	elsif ($a eq "--multiline") {
		$multi = 1;
		}
	else {
		&usage("Unknown parameter $a");
		}
	}

# Get the server
$host || &usage("Missing --host parameter");
$server = &get_managed_server_by("host", $host);
$server || &usage("System with hostname $host does not exist");
&can_action_usage($server, "reverse");

# Get the addresses
@revs = &get_server_reverse_records($server);

if ($multi) {
	# Show one per block
	foreach $rev (@revs) {
		print "$rev->{'ip'}\n";
		print "    DNS domain: ",
			($rev->{'outside'} ? "NONE" : $rev->{'zone'}),"\n";
		print "    Hostname: ",
			($rev->{'name'} || "NONE"),"\n";
		}
	}
else {
	# Show one per line
	$fmt = "%-15.15s %-30.30s %-30.30s\n";
	printf $fmt, "IP Address", "DNS domain", "Hostname";
	printf $fmt, ("-" x 15), ("-" x 30), ("-" x 30);
	foreach $rev (@revs) {
		printf $fmt, $rev->{'ip'},
			     $rev->{'outside'} ? "NONE" : $rev->{'zone'},
			     $rev->{'name'} || "NONE";
		}
	}

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Lists all reverse IP to hostname DNS mappings on some virtual system.\n";
print "\n";
print "cloudmin list-reverse-addresses --host hostname\n";
print "                               [--multiline]\n";
exit(1);
}

