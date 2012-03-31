#!/usr/local/bin/perl

=head1 startup-system.pl

Starts up one or more managed systems

For virtual systems running under Xen, VServers or Zones, Cloudmin can start up
existing instances using this command. The command will only exit when all the
specified systems have been booted.

=head1 Example usage

  cloudmin startup-system --host xencentos.home
  Starting up Xen system xencentos.home ..
  .. startup successfull

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
$0 = "$pwd/startup-system.pl";
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
	elsif ($a eq "--wait-for-ssh") { $waitssh = 1; }
	elsif ($a eq "--multiline") {
		$multiline = 1;
		}
	elsif ($a eq "--help") { &usage(); }
	else {
		&usage("Unknown parameter $a");
		}
	}

# Get the systems
@servers = &find_managed_servers(0, \@hosts, \@groups, \@managers, \@types, \@owners, \@statuses, \@hostons);
@servers || &usage("No systems specified");
&can_action_usage(\@servers, "startup"); 

# Check if any cannot be shutdown
foreach $s (@servers) {
	$sfunc = "type_".$s->{'manager'}."_no_startup";
	if (defined(&$sfunc) && &$sfunc($server) ||
	    ($s->{'status'} ne 'down' && $s->{'status'} ne 'nossh')) {
		push(@cannot, $s);
		}
	}
@cannot && &usage("The following systems cannot be started up : ".
		  join(" ", map { $_->{'host'} } @cannot));

# Do it!
&obtain_lock_server(\@servers);
foreach $s (@servers) {
	$tfunc = "type_".$s->{'manager'}."_desc";
	$tdesc = &$tfunc();
	print "Starting up $tdesc system $s->{'host'} ..\n";
	($ok, $err) = &startup_server($s);
	if (!$ok) {
		$err = &html_tags_to_text($err);
		print ".. startup failed : $err\n\n";
		}
	else {
		&check_server_status($s);
		if ($ok == 1) {
			print ".. startup successfull\n\n";
			}
		else {
			print ".. started, but a problem was detected : $err\n\n";
			}
		}

	if ($waitssh) {
		# Wait for system to be SSH able
		print "Waiting for SSH login to $s->{'host'} ..\n";
		$start = time();
		while(1) {
			&check_server_status($s, 0, 1);
			last if (&can_ssh_status($s));
			$diff = time() - $start;
			last if ($diff > $startup_ssh_timeout);
			$desc = $text{'status_'.$s->{'status'}};
			print "  .. status after $diff seconds is : ",
			      "$s->{'status'} ($desc)\n";
			sleep(1);
			}
		}
	else {
		# Just check once
		print "Refreshing status of $s->{'host'} ..\n";
		&check_server_status($s, 0, 1);
		}
	&refresh_server_usage($s);
	&save_managed_server($s);
	$desc = $text{'status_'.$s->{'status'}};
	print ".. new status is : $s->{'status'} ($desc)\n";
	}
&release_lock_server(\@servers);
&cloudmin_api_log(\@OLDARGV);

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Starts up one or more managed systems.\n";
print "\n";
print "cloudmin startup-system [--host name]*\n";
print "                        [--group name]*\n";
my $types = join("|", @server_management_types);
print "                        [--type $types]*\n";
print "                        [--os oscode]*\n";
print "                        [--owner name]*\n";
print "                        [--status status-code|\"up\"|\"wm\"|\"bad\"]\n";
print "                        [--host-on name]\n";
print "                        [--wait-for-ssh]\n";
exit(1);
}

