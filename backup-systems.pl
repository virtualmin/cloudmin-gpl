#!/usr/local/bin/perl

=head1 backup-systems.pl

Backs up one or more Cloudmin-managed virtual systems.

This command creates backups of one or more Cloudmin systems to the specified
backup destination. The systems to include are selected using standard
flags like C<--host> or C<--owner>, and the destination by the C<--dest>
flag followed by a destination specification like I</backup/cloudmin> or
I<backupserver:/cloudmin>. To use the default backup destination for each
system's host, use the C<--default-dest> flag instead of C<--dest>.

By default, systems are backed up one by one. However, you can have them
done in parallel with the C<--parallel> flag.

Systems will be left running during the backup, which may lead to filesystem
or database inconsistencies. To have them shut down (if running) during the
backup, use the C<--shutdown> flag.

To have Cloudmin delete backup old destinations under the same directory as
this backup's destination, use the C<--purge> flag followed by a number of
days. This will only work if the backup is to a date-based directory, like
I</backup/%d-%m-%Y>.

To just show which systems will be backed up and to where, use the C<--test>
flag. This is useful when selecting systems by group or host, or when using
a date-based backup destination spec.

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
if ($0 =~ /^(.*)\/[^\/]+$/) {
	chdir($pwd = $1);
	}
else {
	chop($pwd = `pwd`);
	}
$0 = "$pwd/backup-systems.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";
@OLDARGV = @ARGV;
&usage_if_cloudmin_replica();

# Parse command line
while(@ARGV > 0) {
	my $a = shift(@ARGV);
	if ($a eq "--host") { push(@hosts, shift(@ARGV)); }
	elsif ($a eq "--group") { push(@groups, shift(@ARGV)); }
	elsif ($a eq "--os") { push(@types, shift(@ARGV)); }
	elsif ($a eq "--type") { push(@managers, shift(@ARGV)); }
        elsif ($a eq "--owner") { push(@owners, shift(@ARGV)); }
	elsif ($a eq "--host-on") { push(@hostons, shift(@ARGV)); }
	elsif ($a eq "--status") { push(@statuses, shift(@ARGV)); }
	elsif ($a eq "--dest") { $dest = shift(@ARGV); }
	elsif ($a eq "--default-dest") { $defaultdest = 1 };
	elsif ($a eq "--shutdown") { $shutdown = 1; }
	elsif ($a eq "--parallel") { $parallel = 1; }
	elsif ($a eq "--quiet") { $quiet = 1; }
	elsif ($a eq "--purge") { $purge = shift(@ARGV); }
	elsif ($a eq "--test") { $test = 1; }
	else {
		&usage();
		}
	}

# Validate args
$dest || $defaultdest || &usage("Missing --dest or --default-dest parameter");
if ($dest) {
	$desthash = &parse_backup_destination($dest);
	$desthash ||  &usage("Invalid --dest specification $dest");
	}
if (defined($purge)) {
	$purge =~ /^[0-9\.]+$/ && $purge > 0 ||
		&usage("--purge must be followed by a non-zero number of days");
	($base, $date) = &extract_purge_path($dest);
	$base || &usage("--purge can only be used when the backup destination ".
			"contains date codes");
	}

# Work out who to backup
@servers = &find_managed_servers(0, \@hosts, \@groups, \@managers, \@types, \@owners, \@statuses, \@hostons);
@servers || &usage("No systems specified");
$backup = { 'dest' => $desthash ? &join_backup_destination($desthash)
				: undef,
	    'servers' => join(' ', map { $_->{'id'} } @servers),
	    'shutdown' => $shutdown,
	    'parallel' => $parallel,
	    'purge' => $purge, };

# Make sure source and dest can be managed by the user
&can_action_usage(\@servers, "backup");
if ($desthash && $desthash->{'mode'} <= 2) {
	foreach $s (@servers) {
		$vhost = &get_parent_server($s);
		$destserver = &get_backup_dest_server($desthash, $vhost);
		&can_action_usage($destserver, "backup");
		}
	}

# In test mode, just show what would be done
if ($test) {
	foreach $s (@servers) {
		$r = $rv->{$s->{'id'}};
		($ok, $destfile) = &compute_backup_destination($s, $backup);
		print $s->{'host'},": ";
		if ($ok) {
			print "OK $destfile\n";
			}
		else {
			print "ERROR $destfile\n";
			}
		}
	exit;
	}

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
&cloudmin_api_log(\@OLDARGV);

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Backs up one or more managed systems.\n";
print "\n";
print "cloudmin backup-systems [--host name]*\n";
print "                        [--group name]*\n";
my $types = join("|", @server_management_types);
print "                        [--type $types]*\n";
print "                        [--os oscode]*\n";
print "                        [--owner name]*\n";
print "                        [--status status-code|\"up\"|\"wm\"|\"bad\"]\n";
print "                        [--host-on name]\n";
print "                        --dest destination-directory | --default-dest\n";
print "                        [--shutdown]\n";
print "                        [--parallel]\n";
print "                        [--purge days]\n";
print "                        [--test]\n";
print "\n";
print "The destination can be one of :\n";
print " - A dir on the VM2 master, like /backup\n";
print " - A dir on another VM2-managed system, like backupbox:/backup\n";
print " - A dir on the host systems, like host:/backup\n";
print " - An FTP destination, like ftp:login:pass\@server/backup\n";
print " - An SSH destination, like ssh:login:pass\@server/backup\n";
exit(1);
}

