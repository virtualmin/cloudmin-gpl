#!/usr/local/bin/perl
# Deletes a virtual system or systems

package server_manager;
$main::no_acl_check++;
$ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
$ENV{'WEBMIN_VAR'} ||= "/var/webmin";
if ($0 =~ /^(.*\/)[^\/]+$/) {
	chdir($1);
	}
chop($pwd = `pwd`);
$0 = "$pwd/delete-system.pl";
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
@names || &usage("No system to delete specified");
foreach my $n (@names) {
	$server = &get_managed_server_by("host", $n);
	$server || &usage("No system with hostname $n exists");
	push(@servers, $server);
	}

# Check if they can all be deleted
foreach $s (@servers) {
	if ($s->{'manager'} eq 'real' || $s->{'manager'} eq 'this') {
		push(@cannot, $s);
		&usage("$s->{'host'} is not a virtual system that ".
		       "can be deleted");
		}
	}
if (@cannot) {
	&usage("The following systems are not virtual and cannot be deleted : ".
	       join(" ", map { $_->{'host'} } @cannot));
	}

# Check for dependencies
@deps = map { local $_; &find_server_dependencies($_) } @servers;
if (@deps) {
	&usage("The following systems have dependencies and cannot be ".
	       "deleted : ".join(" ", map { $_->{'host'} } @deps));
	}

# Do it!
foreach $s (@servers) {
	$tfunc = "type_".$s->{'manager'}."_desc";
	$tdesc = &$tfunc();

	# Run pre-deletion script
	&run_system_script($s, 'before', 'delete') || next;

	print "Deleting $tdesc system $s->{'host'} ..\n";
	$dfunc = "type_".$s->{'manager'}."_delete";
	$err = &$dfunc($s);
	if ($err) {
		print ".. deletion failed : $err\n\n";
		}
	else {
		&remove_server_ssh_keys($s);
		&delete_managed_server($s);
		print ".. deleted successfully\n\n";

		# Run post-deletion script
		&run_system_script($s, 'after', 'delete');
		}
	}

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Deletes one or more managed systems.\n";
print "\n";
print "usage: delete-system.pl --host name [--host name]*\n";
exit(1);
}

