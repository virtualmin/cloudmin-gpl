#!/usr/local/bin/perl

=head1 restore-systems.pl

Restores one or more Cloudmin-managed virtual systems.

This command restores backups of one or more Cloudmin systems from the
specified backup destination. The systems to include are selected using standard
flags like C<--host> or C<--owner>, and the destination by the C<--source>
flag followed by a destination specification like I</backup/cloudmin> or
I<backupserver:/cloudmin>.

By default, systems are restored one by one. However, you can have them
done in parallel with the C<--parallel> flag.

If a system being restored no longer exists, Cloudmin will attempt to re-create
it using the same parameters (like disk size, CPU and memory limits) that it
had originally. However, this will fail if the original host system is down
or un-available - in which case you can use the C<--new-host> flag to specify
an alternate host system to restore on.

=head1 Example usage

  cloudmin restore-systems --host functest.home --source /tmp
  Finding systems to restore ..
  .. found 1 systems
  Working out backup sources ..
  .. found 1 usable sources
  Restoring functest.home from /tmp/functest.home.tar.gz on Cloudmin master ..
    Un-TARing filesystem for functest.home under /vz/private/10016 via SSH from fudu.home ..
  .. restore failed : Failed to extract TAR file : Unknown error
  functest.home: FAILED Failed to extract TAR file : Unknown error

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
$0 = "$pwd/restore-systems.pl";
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
	elsif ($a eq "--source") { $source = shift(@ARGV); }
	elsif ($a eq "--parallel") { $parallel = 1; }
	elsif ($a eq "--quiet") { $quiet = 1; }
	elsif ($a eq "--new-host") { $newhost = shift(@ARGV); }
	elsif ($a eq "--multiline") {
		$multiline = 1;
		}
	else {
		&usage("Unknown parameter $a");
		}
	}

# Validate args
$source || &usage("Missing --source parameter");
$sourcehash = &parse_backup_destination($source);
$sourcehash ||  &usage("Invalid --source specification $source");

# Work out who to restore
@servers = &find_managed_servers(0, \@hosts, \@groups, \@managers, \@types, \@owners, \@statuses, \@hostons);

# For hostnames that don't exist, check if they have .serv files at
# the source
foreach $h (@hosts) {
	($server) = grep { $_->{'host'} eq $h } @servers;
	if (!$server) {
		$server = &get_missing_backup_server($h, $source);
		if ($server) {
			push(@missing, $server);
			}
		else {
			push(@badhosts, $h);
			}
		}
	}

# Check forced host system for missing systems
if ($newhost) {
	$newvhost = &get_managed_server_by("host", $newhost);
	$newvhost || &usage("Host system $newhost does not exist");
	foreach my $m (@missing) {
		$newvhost->{$m->{'manager'}.'_host'} ||
			&usage($m->{'host'}." cannot be hosted on ".$newhost);
		}
	}

if (!@servers && !@missing) {
	if (@badhosts) {
		&usage("No systems with hostnames ".
		       join(" ", @badhosts)." were found");
		}
	else {
		&usage("No systems specified");
		}
	}
$backup = { 'dest' => $source,
	    'servers' => join(' ', map { $_->{'id'} } @servers),
	    'missing' => join(' ', map { $_->{'host'} } @missing),
	    'newvhost' => $newvhost->{'id'},
	    'parallel' => $parallel };

# Make sure source and dest can be managed by the user
&can_action_usage(\@servers, "backup");
if ($sourcehash->{'mode'} <= 2) {
	foreach $s (@servers) {
		$vhost = &get_parent_server($s);
		$sourceserver = &get_backup_dest_server($sourcehash, $vhost);
		&can_action_usage($sourceserver, "backup");
		}
	}

# Do the restore
if ($quiet) {
	&set_all_null_print();
	}
else {
	&set_all_text_print();
	}
$rv = &execute_restore($backup);

# Show results
$allok = 1;
foreach $s (@servers, @missing) {
	$r = $rv->{$s->{'id'}};
	print $s->{'host'},": ";
	if ($r) {
		if ($r->{'ok'}) {
			print "OK ",&nice_size($r->{'size'});
			}
		else {
			print "FAILED ",$r->{'msg'};
			$allok = 0;
			}
		}
	else {
		print "UNKNOWN";
		$allok = 0;
		}
	print "\n";
	}
&cloudmin_api_log(\@OLDARGV);
exit($allok ? 0 : 1);

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Restores one or more managed systems.\n";
print "\n";
print "cloudmin restore-systems [--host name]*\n";
print "                         [--group name]*\n";
my $types = join("|", @server_management_types);
print "                         [--type $types]*\n";
print "                         [--os oscode]*\n";
print "                         [--owner name]*\n";
print "                         [--status status-code|\"up\"|\"wm\"|\"bad\"]\n";
print "                         [--host-on name]\n";
print "                         --source source-directory\n";
print "                         [--parallel]\n";
print "                         [--new-host hostname]\n";
exit(1);
}

