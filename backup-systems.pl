#!/usr/local/bin/perl

=head1 backup-systems.pl

Backs up one or more Cloudmin-managed virtual systems.

This command creates backups of one or more Cloudmin systems to the specified
backup destination. The systems to include are selected using standard
flags like C<--host> or C<--owner>, and the destination by the C<--dest>
flag followed by a destination specification like I</backup/cloudmin> or
I<backupserver:/cloudmin>.

By default, systems are backed up one by one. However, you can have them
done in parallel with the C<--parallel> flag.

Systems will be left running during the backup, which may lead to filesystem
or database inconsistencies. To have them shut down (if running) during the
backup, use the C<--shutdown> flag.

=head1 Example usage

  cloudmin backup-systems --host openvzgpl.home
  Finding systems to backup ..
  .. found 1 systems
  Working out backup destinations ..
  .. found 1 usable destinations
  Backing up openvzgpl.home to /backup/cloudmin/openvzgpl.home.tar.gz on Cloudmin master ..
  .. created backup of 160.40 MB

=cut

package server_manager;
$main::no_acl_check++;
$ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
$ENV{'WEBMIN_VAR'} ||= "/var/webmin";
if ($0 =~ /^(.*\/)[^\/]+$/) {
	chdir($1);
	}
chop($pwd = `pwd`);
$0 = "$pwd/backup-systems.pl";
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
	elsif ($a eq "--quiet") { $quiet = 1; }
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
$backup = { 'dest' => &join_backup_destination($desthash),
	    'servers' => join(' ', map { $_->{'id'} } @servers),
	    'shutdown' => $shutdown,
	    'parallel' => $parallel };

# Do the backup
if ($quiet) {
	&set_all_null_print();
	}
else {
	&set_all_text_print();
	}
$rv = &execute_backup($backup);

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
print " - An FTP destination, like ftp:login:pass\@server/backup\n";
print " - An SSH destination, like ssh:login:pass\@server/backup\n";
exit(1);
}

