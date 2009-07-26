#!/usr/local/bin/perl

=head1 reboot-system.pl

Reboots one or more managed systems

Triggers an immediate reboot of the specified systems. For virtual machines,
Cloudmin will wait until they come back up before exiting, while for real systems
it just runs the reboot command, which merely starts the reboot process in the
background.

=head1 Example usage

  cloudmin reboot-system --host xencentos.home
  Rebooting Xen system xencentos.home ..
  .. rebooted successfully

=cut

package server_manager;
$main::no_acl_check++;
$ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
$ENV{'WEBMIN_VAR'} ||= "/var/webmin";
if ($0 =~ /^(.*\/)[^\/]+$/) {
	chdir($1);
	}
chop($pwd = `pwd`);
$0 = "$pwd/reboot-system.pl";
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
	elsif ($a eq "--help") { &usage(); }
	else {
		&usage();
		}
	}

# Get the systems
@servers = &find_managed_servers(0, \@hosts, \@groups, \@managers, \@types, \@owner);
@servers || &usage("No systems specified");

# Check if any cannot be rebooted
foreach $s (@servers) {
	$sfunc = "type_".$s->{'manager'}."_no_reboot";
	if (defined(&$sfunc) && &$sfunc($server) ||
	    $s->{'status'} eq 'down' || $s->{'status'} eq 'nossh' ||
	    $s->{'status'} eq 'nohost') {
		push(@cannot, $s);
		}
	}
@cannot && &usage("The following systems cannot be rebooted : ".
		  join(" ", map { $_->{'host'} } @cannot));

# Do it!
&obtain_lock_server(\@servers);
foreach $s (@servers) {
	$tfunc = "type_".$s->{'manager'}."_desc";
	$tdesc = &$tfunc();
	print "Rebooting $tdesc system $s->{'host'} ..\n";
	$err = &reboot_server($s);
	if ($err) {
		$err = &html_tags_to_text($err);
		print ".. reboot failed : $err\n\n";
		}
	else {
		print ".. rebooted successfully\n\n";
		}
	&save_managed_server($s);
	}
&release_lock_server(\@servers);

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Reboots one or more managed systems.\n";
print "\n";
print "cloudmin reboot-system [--host name]*\n";
print "                       [--group name]*\n";
local $types = join("|", @server_management_types);
print "                       [--type $types]*\n";
print "                       [--os oscode]*\n";
exit(1);
}

