#!/usr/local/bin/perl

=head1 list-disk-storages.pl

Lists all disk storage locations available on some host system.

On host systems that support multiple storage locations for virtual disks,
this command lists all storages that are available. The C<--host> flag is used
to set the host system, and the C<--id-only>, C<--name-only> and 
C<--multiline> flags control the output format.

=head1 Example usage

  cloudmin list-disk-storages --host citrixhost
  ID                                       Name                                
  ---------------------------------------- ------------------------------------
  d6e9ccb3-cff5-978a-604d-8a7e9baf7270     Removable storage
  3d17f1d6-d5a0-1707-86c8-ab81fa68f977     Local storage
  3bcfadea-36d0-56f4-fba6-22438c981e11     XenServer Tools
  977a3e7d-34a1-9b51-ad1e-8b40b3411bc6     NFS ISO library
  48f33990-26a7-7d1a-f8b5-a20617e33317     DVD drives

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
$0 = "$pwd/list-disk-storages.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";

# Parse command line
while(@ARGV > 0) {
	my $a = shift(@ARGV);
	if ($a eq "--multiline") {
		$multi = 1;
		}
	elsif ($a eq "--id-only") {
		$idonly = 1;
		}
	elsif ($a eq "--name-only") {
		$nameonly = 1;
		}
	elsif ($a eq "--host") {
		$host = shift(@ARGV);
		}
	else {
		&usage();
		}
	}

# Get the host system
$host || &usage("Missing --host parameter");
$server = &get_managed_server_by("host", $host);
$server || &usage("System with hostname $host does not exist");
($manager) = &is_parent_server($server);
$manager || &usage("System $host is not a host system");

# Get the storages
$sfunc = "type_".$manager."_list_storages";
defined(&$sfunc) || &usage("System $host does not support disk storages");
$storages = &$sfunc($server);
ref($storages) || &usage("Failed to list disk storages : $storages");

if ($multi) {
	# One block storage
	foreach $s (@$storages) {
		print $s->{'id'},"\n";
		print "    Name: $s->{'desc'}\n";
		print "    Description: $s->{'longdesc'}\n"
			if ($s->{'longdesc'});
		}
	}
elsif ($nameonly) {
	# Just names
	foreach $s (@$storages) {
		print $s->{'desc'},"\n";
		}
	}
elsif ($idonly) {
	# Just IDs
	foreach $s (@$storages) {
		print $s->{'id'},"\n";
		}
	}
else {
	# One storage per line
	$fmt = "%-40.40s %-38.38s\n";
	printf $fmt, "ID", "Name";
	printf $fmt, ("-" x 40), ("-" x 38);
	foreach $s (@$storages) {
		printf $fmt, $s->{'id'}, $s->{'desc'};
		}
	}

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Lists all disk storage locations available on some host system.\n";
print "\n";
print "cloudmin list-disk-storages --host name\n";
print "                           [--multiline | --name-only | --id-only]\n";
exit(1);
}

