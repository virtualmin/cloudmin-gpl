#!/usr/local/bin/perl

=head1 login-system.pl

Open the console of some virtual system

When run, this command immediately connects you to the console of the specified
system. This allows you to login and run commands even if networking is down,
although for some system types the C<root> password may be needed. It can also
be used to diagnose boot-time problems.

=head1 Example usage

  cloudmin login-system --host xennoupdate.home
  Login: root
  Password: ****

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
$0 = "$pwd/login-system.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";
&set_all_text_print();
@OLDARGV = @ARGV;
$ENV{'VIRTUALMIN_REMOTE_API'} &&
	&usage("This cannot cannot be called from the remote API");

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
$host || &usage("No system to open the console for specified");
$server = &get_managed_server_by("host", $host);
$server || &usage("No system with hostname $host exists");

# Check if the console is available
$clfunc = "type_".$server->{'manager'}."_supports_console_login";
if (!defined(&$clfunc) || !&$clfunc($server)) {
	&usage("This system does not support console logins");
	}

# SSH to the host system, and run the console command
$cfunc = "type_".$server->{'manager'}."_console_command";
$cmd = &$cfunc($server);
$vhost = &get_parent_server($server);
($out, $ex, $err, $status, $fh, $fpid) =
	&execute_command_on_server($vhost, $cmd, 0, 1);
if ($err) {
	&usage("Failed to connect to console : $err");
	}
elsif ($ex) {
	&usage("Failed to connect to console : $out");
	}
print "Connected to console of $server->{'host'} ..\n\n";
&forward_console_data($fh);
print "Console connection closed\n";
&cloudmin_api_log(\@OLDARGV);

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Opens the console of a managed system.\n";
print "\n";
print "cloudmin login-system --host name\n";
exit(1);
}

