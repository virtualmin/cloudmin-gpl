#!/usr/local/bin/perl

=head1 system-system.pl

Open a root shell on some virtual system.

When run, this command immediately connects you to a shell logged in as root
on the specified system. Depending on the system type, this may be via SSH
or via direct access to the console.

=head1 Example usage

  cloudmin shell-system --host xencentos.home
  -bash-3.1# pwd
  /root

=cut

package server_manager;
$main::no_acl_check++;
$ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
$ENV{'WEBMIN_VAR'} ||= "/var/webmin";
if ($0 =~ /^(.*\/)[^\/]+$/) {
	chdir($1);
	}
chop($pwd = `pwd`);
$0 = "$pwd/shell-system.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";
&set_all_text_print();
@OLDARGV = @ARGV;

# Parse command line
while(@ARGV > 0) {
	my $a = shift(@ARGV);
	if ($a eq "--host") {
		$host = shift(@ARGV);
		}
	else {
		&usage();
		}
	}

# Get the systems
$host || &usage("No system to open a shell for specified");
$server = &get_managed_server_by("host", $host);
$server || &usage("No system with hostname $host exists");

# Call the type-specific function to open a shell
$sfunc = "type_".$server->{'manager'}."_open_shell";
($err, $fh) = &$sfunc($server);
if ($err) {
	&usage("Failed to open shell : $err");
	}
print "Opened shell on $server->{'host'} ..\n\n";
&forward_console_data($fh);
print "Shell login closed\n";
&cloudmin_api_log(\@OLDARGV);

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Opens a root shell on a managed system.\n";
print "\n";
print "cloudmin shell-system --host name\n";
exit(1);
}

