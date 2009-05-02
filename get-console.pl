#!/usr/local/bin/perl

=head1 get-console.pl

Output boot-time console messages for some host

This command outputs all messages captured from the console of specified
virtual systems during bootup. At the time of writing, this was only possible
for Xen and EC2 instances. It can be useful for debugging boot failures or
figuring out why some server processes were not started at boot time.

For interactive access to the console, you can instead use the Console Login
page in the Cloudmin web user interface.

=head1 Example usage

  ./get-console.pl --host xensendmail.home
  PTY PID: 9535
  Using config file "/xen/xensendmail.cfg".
  Started domain xensendmail
  Linux version 2.6.18-8.1.4.el5xen (mockbuild@builder4.centos.org) (gcc version 4.1.1 20070105 (Red Hat 4.1.1-52)) #1 SMP Thu May 17 05:27:09 EDT 2007
  BIOS-provided physical RAM map:
   Xen: 0000000000000000 - 0000000020800000 (usable)
  0MB HIGHMEM available.
  520MB LOWMEM available.
  NX (Execute Disable) protection: active
  ACPI in unprivileged domain disabled
  Built 1 zonelists.  Total pages: 133120
  Kernel command line:  root=/dev/sda1 ro
  Enabling fast FPU save and restore... done.
  Enabling unmasked SIMD FPU exception support... done.
  Initializing CPU#0
  CPU 0 irqstacks, hard=c071b000 soft=c06fb000
  PID hash table entries: 4096 (order: 12, 16384 bytes)
  Xen reported: 2992.498 MHz processor.
  Console: colour dummy device 80x25

=cut

package server_manager;
$main::no_acl_check++;
$ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
$ENV{'WEBMIN_VAR'} ||= "/var/webmin";
if ($0 =~ /^(.*\/)[^\/]+$/) {
	chdir($1);
	}
chop($pwd = `pwd`);
$0 = "$pwd/get-console.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";

# Parse command line
while(@ARGV > 0) {
	local $a = shift(@ARGV);
	if ($a eq "--all-hosts") { $all = 1; }
	elsif ($a eq "--host") { push(@hosts, shift(@ARGV)); }
	elsif ($a eq "--group") { push(@groups, shift(@ARGV)); }
	elsif ($a eq "--os") { push(@types, shift(@ARGV)); }
	elsif ($a eq "--type") { push(@managers, shift(@ARGV)); }
	elsif ($a eq "--help") { &usage(); }
	else {
		push(@cmd, $a);
		}
	}

# Work out who to get consoles from
@servers = &find_managed_servers($all, \@hosts, \@groups, \@managers, \@types);
@servers || &usage("No systems specified");

# Make sure they all support it
foreach $s (@servers) {
	$cfunc = "type_".$s->{'manager'}."_get_console_output";
	defined(&$cfunc) || &usage("Console messages cannot be fetched for $s->{'manager'} system $s->{'host'}");
	}

# Output in turn
foreach $s (@servers) {
	if (@servers > 1) {
		print $s->{'host'},":\n";
		}
	$cfunc = "type_".$s->{'manager'}."_get_console_output";
	($ok, $out) = &$cfunc($s);
	if (!$ok) {
		print "ERROR: $out\n";
		}
	else {
		print $out;
		}
	}

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Outputs console messages for one or more managed systems.\n";
print "\n";
print "usage: get-console.pl [--all-hosts] | [--host name]*\n";
print "                      [--group name]*\n";
local $types = join("|", @server_management_types);
print "                      [--type $types]*\n";
print "                      [--os oscode]*\n";
exit(1);
}

