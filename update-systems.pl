#!/usr/local/bin/perl

=head1 update-systems.pl

Installs updated Virtualmin packages on multiple systems, and displays the results

This command installs all available package updates on specified systems. This
is only suppported on systems running Virtualmin, which has a module for
finding new versions of packages that relate to virtual hosting, such as
Apache, BIND, MySQL and of course the Virtualmin modules themselves. Updates
are done in parallel across all systems, and the packages installed on each
are displayed as they complete.

=head1 Example usage

  [root@fudu server-manager]# ./update-systems.pl --host xennoupdate.home
  Updating packages on 1 systems ..
  xennoupdate.home: spamassassin mod_perl

=cut

package server_manager;
$main::no_acl_check++;
$ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
$ENV{'WEBMIN_VAR'} ||= "/var/webmin";
if ($0 =~ /^(.*\/)[^\/]+$/) {
	chdir($1);
	}
chop($pwd = `pwd`);
$0 = "$pwd/update-systems.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";

# Parse command line
while(@ARGV > 0) {
	local $a = shift(@ARGV);
	if ($a eq "--host") {
		push(@names, shift(@ARGV));
		}
	elsif ($a eq "--all-hosts") {
		$all = 1;
		}
	else {
		&usage();
		}
	}

# Work out who to refresh
if (!$all) {
	foreach my $n (@names) {
		$server = &get_managed_server_by("host", $n);
		$server || &usage("No system with hostname $n exists");
		push(@servers, $server);
		}
	}
else {
	@servers = &list_managed_servers();
	}
@servers || &usage("No systems specified");

# Do the parallel update and print
print "Updating packages on ",scalar(@servers)," systems ..\n";
&parallel_server_function(\@servers,
	sub { my $info = &get_server_collected($_[0]);
	      my @allgot;
	      foreach $p (&sort_package_updates(@{$info->{'poss'}})) {
	          local $got = &install_package_update($_[0], $p);
		  push(@allgot, @$got) if (ref($got));
	          }
	      if (@allgot) {
                  &refresh_server_updates($_[0], \@allgot);
	          &check_server_status($_[0]);
	          &save_managed_server($_[0]);
	          print "$_[0]->{'host'}: ".join(" ", @allgot)."\n"
	          }
              else {
	          print "$_[0]->{'host'}: NONE\n"
                  }
	      });

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Installs updated Virtualmin packages on some or all managed systems.\n";
print "\n";
print "cloudmin update-systems [--all-hosts] | [--host name]*\n";
print "                        [--group name]*\n";
local $types = join("|", @server_management_types);
print "                        [--type $types]*\n";
print "                        [--os oscode]*\n";
exit(1);
}

