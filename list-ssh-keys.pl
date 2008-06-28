#!/usr/local/bin/perl

=head1 list-ssh-keys.pl

Lists all registered SSH keys

This program displays a list of all SSH keys registered with VM2, in a table
format. To show more details, use the C<--multiline> command-line argument.
It is most useful when creating a system that will use SSH authentication to
login as root, such as an EC2 instance. In this case, the key ID must be
passed to C<create-system.pl> as a command-line argument.

=head1 Example usage

  ./list-ssh-keys.pl
  ID         Description
  ---------- -----------------------------------------------------------------
  1176512463 Jamie's SSH 1 key. uploaded copy
  1176512615 Jamie's SSH 2  key, in home directory
  1176513526 Amazon EC2 SSH key
  1176848976 EC2 generated key

=cut 

package server_manager;
$main::no_acl_check++;
$ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
$ENV{'WEBMIN_VAR'} ||= "/var/webmin";
if ($0 =~ /^(.*\/)[^\/]+$/) {
	chdir($1);
	}
chop($pwd = `pwd`);
$0 = "$pwd/list-ssh-keys.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";

# Parse command line
while(@ARGV > 0) {
	local $a = shift(@ARGV);
	if ($a eq "--multiline") {
		$multi = 1;
		}
	else {
		&usage();
		}
	}

@keys = &list_ssh_keys();
if ($multi) {
	# One block per key
	foreach $k (@keys) {
		print $k->{'id'},"\n";
		print "    Description: $k->{'desc'}\n";
		print "    Key file: $k->{'file'}\n";
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
else {
	# One key per line
	$fmt = "%-10.10s %-65.65s\n";
	printf $fmt, "ID", "Description";
	printf $fmt, ("-" x 10), ("-" x 65);
	foreach $k (@keys) {
		printf $fmt, $k->{'id'}, $k->{'desc'};
		}
	}

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Lists all registered SSH keys.\n";
print "\n";
print "usage: list-ssh-keys.pl [--multiline]\n";
exit(1);
}

