#!/usr/local/bin/perl

=head1 install-virtualmin.pl

Installs Virtualmin on multiple systems

If you have a system without Virtualmin installed, this command can be used to
perform a manual install on it using the Virtualmin standard install script.
In general we do not recommend this - it is much simpler and more reliable
to create virtual systems from an image that already includes the full
Virtualmin software stack.

This command can install on multiple systems at once, specified using
C<--host>, C<--type> and other standard system selection parameters. This
install will be done in parallel, but can still take some time (10-20 minutes)
as it will download required packages from your Linux distribution's
repository and the Virtualmin website.

All Virtualmin Pro installs require a license, which can be specified to this
command using either the C<--allocate-serial> parameter, or C<--serial> and
C<--key>. The former selects a free serial for each system you are installing
on from the license pool, while the latter lets you manually select a serial
number and key to be used on all systems. 

To install Virtualmin GPL instead, use the C<--gpl-serial> command line flag.

=head1 Example usage

For each system that the install completes successfully on, a line starting
with the hostname followed OK will be output.

  cloudmin install-virtualmin --host xencentos.home
  xencentos.home: Started
  xencentos.home: OK

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
$0 = "$pwd/install-virtualmin.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";
@OLDARGV = @ARGV;
&usage_if_cloudmin_replica();

# Parse command line
while(@ARGV > 0) {
	my $a = shift(@ARGV);
	if ($a eq "--host") { push(@hosts, shift(@ARGV)); }
	elsif ($a eq "--group") { push(@groups, shift(@ARGV)); }
	elsif ($a eq "--os") { push(@types, shift(@ARGV)); }
	elsif ($a eq "--type") { push(@managers, shift(@ARGV)); }
        elsif ($a eq "--owner") { push(@owners, shift(@ARGV)); }
        elsif ($a eq "--host-on") { push(@hostons, shift(@ARGV)); }
        elsif ($a eq "--status") { push(@statuses, shift(@ARGV)); }
	elsif ($a eq "--serial") { $serial = shift(@ARGV); }
	elsif ($a eq "--key") { $key = shift(@ARGV); }
	elsif ($a eq "--same-serial") { $same_serial = 1; }
	elsif ($a eq "--allocate-serial") { $allocate_serial = 1; }
	elsif ($a eq "--gpl-serial") { $serial = $key = "GPL"; }
	elsif ($a eq "--multiline") {
		$multiline = 1;
		}
	else {
		&usage("Unknown parameter $a");
		}
	}

# Make sure a serial number is specified
$serial && $key || $same_serial || $allocate_serial ||
	&usage("A Virtualmin licence must be specified with --serial, --same-serial or --allocate-serial");

# Work out who to install on
@servers = &find_managed_servers(0, \@hosts, \@groups, \@managers, \@types, \@owners, \@statuses, \@hostons);
@servers || &usage("No systems specified");
&can_action_usage(\@servers, "virtualmin");

# Make sure servers are valid
foreach $s (@servers) {
	if ($s->{'status'} ne 'nowebmin' &&
	    $s->{'status'} ne 'novirt') {
		push(@cannot, $s);
		}
	}
@cannot && &usage("The following systems cannot have Virtualmin installed : ".
		  join(" ", map { $_->{'host'} } @cannot));

# Work out the serial and key to use
if ($same_serial) {
	# Same as Cloudmin
	&can_action_usage(\@servers, "licence");
	%serialmap = map { $_->{'id'}, [ &get_server_manager_serial() ] }
			 @servers;
	}
elsif ($allocate_serial) {
	# Allocate from pool
	&can_action_usage(\@servers, "licence");
	foreach $s (@servers) {
		($serial, $key) = &allocate_virtualmin_serial();
		$serial || &usage("Could not allocate serial number ".
				  "for $s->{'host'} : $key");
		$serialmap{$s->{'id'}} = [ $serial, $key ];
		}
	}
else {
	# Whatever was entered
	%serialmap = map { $_->{'id'}, [ $serial, $key ] } @servers;
	}

# Validate serials
foreach $s (@servers) {
	($tserial, $tkey) = @{$serialmap{$s->{'id'}}};
	if ($tserial ne "GPL") {
		$tok = &check_virtualmin_serial($tserial, $tkey);
		$tok || &usage("Serial $tserial or key $tkey for $s->{'host'} is not valid");
		$tok > 0 || &usage("Could not validate serial for $s->{'host'}");
		}
	}

# Do the parallel refresh
print "Installing Virtualmin on ",scalar(@servers)," systems ..\n";
&obtain_lock_server(\@servers);
&parallel_server_function(\@servers,
	sub { # Start install
	      ($serial, $key) = @{$serialmap{$_[0]->{'id'}}};
	      &start_installing_virtualmin_licence($serial, $key);
	      $err = &install_virtualmin_server($_[0], 0, $serial, $key);
	      if ($err) {
	          print "$_[0]->{'host'}: ERROR: $err\n";
                  return 1;
	      }
	      print "$_[0]->{'host'}: Started\n";
	      while(1) {
		  $done = &install_virtualmin_server_done($_[0]);
		  if ($done) {
	              &stop_installing_virtualmin_licence($serial, $key);
		  }
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
&release_lock_server(\@servers);
&cloudmin_api_log(\@OLDARGV);

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Installs Virtualmin on one or more managed systems.\n";
print "\n";
print "cloudmin install-virtualmin [--host name]*\n";
print "                            [--group name]*\n";
my $types = join("|", @server_management_types);
print "                            [--type $types]*\n";
print "                            [--os oscode]*\n";
print "                            [--serial number --key number |\n";
print "                             --same-serial | --allocate-serial |\n";
print "                             --gpl-serial]\n";
print "                            [--owner name]*\n";
print "                            [--status status-code|\"up\"|\"wm\"|\"bad\"]\n";
print "                            [--host-on name]\n";
exit(1);
}

