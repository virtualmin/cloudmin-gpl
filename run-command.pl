#!/usr/local/bin/perl

=head1 run-command.pl

Run some shell command on multiple systems in parallel

This is the equivalent of the command shell in the Cloudmin web interface, but
arguably more powerful. It can be used to run a command on one or several
hosts managed by Cloudmin, and display the output from all of them. Systems are
selected by the standard optons (C<--host>, C<--type> and so on), and the
command to run follows the other parameters.

=head1 Example usage

  cloudmin run-command --host xencentos.home "df -h"
  Filesystem            Size  Used Avail Use% Mounted on
  /dev/sda1             2.0G  1.2G  777M  60% /
  none                  257M     0  257M   0% /dev/shm

When multiple systems are specified, the output from each is preceeded by the
hostname.

  ./run-command.pl --host xencentos.home --host suntec.home uname
  xencentos.home: Linux
  suntec.home: SunOS

=cut 

package server_manager;
$main::no_acl_check++;
$ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
$ENV{'WEBMIN_VAR'} ||= "/var/webmin";
if ($0 =~ /^(.*\/)[^\/]+$/) {
	chdir($1);
	}
chop($pwd = `pwd`);
$0 = "$pwd/run-command.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";

# Parse command line
while(@ARGV > 0) {
	my $a = shift(@ARGV);
	if ($a eq "--all-hosts") { $all = 1; }
	elsif ($a eq "--host") { push(@hosts, shift(@ARGV)); }
	elsif ($a eq "--group") { push(@groups, shift(@ARGV)); }
	elsif ($a eq "--os") { push(@types, shift(@ARGV)); }
	elsif ($a eq "--type") { push(@managers, shift(@ARGV)); }
        elsif ($a eq "--owner") { push(@owners, shift(@ARGV)); }
	elsif ($a eq "--help") { &usage(); }
	else {
		push(@cmd, $a);
		}
	}

# Work out who to run on
@servers = &find_managed_servers($all, \@hosts, \@groups, \@managers, \@types, \@owners);
@servers || &usage("No systems specified");

# Build the command
$cmd = join(" ", @cmd);
$cmd || &usage("No command to run given");

if (@servers == 1) {
	# Just do one
	($out, $ex, $err) = &execute_command_on_server($servers[0], $cmd);
	if ($err) {
		print "ERROR: $err\n";
		exit(255);
		}
	else {
		print $out;
		exit($ex);
		}
	}
else {
	# Do multiple in parallel
	&parallel_server_function(\@servers,
		sub { my ($out, $ex, $err) =
			&execute_command_on_server($_[0], $cmd);
		      if ($err) {
		          print "$_[0]->{'host'}: ERROR: $err\n";
			  return 255;
		      } else {
			  print "$_[0]->{'host'}: $out";
			  print "\n" if ($out !~ /\n$/);
			  return $ex;
                      }
	            });
	}

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Runs a shell command on some or all managed systems.\n";
print "\n";
print "cloudmin run-command [--all-hosts] | [--host name]*\n";
print "                     [--group name]*\n";
my $types = join("|", @server_management_types);
print "                     [--type $types]*\n";
print "                     [--os oscode]*\n";
print "                     [--owner name]*\n";
print "                     command arg ...\n";
exit(1);
}

