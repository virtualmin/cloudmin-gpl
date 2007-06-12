#!/usr/local/bin/perl
# Shuts down one or more managed systems

package server_manager;
$main::no_acl_check++;
$ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
$ENV{'WEBMIN_VAR'} ||= "/var/webmin";
if ($0 =~ /^(.*\/)[^\/]+$/) {
	chdir($1);
	}
chop($pwd = `pwd`);
$0 = "$pwd/shutdown-system.pl";
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

# Get the systems
@servers = &find_managed_servers(0, \@hosts, \@groups, \@managers, \@types);
@servers = sort { $a->{'host'} cmp $b->{'host'} } @servers;
@servers || &usage("No systems specified");

# Check if any cannot be shutdown
foreach $s (@servers) {
	$sfunc = "type_".$s->{'manager'}."_no_shutdown";
	if (defined(&$sfunc) && &$sfunc($server) ||
	    $s->{'status'} eq 'down' || $s->{'status'} eq 'nohost') {
		push(@cannot, $s);
		}
	}
@cannot && &usage("The following systems cannot be shut down : ".
		  join(" ", map { $_->{'host'} } @cannot));

# Do it!
foreach $s (@servers) {
	$tfunc = "type_".$s->{'manager'}."_desc";
	$tdesc = &$tfunc();
	print "Shutting down $tdesc system $s->{'host'} ..\n";
	$err = &shutdown_server($s);
	if ($err) {
		$err = &html_tags_to_text($err);
		print ".. shutdown failed : $err\n\n";
		}
	else {
		&check_server_status($s);
		&save_managed_server($s);
		print ".. shutdown successfull\n\n";
		}
	}

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Shuts down one or more managed systems.\n";
print "\n";
print "usage: shutdown-system.pl [--host name]*\n";
print "                          [--group name]*\n";
local $types = join("|", @server_management_types);
print "                          [--type $types]*\n";
print "                          [--os oscode]*\n";
exit(1);
}

