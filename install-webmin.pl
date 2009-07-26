#!/usr/local/bin/perl

=head1 install-webmin.pl

Installs Webmin on multiple systems

This command can be used to install Webmin on a real or virtual system that
does not have it yet. On operating systems that support RPM packages (Fedora,
CentOS and Redhat) it will download the latest version in C<.rpm> format from
www.webmin.com , while on Debian and Ubuntu systems it will use the latest
C<.deb>. On other platforms, the C<.tar.gz> package of Webmin is used instead.

Installation is fully automatic, and where possible the initial Webmin login
is set to match the system's root password. If necessary, the C<wget> and
C<perl> programs are automatically installed on the target system, as they are
needed to fetch and run Webmin.

This command can install on multiple systems at once, specified using C<--host>,
C<--type> and other standard system selection parameters. This install will be
done in parallel, and for each system it completes successfully on the
hostname followed by OK, the package type and download URL will be displayed.

=head1 Example usage

  cloudmin install-webmin --host xenempty.home
  Installing Webmin on 1 systems ..
  xenempty.home: OK rpm http://www.webmin.com/download/rpm/webmin-current.rpm

=cut 

package server_manager;
$main::no_acl_check++;
$ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
$ENV{'WEBMIN_VAR'} ||= "/var/webmin";
if ($0 =~ /^(.*\/)[^\/]+$/) {
	chdir($1);
	}
chop($pwd = `pwd`);
$0 = "$pwd/install-webmin.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";

# Parse command line
while(@ARGV > 0) {
	local $a = shift(@ARGV);
	if ($a eq "--host") { push(@hosts, shift(@ARGV)); }
	elsif ($a eq "--group") { push(@groups, shift(@ARGV)); }
	elsif ($a eq "--os") { push(@types, shift(@ARGV)); }
	elsif ($a eq "--type") { push(@managers, shift(@ARGV)); }
        elsif ($a eq "--owner") { push(@owners, shift(@ARGV)); }
	else {
		&usage();
		}
	}

# Work out who to install on
@servers = &find_managed_servers(0, \@hosts, \@groups, \@managers, \@types, \@owners);
@servers || &usage("No systems specified");

# Make sure servers are valid
foreach $s (@servers) {
	if ($s->{'status'} ne 'nowebmin') {
		push(@cannot, $s);
		}
	}
@cannot && &usage("The following systems cannot have Webmin installed : ".
		  join(" ", map { $_->{'host'} } @cannot));

# Do the parallel install
print "Installing Webmin on ",scalar(@servers)," systems ..\n";
&obtain_lock_server(\@servers);
&parallel_server_function(\@servers,
	sub { ($src, $type, $err) = &get_install_webmin_source($_[0]);
	      if ($err) {
	          print "$_[0]->{'host'}: ERROR: $err\n";
                  return 1;
	      }
	      ($out, $err) = &install_webmin_server($_[0], $src, $type, 1);
	      if ($err) {
	          print "$_[0]->{'host'}: ERROR: $err\n";
	      } else {
		  &check_server_status($_[0]);
		  &save_managed_server($_[0]);
	          print "$_[0]->{'host'}: OK $type $src\n";
	      }
	    });
&release_lock_server(\@servers);

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Installs Webmin on one or more managed systems.\n";
print "\n";
print "cloudmin install-webmin [--host name]*\n";
print "                        [--group name]*\n";
local $types = join("|", @server_management_types);
print "                        [--type $types]*\n";
print "                        [--os oscode]*\n";
exit(1);
}

