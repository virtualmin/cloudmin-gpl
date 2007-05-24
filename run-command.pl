#!/usr/local/bin/perl
# Run some shell command on multiple systems in parallel

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
	local $a = shift(@ARGV);
	if ($a eq "--all-hosts") { $all = 1; }
	elsif ($a eq "--host") { push(@hosts, shift(@ARGV)); }
	elsif ($a eq "--group") { push(@groups, shift(@ARGV)); }
	elsif ($a eq "--os") { push(@types, shift(@ARGV)); }
	elsif ($a eq "--type") { push(@managers, shift(@ARGV)); }
	else {
		push(@cmd, $a);
		}
	}

# Work out who to refresh
@servers = &find_managed_servers($all, \@hosts, \@groups, \@managers, \@types);
@servers || &usage("No systems specified");

# Build the command
#$cmd = join(" ", map { quotemeta($_) } @cmd);
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
		sub { local ($out, $ex, $err) =
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
print "usage: run-command.pl [--all-hosts] | [--host name]*\n";
print "                      [--group name]*\n";
local $types = join("|", @server_management_types);
print "                      [--type $types]*\n";
print "                      [--os oscode]*\n";
print "                      command arg ...\n";
exit(1);
}

