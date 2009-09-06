#!/usr/local/bin/perl

=head1 list-ssh-keys.pl

Lists all registered SSH keys

This program displays a list of all SSH keys registered with Cloudmin, in a table
format. To show more details, use the C<--multiline> command-line argument, or
to show only key IDs use the C<--name-only> flag.

It is most useful when creating a system that will use SSH authentication to
login as root, such as an EC2 instance. In this case, the key ID must be
passed to C<create-system.pl> as a command-line argument.

=head1 Example usage

  cloudmin list-ssh-keys
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

@keys = &list_ssh_keys();
if ($multi) {
	# One block per key
	foreach $k (@keys) {
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
	foreach $k (@keys) {
		print $k->{'id'},"\n";
		}
	}
else {
	# One key per line
	$fmt = "%-10.10s %-7.7s %-58.58s\n";
	printf $fmt, "ID", "Type", "Description";
	printf $fmt, ("-" x 10), ("-" x 7), ("-" x 58);
	foreach $k (@keys) {
		printf $fmt, $k->{'id'}, $k->{'public'} ? "Public" : "Private",
			     $k->{'desc'};
		}
	}

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Lists all registered SSH keys.\n";
print "\n";
print "cloudmin list-ssh-keys [--multiline | --name-only]\n";
exit(1);
}

