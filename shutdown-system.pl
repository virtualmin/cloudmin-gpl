#!/usr/local/bin/perl

=head1 shutdown-system.pl

Shuts down one or more managed systems

Shuts down the specified systems, as long as their virtualization type
supports it. For virtual machines, Cloudmin will wait until they are completely
shut down before this command exists, while for real systems it just runs the
shutdown command, which merely starts the power-off process in the background.

Some virtualization types (like Xen) support a forced shutdown mode, which
immediately terminates the instance. To use this, add the C<--force> flag
to the command line.

=head1 Example usage

  cloudmin shutdown-system --host xencentos.home
  Shutting down Xen system xencentos.home ..
  .. shutdown successfull

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
$0 = "$pwd/shutdown-system.pl";
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
	elsif ($a eq "--force") { $force = 1; }
	elsif ($a eq "--help") { &usage(); }
	else {
		&usage();
		}
	}

# Get the systems
@servers = &find_managed_servers(0, \@hosts, \@groups, \@managers, \@types, \@owners, \@statuses, \@hostons);
@servers = sort { $a->{'host'} cmp $b->{'host'} } @servers;
@servers || &usage("No systems specified");
&can_action_usage(\@servers, "shutdown"); 

# Check if any cannot be shutdown
foreach $s (@servers) {
	$sfunc = "type_".$s->{'manager'}."_no_shutdown";
	if (defined(&$sfunc) && &$sfunc($server) ||
	    $s->{'status'} eq 'down' || $s->{'status'} eq 'nohost') {
		push(@cannot, $s);
		}
	}
@cannot && &usage("The following systems cannot be shut down : ".
		  join(" ", map { $_->{'host'} } @cannot));

# Do it!
&obtain_lock_server(\@servers);
foreach $s (@servers) {
	$tfunc = "type_".$s->{'manager'}."_desc";
	$tdesc = &$tfunc();
	print "Shutting down $tdesc system $s->{'host'} ..\n";
	$err = &shutdown_server($s, $force);
	if ($err) {
		$err = &html_tags_to_text($err);
		print ".. shutdown failed : $err\n\n";
		}
	else {
		print ".. shutdown successfull\n\n";
		}

	print "Refreshing status of $s->{'host'} ..\n";
	&check_server_status($s, 0, 1);
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
print "Shuts down one or more managed systems.\n";
print "\n";
print "cloudmin shutdown-system [--host name]*\n";
print "                         [--group name]*\n";
my $types = join("|", @server_management_types);
print "                         [--type $types]*\n";
print "                         [--os oscode]*\n";
print "                         [--owner name]*\n";
print "                         [--status status-code|\"up\"|\"wm\"|\"bad\"]\n";
print "                         [--host-on name]\n";
print "                         [--force]\n";
exit(1);
}

