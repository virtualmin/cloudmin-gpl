#!/usr/local/bin/perl

=head1 pause-system.pl

Pauses one or more managed systems

Puts a virtual system into a suspended state, in which it is still running
and consuming memory but cannot use any CPU time - similar to suspending
a laptop. Not all virtual system types support pausing.

=head1 Example usage

  ./pause-system.pl --host xencentos.home
  Pausing Xen system xencentos.home ..
  .. paused successfully

=cut

package server_manager;
$main::no_acl_check++;
$ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
$ENV{'WEBMIN_VAR'} ||= "/var/webmin";
if ($0 =~ /^(.*\/)[^\/]+$/) {
	chdir($1);
	}
chop($pwd = `pwd`);
$0 = "$pwd/pause-system.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";

# Parse command line
while(@ARGV > 0) {
	local $a = shift(@ARGV);
	if ($a eq "--host") { push(@hosts, shift(@ARGV)); }
	elsif ($a eq "--group") { push(@groups, shift(@ARGV)); }
	elsif ($a eq "--os") { push(@types, shift(@ARGV)); }
	elsif ($a eq "--type") { push(@managers, shift(@ARGV)); }
	elsif ($a eq "--help") { &usage(); }
	else {
		&usage();
		}
	}

# Get the systems
@servers = &find_managed_servers(0, \@hosts, \@groups, \@managers, \@types);
@servers || &usage("No systems specified");

# Check if any cannot be paused
foreach $s (@servers) {
	$pfunc = "type_".$s->{'manager'}."_can_pause";
	if (!defined(&$pfunc) || &$pfunc($s) != 1) {
		push(@cannot, $s);
		}
	}
@cannot && &usage("The following systems cannot be paused : ".
		  join(" ", map { $_->{'host'} } @cannot));

# Do it!
foreach $s (@servers) {
	$tfunc = "type_".$s->{'manager'}."_desc";
	$tdesc = &$tfunc();
	print "Pausing $tdesc system $s->{'host'} ..\n";
	$pfunc = "type_".$s->{'manager'}."_pause_system";
	$err = &$pfunc($s);
	if ($err) {
		$err = &html_tags_to_text($err);
		print ".. pause failed : $err\n\n";
		}
	else {
		&check_server_status($s, 0, 1);
		print ".. pause successfully\n\n";
		}
	&save_managed_server($s);
	}

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Pauses one or more managed systems.\n";
print "\n";
print "cloudmin pause-system [--host name]*\n";
print "                      [--group name]*\n";
local $types = join("|", @server_management_types);
print "                      [--type $types]*\n";
print "                      [--os oscode]*\n";
exit(1);
}

