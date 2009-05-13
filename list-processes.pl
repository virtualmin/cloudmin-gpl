#!/usr/local/bin/perl

=head1 list-processes.pl

List or find running processes on some systems

This command lists all running processes on the systems you select, specified
by the standard optons (C<--host>, C<--type> and so on). Alternately, it can
limit output to processes matching some pattern specified with the C<--match>
flag.

=head1 Example usage

  ./list-processes.pl --host xencentos.home --match httpd
  PID      User             Command
  -------- ---------------- ---------------------------------------------------
  926      root             /usr/sbin/httpd
  927      apache           /usr/sbin/httpd
  964      apache           /usr/sbin/httpd
  965      apache           /usr/sbin/httpd

When multiple systems are specified, the output from each is preceeded by the
hostname.

  ./list-processes.pl --host xencentos.home --host suntec.home --match httpd
  xencentos.home:
  PID      User             Command
  -------- ---------------- ---------------------------------------------------
  926      root             /usr/sbin/httpd
  927      apache           /usr/sbin/httpd
  suntec.home:
  PID      User             Command
  -------- ---------------- ---------------------------------------------------
  697      nobody           /usr/apache/bin/httpd
  1223     nobody           /opt/csw/apache2/sbin/httpd -k start

=cut 

package server_manager;
$main::no_acl_check++;
$ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
$ENV{'WEBMIN_VAR'} ||= "/var/webmin";
if ($0 =~ /^(.*\/)[^\/]+$/) {
	chdir($1);
	}
chop($pwd = `pwd`);
$0 = "$pwd/list-processes.pl";
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
	elsif ($a eq "--match") { $match = shift(@ARGV); }
	else { &usage(); }
	}

# Work out who to refresh
@servers = &find_managed_servers($all, \@hosts, \@groups, \@managers, \@types);
@servers || &usage("No systems specified");

# Do each system in parallel
@rv = &parallel_server_function(\@servers,
	sub { local ($server) = @_;
	      $procs = &list_processes_on_server($server);
	      if (ref($procs) && defined($match)) {
		$procs = [ grep { $_->{'args'} =~ /$match/i } @$procs ];
	      }
              return $procs;
	    });

# Show the results
$fmt = "%-8.8s %-16.16s %-54.54s\n";
for($i=0; $i<@servers; $i++) {
	$procs = $rv[$i]->[0];
	next if (ref($procs) && !@$procs && defined($match));
	if (@servers > 1) {
		print $servers[$i]->{'host'},":\n";
		}
	if (ref($procs)) {
		printf $fmt, "PID", "User", "Command";
		printf $fmt, ("-" x 8), ("-" x 16), ("-" x 54);
		foreach $p (@$procs) {
			printf $fmt, $p->{'pid'}, $p->{'user'}, $p->{'args'};
			}
		}
	else {
		print "ERROR: $procs\n";
		}
	}

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Lists or finds processes on some or all managed systems.\n";
print "\n";
print "cloudmin list-processes [--all-hosts] | [--host name]*\n";
print "                        [--group name]*\n";
local $types = join("|", @server_management_types);
print "                        [--type $types]*\n";
print "                        [--os oscode]*\n";
print "                        [--match regexp]\n";
exit(1);
}

