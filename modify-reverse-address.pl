#!/usr/local/bin/perl

=head1 modify-reverse-address.pl

Changes the DNS hostname for a reverse address

This command can add, remove or change the reverse IP to hostname mapping
for a virtual system. The system is chosen with the C<--host> parameter,
and the IP with the C<--ip> flag. To add or change the hostname that this IP
maps to in DNS, use the C<--name> flag followed by a valid DNS name (without
the trailing dot). Or to remove the reverse mapping, use the C<--no-name>
flag.

=head1 Example usage

  cloudmin modify-reverse-address --host vvirtualmin.home --ip 1.2.3.4 --name www.foo.com
  Changed reverse DNS name for 1.2.3.4 to www.foo.com

=cut 

package server_manager;
$main::no_acl_check++;
$ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
$ENV{'WEBMIN_VAR'} ||= "/var/webmin";
if ($0 =~ /^(.*\/)[^\/]+$/) {
	chdir($1);
	}
chop($pwd = `pwd`);
$0 = "$pwd/modify-reverse-address.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";

# Parse command line
while(@ARGV > 0) {
	local $a = shift(@ARGV);
	if ($a eq "--host") {
		$host = shift(@ARGV);
		}
	elsif ($a eq "--ip") {
		$ip = shift(@ARGV);
		}
	elsif ($a eq "--name") {
		$name = shift(@ARGV);
		$name =~ /^[A-Za-z0-9\.\_\-]+$/ ||
		    &usage("--name must be followed by a valid DNS hostname");
		}
	elsif ($a eq "--no-name") {
		$name = '';
		}
	else {
		&usage();
		}
	}

# Get the server and validate args
$host || &usage("Missing --host parameter");
$server = &get_managed_server_by("host", $host);
$server || &usage("System with hostname $host does not exist");
$ip || &usage("Missing --ip parameter");
defined($name) || &usage("Missing --name or --no-name parameter");

# Get the address
@revs = &get_server_reverse_records($server);
($rev) = grep { $_->{'ip'} eq $ip } @revs;
$rev || &usage("No network interface with IP $ip was found on $host");
$rev->{'outside'} && &usage("The IP address $ip is not in a DNS zone managed ".
			    "by Cloudmin");

# Make the change and save
$rev->{'name'} = $name;
&save_server_reverse_records($server, \@revs);
if ($name) {
	print "Changed reverse DNS name for $ip to $name\n";
	}
else {
	print "Removed reverse DNS name for $ip\n";
	}

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Changes or removes the reverse DNS mapping for some system's IP.\n";
print "\n";
print "cloudmin modify-reverse-address --host hostname\n";
print "                                --ip address\n";
print "                                --name hostname | --no-name\n";
exit(1);
}

