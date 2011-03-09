#!/usr/local/bin/perl

=head1 wait-ssh-system.pl

Waits until one or more systems can be contacted via SSH.

This command will wait until the specified systems can be contacted via SSH,
and only completes when this is true or the timeout set with the C<--timeout>
flag expires. The systems to wait on can be set with the standard flags like
C<--host> , C<--group> and C<--type>.

=head1 Example usage

  cloudmin wait-ssh-systems --host xenrails.home --host smeg.com --timeout 5
  xenrails.home: OK
  smeg.com: TIMEOUT

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
$0 = "$pwd/wait-ssh-system.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";
@OLDARGV = @ARGV;
&usage_if_cloudmin_replica();

# Parse command line
while(@ARGV > 0) {
	my $a = shift(@ARGV);
	if ($a eq "--all-hosts") { $all = 1; }
	elsif ($a eq "--host") { push(@hosts, shift(@ARGV)); }
	elsif ($a eq "--group") { push(@groups, shift(@ARGV)); }
	elsif ($a eq "--os") { push(@types, shift(@ARGV)); }
	elsif ($a eq "--type") { push(@managers, shift(@ARGV)); }
        elsif ($a eq "--owner") { push(@owners, shift(@ARGV)); }
        elsif ($a eq "--host-on") { push(@hostons, shift(@ARGV)); }
        elsif ($a eq "--status") { push(@statuses, shift(@ARGV)); }
	elsif ($a eq "--timeout") { $timeout = shift(@ARGV); }
	else {
		&usage();
		}
	}

# Work out who to refresh
@servers = &find_managed_servers($all, \@hosts, \@groups, \@managers, \@types, \@owners, \@statuses, \@hostons);
@servers || &usage("No systems specified");
&can_action_usage(\@servers, "run"); 

# Do the parallel refresh and print
$start = time();
if ($timeout) {
	print "Waiting for SSH to ",scalar(@servers)," systems for $timeout seconds ..\n";
	}
else {
	print "Waiting for SSH to ",scalar(@servers)," systems ..\n";
	$timeout = 99999999;
	}
%okmap = map { $_->{'id'}, 0 } @servers;
while(time() - $start < $timeout) {
	$left = 0;
	foreach $s (grep { !$okmap{$_->{'id'}} } @servers) {
		$ok = &wait_for_ssh($s, 1);
		if ($ok) {
			print "$s->{'host'}: OK\n";
			$okmap{$s->{'id'}} = 1;
			}
		else {
			$left++;
			}
		}
	last if (!$left);
	}
$fail = 0;
foreach $s (grep { !$okmap{$_->{'id'}} } @servers) {
	print "$s->{'host'}: TIMEOUT\n";
	$fail++;
	}
&cloudmin_api_log(\@OLDARGV);
exit($fail);

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Waits until one or more systems can be contacted via SSH.\n";
print "\n";
print "cloudmin refresh-systems [--all-hosts] | [--host name]*\n";
print "                         [--group name]*\n";
my $types = join("|", @server_management_types);
print "                         [--type $types]*\n";
print "                         [--os oscode]*\n";
print "                         [--owner name]*\n";
print "                         [--status status-code|\"up\"|\"wm\"|\"bad\"]\n";
print "                         [--host-on name]\n";
print "                         [--timeout number]\n";
exit(1);
}

