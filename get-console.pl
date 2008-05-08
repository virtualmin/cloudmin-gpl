#!/usr/local/bin/perl
# Output console messages for some host

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

