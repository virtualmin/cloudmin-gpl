#!/usr/local/bin/perl
# Installs Virtualmin on multiple systems

package server_manager;
$main::no_acl_check++;
$ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
$ENV{'WEBMIN_VAR'} ||= "/var/webmin";
if ($0 =~ /^(.*\/)[^\/]+$/) {
	chdir($1);
	}
chop($pwd = `pwd`);
$0 = "$pwd/install-virtualmin.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";

# Parse command line
while(@ARGV > 0) {
	local $a = shift(@ARGV);
	if ($a eq "--host") { push(@hosts, shift(@ARGV)); }
	elsif ($a eq "--group") { push(@groups, shift(@ARGV)); }
	elsif ($a eq "--os") { push(@types, shift(@ARGV)); }
	elsif ($a eq "--type") { push(@managers, shift(@ARGV)); }
	else {
		&usage();
		}
	}

# Work out who to install on
@servers = &find_managed_servers(0, \@hosts, \@groups, \@managers, \@types);
@servers || &usage("No systems specified");

# Make sure servers are valid
foreach $s (@servers) {
	if ($s->{'status'} ne 'nowebmin' &&
	    $s->{'status'} ne 'novirt') {
		push(@cannot, $s);
		}
	}
@cannot && &usage("The following systems cannot have Virtualmin installed : ".
		  join(" ", map { $_->{'host'} } @cannot));

# Do the parallel refresh
print "Installing Virtualmin on ",scalar(@servers)," systems ..\n";
&parallel_server_function(\@servers,
	sub { # Start install
	      $err = &install_virtualmin_server($_[0]);
	      if ($err) {
	          print "$_[0]->{'host'}: ERROR: $err\n";
                  return 1;
	      }
	      print "$_[0]->{'host'}: Started\n";
	      while(1) {
		  $done = &install_virtualmin_server_done($_[0]);
		  if ($done eq "OK") {
		      last;
		      }
		  elsif ($done) {
		      print "$_[0]->{'host'}: ERROR: $done\n";
                      return 1;
		  }
	       }
	       &check_server_status($_[0]);
	       &save_managed_server($_[0]);
	       print "$_[0]->{'host'}: OK\n";
	    });

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Installs Virtualmin on one or more managed systems.\n";
print "\n";
print "usage: install-webmin.pl [--host name]*\n";
print "                         [--group name]*\n";
local $types = join("|", @server_management_types);
print "                         [--type $types]*\n";
print "                         [--os oscode]*\n";
exit(1);
}

