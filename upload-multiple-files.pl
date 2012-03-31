#!/usr/local/bin/perl

=head1 upload-multiple-files.pl

Uploads multiple files to a directory on one or more systems.

This command can send several files from the Cloudmin master system to one
or more managed
hosts. The files are specified with the C<--source> parameter, which can be
given multiple times and use shell wildcards. The destination directory is set
with the C<--dest> flag, follow by a directory that must exist on all target
systems.

The destination systems are specified with the C<--host>, C<--group> and other
standard system-selection parameters. When copying the files are transferred to
all systems in parallel, and the success or failure of each is shown as the
transfer completes.

For OpenVZ, Vservers and Zones systems, the file transfer will be done via the
host system, which works even if the virtual system is down. However, you can
force a transfer via SSH to the target system with the C<--force-ssh> flag.

=head1 Example usage

  cloudmin upload-multiple-files --host xencentos.home --host xenrails.home --host fedora.home --source /etc/h* --dest /tmp
  Uploading 10 files to 3 systems ..
  xencentos.home: OK
  xenrails.home: OK
  fedora.home: ERROR: ssh: connect to host fedora.home port 22: No route to host lost connection

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
$0 = "$pwd/upload-multiple-files.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";
@OLDARGV = @ARGV;

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
	elsif ($a eq "--source") {
		while(@ARGV && $ARGV[0] !~ /^--/) {
			push(@files, shift(@ARGV));
			}
		}
	elsif ($a eq "--dest") {
		$dest = shift(@ARGV);
		}
	elsif ($a eq "--force-ssh") {
		$forcessh = 1;
		}
	elsif ($a eq "--multiline") {
		$multiline = 1;
		}
	else {
		&usage("Unknown parameter $a");
		}
	}
@files = grep { -f $_ } @files;

# Work out who to install on
@servers = &find_managed_servers(0, \@hosts, \@groups, \@managers, \@types, \@owners, \@statuses, \@hostons);
@servers || &usage("No systems specified");
&can_action_usage(\@servers, "transfer");
$dest || &usage("Missing --dest parameter");
@files || &usage("Missing --source parameter");

# Do the parallel upload
print "Uploading ",scalar(@files)," files to ",scalar(@servers)," systems ..\n";
@oks = &parallel_server_function(\@servers,
	sub { my ($server) = @_;
	      my $err = &mount_filesystem_if_needed($server);
	      if ($err) {
		print "$server->{'host'}: ERROR: $err\n";
		return 0;
		}

	      # Get the file
	      my $ok = 0;
	      $err = &put_multiple_files_to_server($server, \@files, $dest,
						   $forcessh);
	      if ($err) {
	          print "$server->{'host'}: ERROR: $err\n";
	          }
              else {
	          print "$server->{'host'}: OK\n";
		  $ok = 1;
	          }
	      &umount_filesystem_if_needed($server);
	      return $ok;
	    });
@fails = grep { !$_->[0] } @oks;
exit(scalar(@fails));
&cloudmin_api_log(\@OLDARGV);

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Uploads multiple files to a directory on one or more systems.\n";
print "\n";
print "cloudmin upload-multiple-files [--host name]*\n";
print "                               [--group name]*\n";
my $types = join("|", @server_management_types);
print "                               [--type $types]*\n";
print "                               [--os oscode]*\n";
print "                               [--owner name]*\n";
print "                               [--status status-code|\"up\"|\"wm\"|\"bad\"]\n";
print "                               [--host-on name]\n";
print "                               [--source sourcepath]*\n";
print "                                --dest destdirectory\n";
print "                               [--force-ssh]\n";
exit(1);
}

