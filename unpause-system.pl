#!/usr/local/bin/perl

=head1 unpause-system.pl

Un-pauses one or more managed systems

Returns a virtual system from a suspended state, which has been entered
using the C<pause-system.pl> command or the web UI. All processes will continue
running where they left off, but some network connections may have been broken
due to TCP session timeouts.

=head1 Example usage

  cloudmin unpause-system --host xencentos.home
  Un-pausing Xen system xencentos.home ..
  .. un-paused successfully

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
$0 = "$pwd/unpause-system.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";
@OLDARGV = @ARGV;

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

# Check if any cannot be un-paused
foreach $s (@servers) {
	$pfunc = "type_".$s->{'manager'}."_can_pause";
	if (!defined(&$pfunc) || &$pfunc($s) != 2) {
		push(@cannot, $s);
		}
	}
@cannot && &usage("The following systems cannot be un-paused : ".
		  join(" ", map { $_->{'host'} } @cannot));

# Do it!
&obtain_lock_server(\@servers);
foreach $s (@servers) {
	$tfunc = "type_".$s->{'manager'}."_desc";
	$tdesc = &$tfunc();
	print "Un-pausing $tdesc system $s->{'host'} ..\n";
	$pfunc = "type_".$s->{'manager'}."_unpause_system";
	$err = &$pfunc($s);
	if ($err) {
		$err = &html_tags_to_text($err);
		print ".. un-pause failed : $err\n\n";
		}
	else {
		&check_server_status($s, 0, 1);
		print ".. un-pause successfully\n\n";
		}
	&save_managed_server($s);
	}
&release_lock_server(\@servers);
&cloudmin_api_log(\@OLDARGV);

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Resumes one or more paused systems.\n";
print "\n";
print "cloudmin unpause-system [--host name]*\n";
print "                        [--group name]*\n";
my $types = join("|", @server_management_types);
print "                        [--type $types]*\n";
print "                        [--os oscode]*\n";
print "                        [--owner name]*\n";
exit(1);
}

