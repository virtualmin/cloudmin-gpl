#!/usr/local/bin/perl

=head1 refresh-system.pl

Updates the status of multiple systems, and displays the results

Forces Cloudmin to re-query the actual status of the specified systems. This is
done in parallel so that many can be updated at once, and the status from
each is displayed once it is retrieved. By default, Virtualmin status
information like the amount of free RAM and available package updates is only
fetched from the remote system's cache, which is typically updated once
every 5 minutes. To force a full status update, use the C<--regenerate>
command-line option - this will make the update take longer though.

=head1 Example usage

  cloudmin refresh-systems --host xenrails.home
  Refreshing status of 1 systems ..
  xenrails.home: virt (Webmin and Virtualmin)

=cut

package server_manager;
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
	if ($a eq "--regenerate") {
		$regen = 1;
		}
	elsif ($a eq "--serial") {
		$serial = 1;
		}
	elsif ($a eq "--all-hosts") { $all = 1; }
	elsif ($a eq "--host") { push(@hosts, shift(@ARGV)); }
	elsif ($a eq "--group") { push(@groups, shift(@ARGV)); }
	elsif ($a eq "--os") { push(@types, shift(@ARGV)); }
	elsif ($a eq "--type") { push(@managers, shift(@ARGV)); }
	else {
		&usage();
		}
	}

# Work out who to refresh
@servers = &find_managed_servers($all, \@hosts, \@groups, \@managers, \@types);
@servers || &usage("No systems specified");

# Identify parent and virtual systems
@pservers = grep { !&is_virtual_server($_) } @servers;
@oservers = grep { &is_virtual_server($_) } @servers;

# Do the parallel refresh and print
print "Refreshing status of ",scalar(@servers)," systems ..\n";
if ($serial) {
	# In one process
	foreach $s (@pservers, @oservers) {
		&check_server_status($s, $regen, 0, $time);
		&save_managed_server($s);
	        if (defined(&refresh_server_usage)) {
			&refresh_server_usage($s, $time);
			}
		$desc = $text{'status_'.$s->{'status'}};
		print "$s->{'host'}: $s->{'status'} ($desc)\n";
		}
	}
else {
	# In separate processes
	$time = time();
	foreach $l (\@pservers, \@oservers) {
		@rv = &parallel_server_function($l,
			sub { &check_server_status($_[0], $regen, 0, $time);
			      &save_managed_server($_[0]);
			      if (defined(&refresh_server_usage)) {
				&refresh_server_usage($_[0], $time);
			      }
			      return $_[0]->{'status'}; });
		for($i=0; $i<@rv; $i++) {
			$desc = $text{'status_'.$rv[$i]->[0]};
			print "$l->[$i]->{'host'}: $rv[$i]->[0] ($desc)\n";
			}
		}
	}

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Refreshes the status of some or all managed systems.\n";
print "\n";
print "cloudmin refresh-systems [--all-hosts] | [--host name]*\n";
print "                         [--group name]*\n";
local $types = join("|", @server_management_types);
print "                         [--type $types]*\n";
print "                         [--os oscode]*\n";
print "                         [--regenerate]*\n";
print "                         [--serial]\n";
exit(1);
}

