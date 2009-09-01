#!/usr/local/bin/perl

=head1 startup-system.pl

Starts up one or more managed systems

For virtual systems running under Xen, VServers or Zones, Cloudmin can start up
existing instances using this command. The command will only exit when all the
specified systems have been booted.

=head1 Example usage

  cloudmin startup-system --host xencentos.home
  Starting up Xen system xencentos.home ..
  .. startup successfull

=cut

package server_manager;
$main::no_acl_check++;
$ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
$ENV{'WEBMIN_VAR'} ||= "/var/webmin";
if ($0 =~ /^(.*\/)[^\/]+$/) {
	chdir($1);
	}
chop($pwd = `pwd`);
$0 = "$pwd/startup-system.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";

# Parse command line
while(@ARGV > 0) {
	my $a = shift(@ARGV);
	if ($a eq "--host") { push(@hosts, shift(@ARGV)); }
	elsif ($a eq "--group") { push(@groups, shift(@ARGV)); }
	elsif ($a eq "--os") { push(@types, shift(@ARGV)); }
	elsif ($a eq "--type") { push(@managers, shift(@ARGV)); }
        elsif ($a eq "--owner") { push(@owners, shift(@ARGV)); }
	elsif ($a eq "--help") { &usage(); }
	else {
		&usage();
		}
	}

# Get the systems
@servers = &find_managed_servers(0, \@hosts, \@groups, \@managers, \@types, \@owners);
@servers || &usage("No systems specified");

# Check if any cannot be shutdown
foreach $s (@servers) {
	$sfunc = "type_".$s->{'manager'}."_no_startup";
	if (defined(&$sfunc) && &$sfunc($server) ||
	    ($s->{'status'} ne 'down' && $s->{'status'} ne 'nossh')) {
		push(@cannot, $s);
		}
	}
@cannot && &usage("The following systems cannot be started up : ".
		  join(" ", map { $_->{'host'} } @cannot));

# Do it!
&obtain_lock_server(\@servers);
foreach $s (@servers) {
	$tfunc = "type_".$s->{'manager'}."_desc";
	$tdesc = &$tfunc();
	print "Starting up $tdesc system $s->{'host'} ..\n";
	($ok, $err) = &startup_server($s);
	if (!$ok) {
		$err = &html_tags_to_text($err);
		print ".. startup failed : $err\n\n";
		}
	else {
		&check_server_status($s);
		if ($ok == 1) {
			print ".. startup successfull\n\n";
			}
		else {
			print ".. started, but a problem was detected : $err\n\n";
			}
		}
	&check_server_status($s, 0, 1);
	&refresh_server_usage($s);
	&save_managed_server($s);
	}
&release_lock_server(\@servers);

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Starts up one or more managed systems.\n";
print "\n";
print "cloudmin startup-system [--host name]*\n";
print "                        [--group name]*\n";
my $types = join("|", @server_management_types);
print "                        [--type $types]*\n";
print "                        [--os oscode]*\n";
print "                        [--owner name]*\n";
exit(1);
}

