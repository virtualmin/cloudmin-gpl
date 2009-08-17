#!/usr/local/bin/perl

=head1 backup-systems.pl

Backups up one or more Cloudmin-managed virtual systems.

XXX

=head1 Example usage

  cloudmin backup-systems --host xenrails.home
  XXX

=cut

package server_manager;
$main::no_acl_check++;
$ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
$ENV{'WEBMIN_VAR'} ||= "/var/webmin";
if ($0 =~ /^(.*\/)[^\/]+$/) {
	chdir($1);
	}
chop($pwd = `pwd`);
$0 = "$pwd/refresh-systems.pl";
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
	elsif ($a eq "--dest") { $dest = shift(@ARGV); }
	elsif ($a eq "--shutdown") { $shutdown = 1; }
	elsif ($a eq "--parallel") { $parallel = 1; }
	else {
		&usage();
		}
	}

# Validate args
$dest || &usage("Missing --dest parameter");
$desthash = &parse_backup_destination($dest);
$desthash ||  &usage("Invalid --dest specification $dest");

# Work out who to backup
@servers = &find_managed_servers(0, \@hosts, \@groups, \@managers, \@types, \@owners);
@servers || &usage("No systems specified");
$backup = { 'dest' => $dest,
	    'servers' => join(' ', map { $_->{'id'} } @servers),
	    'shutdown' => $shutdown,
	    'parallel' => $parallel };

# Do the backup
print "Starting backup of ",scalar(@servers)," systems to $dest ..\n";
&obtain_lock_server(\@servers);
$rv = &execute_backup($backup);
&release_lock_server(\@servers);
print ".. backup complete :\n\n";

# Show results
foreach $s (@servers) {
	$r = $rv->{$s->{'id'}};
	print $s->{'host'},": ";
	if ($r) {
		if ($r->{'ok'}) {
			print "OK ",&nice_size($r->{'size'});
			}
		else {
			print "FAILED ",$r->{'msg'};
			}
		}
	else {
		print "UNKNOWN";
		}
	print "\n";
	}

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Backs up one or more managed systems.\n";
print "\n";
print "cloudmin backup-systems [--host name]*\n";
print "                        [--group name]*\n";
local $types = join("|", @server_management_types);
print "                        [--type $types]*\n";
print "                        [--os oscode]*\n";
print "                        [--owner name]*\n";
print "                        --dest destination-directory\n";
print "                        [--shutdown]\n";
print "                        [--parallel]\n";
print "\n";
print "The destination can be one of :\n";
print " - A dir on the VM2 master, like /backup\n";
print " - A dir on another VM2-managed system, like backupbox:/backup\n";
print " - A dir on the host systems, like host:/backup\n";
print " - An FTP destination, like ftp://login:pass\@server/backup\n";
print " - An SSH destination, like ssh://login:pass\@server/backup\n";
exit(1);
}

