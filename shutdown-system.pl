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
	if ($a eq "--host") {
		push(@names, shift(@ARGV));
		}
	else {
		&usage();
		}
	}

# Get the systems
@names || &usage("No system to shut down specified");
foreach my $n (@names) {
	$server = &get_managed_server_by("host", $n);
	$server || &usage("No system with hostname $n exists");
	push(@servers, $server);
	}

# Check if any cannot be shutdown
foreach $s (@servers) {
	$sfunc = "type_".$s->{'manager'}."_no_shutdown";
	if (defined(&$sfunc) && &$sfunc($server) ||
	    $s->{'status'} eq 'down' || $s->{'status'} eq 'nossh' ||
	    $s->{'status'} eq 'nohost') {
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
print "usage: shutdown-system.pl --host name [--host name]*\n";
exit(1);
}

