#!/usr/local/bin/perl

=head1 list-updates.pl

Lists all available updates on one or more systems

This command outputs a table of all known package updates that are available
on the selected systems. You can select systems to query with the C<--host>
flag followed by a hostname, C<--owner> flag followed by a system owner name,
C<--group> and a group name, or C<--all-hosts> to find updates from any of them.

To switch the output to a more parsable format, use the C<--multiline> flag.
To get just a list of package names, use the C<--name-only> flag.

=head1 Example usage

  cloudmin list-updates --host xencentos.home
  Package                        Old version             New version
  ------------------------------ ----------------------- --------------------
  kernel                         2.6.18-8.1.1.el5        2.6.18-8.1.15.el5
  kernel-headers                 2.6.18-8.1.1.el5        2.6.18-8.1.15.el5
  virtualmin-base                1.0-45.rh               1.0-61.rh

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
$0 = "$pwd/list-updates.pl";
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
	elsif ($a eq "--all-hosts") { $all = 1; }
	elsif ($a eq "--host") { push(@hosts, shift(@ARGV)); }
	elsif ($a eq "--group") { push(@groups, shift(@ARGV)); }
	elsif ($a eq "--os") { push(@types, shift(@ARGV)); }
	elsif ($a eq "--type") { push(@managers, shift(@ARGV)); }
	elsif ($a eq "--owner") { push(@owners, shift(@ARGV)); }
        elsif ($a eq "--host-on") { push(@hostons, shift(@ARGV)); }
        elsif ($a eq "--status") { push(@statuses, shift(@ARGV)); }
	else {
		&usage("Unknown parameter $a");
		}
	}

# Work out who to list
@servers = &find_managed_servers($all, \@hosts, \@groups, \@managers, \@types, \@owners, \@statuses, \@hostons);
@servers || &usage("No systems specified");
&can_action_usage(\@servers);

if ($multi) {
	# Show one update per block
	foreach $s (@servers) {
		$info = &get_server_collected($s);
		@poss = @{$info->{'poss'}};
		foreach $p (@poss) {
			print $p->{'name'},"\n";
			print "    Package type: ",$p->{'system'},"\n";
			print "    System: ",$s->{'host'},"\n";
			print "    Old version: ",$p->{'oldversion'},"\n";
			if ($p->{'oldepoch'}) {
				print "    Old epoch: ",$p->{'oldepoch'},"\n";
				}
			print "    New version: ",$p->{'version'},"\n";
			if ($p->{'epoch'}) {
				print "    New epoch: ",$p->{'epoch'},"\n";
				}
			if ($p->{'desc'}) {
				print "    Description: ",$p->{'desc'},"\n";
				}
			}
		}
	}
elsif ($nameonly) {
	# Show just update names
	foreach $s (@servers) {
		$info = &get_server_collected($s);
		@poss = @{$info->{'poss'}};
		foreach $p (@poss) {
			print $p->{'name'},"\n";
			}
		}
	}
else {
	# Show one update per line
	if (@servers > 1) {
		$fmt = "%-25.25s %-20.20s %-15.15s %-15.15s\n";
		}
	else {
		$fmt = "%-30.30s %-23.23s %-23.23s\n";
		}
	printf $fmt, @servers > 1 ? ( "Host" ) : ( ),
		     "Package", "Old version", "New version";
	if (@servers > 1) {
		printf $fmt, ("-" x 25), ("-" x 20), ("-" x 15), ("-" x 15);
		}
	else {
		printf $fmt, ("-" x 30), ("-" x 23), ("-" x 23);
		}
	foreach $s (@servers) {
		$info = &get_server_collected($s);
		@poss = @{$info->{'poss'}};
		foreach $p (@poss) {
			printf $fmt, @servers > 1 ? ( $s->{'host'} ) : ( ),
				     $p->{'name'},
				     $p->{'oldversion'},
				     $p->{'version'};
			}
		}
	}

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Lists all available updates on one or more systems.\n";
print "\n";
print "cloudmin list-systems [--multiline | --name-only]\n";
print "                      [--all-hosts] | [--host name]*\n";
print "                      [--group name]*\n";
my $types = join("|", @server_management_types);
print "                      [--type $types]*\n";
print "                      [--os oscode]*\n";
print "                      [--owner name]*\n";
print "                      [--status status-code|\"up\"|\"wm\"|\"bad\"]\n";
print "                      [--host-on name]\n";
exit(1);
}

