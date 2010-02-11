#!/usr/local/bin/perl

=head1 upload-file.pl

Uploads a file to one or more systems

This command can send a file from the Cloudmin master system to one or more managed
hosts. The file is specified with the C<--source> parameter, and the
destination file or directory with C<--dest>. Alternately, you can have it
write input to the command to the destination with the C<--stdin> parameter.

The destination systems are specified with the C<--host>, C<--group> and other
standard system-selection parameters. When copying the file is transferred to
all systems in parallel, and the success or failure of each is shown as the
transfer completes.

If the source or destination file is block-special device (like an LVM logical
volume), you must add the --device-file flag.

For OpenVZ, Vservers and Zones systems, the file transfer will be done via the
host system, which works even if the virtual system is down. However, you can
force a transfer via SSH to the target system with the C<--force-ssh> flag.

=head1 Example usage

  cloudmin upload-file --host xencentos.home --host xenrails.home --host fedora.home --source /etc/hosts --dest /tmp/hosts
  Uploading file to 3 systems ..
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
$0 = "$pwd/install-webmin.pl";
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
	elsif ($a eq "--source") {
		$file = shift(@ARGV);
		}
	elsif ($a eq "--stdin") {
		$stdin = 1;
		}
	elsif ($a eq "--dest") {
		$dest = shift(@ARGV);
		}
	elsif ($a eq "--device-file") {
		$device = 1;
		}
	elsif ($a eq "--force-ssh") {
		$forcessh = 1;
		}
	else {
		&usage();
		}
	}

# Work out who to install on
@servers = &find_managed_servers(0, \@hosts, \@groups, \@managers, \@types, \@owners);
@servers || &usage("No systems specified");
&can_action_usage(\@servers, "transfer");
$dest || &usage("Missing --dest parameter");

# Get the file data
if ($file) {
	-r $file || &usage("File to upload does not exist");
	}
elsif ($stdin) {
	$file = &transname("file.txt");
	&open_tempfile(FILE, ">$file", 0, 1);
	while(<STDIN>) {
		&print_tempfile(FILE, $_);
		}
	&close_tempfile(FILE);
	}
else {
	&usage("One of --source or --stdin must be given");
	}

# Do the parallel upload
print "Uploading file to ",scalar(@servers)," systems ..\n";
@oks = &parallel_server_function(\@servers,
	sub { my ($server) = @_;
	      my $err = &mount_filesystem_if_needed($server);
	      if ($err) {
		print "$server->{'host'}: ERROR: $err\n";
		return 0;
		}

	      # Get the file
	      my $ok = 0;
	      $err = &put_file_to_server($server, $file, $dest,
					 $device, $forcessh);
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
print "Uploads a file to one or more managed systems.\n";
print "\n";
print "cloudmin upload-file [--host name]*\n";
print "                     [--group name]*\n";
my $types = join("|", @server_management_types);
print "                     [--type $types]*\n";
print "                     [--os oscode]*\n";
print "                     [--owner name]*\n";
print "                     [--source sourcepath] | [--stdin]\n";
print "                      --dest destpath\n";
print "                     [--device-file]\n";
print "                     [--force-ssh]\n";
exit(1);
}

