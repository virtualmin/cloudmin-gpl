#!/usr/local/bin/perl

=head1 list-system-keys.pl

Lists SSH keys accepted by root for some system.

This command outputs a list of authorized SSH keys on some managed system,
selected using the C<--host> command-line parameter. By default they are shown
in a table, but you can select a more machine-readable format with the
optional C<--multiline> parameter. Or to get just the key IDs, use the 
C<--id-only> flag.

=head1 Example usage

  cloudmin list-system-keys --host virtualmin.home
  ID         Type    Description
  ---------- ------- ---------------------------------------------------------
  1176512615 Private Test SSH key

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
$0 = "$pwd/list-system-keys.pl";
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
	elsif ($a eq "--id-only") {
		$nameonly = 1;
		}
	else {
		&usage("Unknown parameter $a");
		}
	}

# Get the server
$host || &usage("Missing --host parameter");
$server = &find_one_managed_server($host);
$server || &usage("System with hostname $host does not exist");
&can_action_usage($server, "pass"); 

# Get the keys
$keys = &list_authorized_keys($server);
ref($keys) || &usage("Failed to fetch SSH keys : $keys");

if ($multi) {
	# One block per key
	foreach $k (@$keys) {
		print $k->{'id'},"\n";
		print "    Description: $k->{'desc'}\n";
		print "    Key file: $k->{'file'}\n";
		if ($k->{'public'}) {
			print "    Type: public\n";
			}
		else {
			print "    Type: private\n";
			}
		print "    Public key: ",&generate_public_key($k),"\n";
		foreach $t (@server_management_types) {
			$kfunc = "type_${t}_ssh_key_info";
			if (defined(&$kfunc)) {
				foreach my $i (&$kfunc($k)) {
					print "    $i->[0]: $i->[1]\n";
					}
				}
			}
		}
	}
elsif ($nameonly) {
	# Just key IDs
	foreach $k (@$keys) {
		print $k->{'id'},"\n";
		}
	}
else {
	# One key per line
	$fmt = "%-10.10s %-7.7s %-58.58s\n";
	printf $fmt, "ID", "Type", "Description";
	printf $fmt, ("-" x 10), ("-" x 7), ("-" x 58);
	foreach $k (@$keys) {
		printf $fmt, $k->{'id'}, $k->{'public'} ? "Public" : "Private",
			     $k->{'desc'};
		}
	}

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Lists all network interfaces on some virtual system.\n";
print "\n";
print "cloudmin list-system-keys --host hostname\n";
print "                         [--multiline | --id-only]\n";
exit(1);
}

