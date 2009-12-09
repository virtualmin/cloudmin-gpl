#!/usr/local/bin/perl

=head1 find-systems.pl

Scan a hosting system for virtual instances already running on it

If you have added to Cloudmin a host system that has manually created Xen
instances or OpenVZ containers
which are not yet under Cloudmin's control, this command can be used to find and
automatically add them. The system to scan must be specified with the
C<--host> parameter, and if hosts more than one type of virtual system, the
type to search for must be specified with the C<--type> flag.

If the C<--same-login> flag is given, Cloudmin will use the same SSH and Webmin
username and password to login to any discovered systems as it currently uses
for the host system. Alternately, you can select a different SSH password
with C<--ssh-pass> followed by a password, or C<--ssh-key> followed by a
key ID. The SSH username, protocol version and port can be changed from their
defaults with the C<--ssh-user>, C<--ssh-protocol> and C<--ssh-port> flags.
Finally, to prevent SSH logins altogether, the C<--ssh-nologin> flag can be
given instead.

If Cloudmin is to login to Webmin or Virtualmin on the discovered systems, the
C<--webmin-user> and C<--webmin-pass> flags must be given, followed by a
username and password respectively. Alternately, you can use the
C<--webmin-same> flag to use the same credentials as for SSH access.
The port for Webmin can be changed from the default of 10000 with the
C<--webmin-port> flag, and SSL access can be enabled with C<--webmin-ssh>.

By default, Cloudmin will find all virtual systems on the host, regardless of
whether they are currently running or not. To limit the search to instances
that are active, add the C<--running-only> flag to the command line.

=head1 Example usage

  cloudmin find-systems --host xenhost --ssh-nologin --running-only
  Finding Xen configuration files under /etc/xen, /xen ..
  .. found 3 files

  Finding running Xen instances ..
  .. found 2 instances

  Processing Xen configuration file /xen/centos64gpl.cfg
  .. instance centos64gpl is not currently running

  Processing Xen configuration file /xen/virtualmin-demo.cfg
  .. added system 10.20.144.132 with status Down

  Processing Xen configuration file /xen/webmin-demo.cfg
  .. added system 10.20.144.133 with status Down

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
$0 = "$pwd/find-systems.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";
&set_all_text_print();
@OLDARGV = @ARGV;

# Parse command line
$ssh_user = 'root';
$ssh_protocol = 2;
$webmin_ssl = 0;
$webmin_port = 10000;
while(@ARGV > 0) {
	my $a = shift(@ARGV);
	if ($a eq "--host") {
		$host = shift(@ARGV);
		}
	elsif ($a eq "--type") {
		$type = shift(@ARGV);
		}
	elsif ($a eq "--running-only") {
		$running = 1;
		}
	elsif ($a eq "--same-login") {
		$samelogin = 1;
		}
	elsif ($a eq "--ssh-user") {
		$ssh_user = shift(@ARGV);
		}
	elsif ($a eq "--ssh-key") {
		$ssh_key = shift(@ARGV);
		($key) = grep { $_->{'id'} eq $ssh_key } @keys;
		$key || &usage("No SSH key with ID $ssh_key found");
		}
	elsif ($a eq "--ssh-pass") {
		$ssh_pass = shift(@ARGV);
		}
	elsif ($a eq "--ssh-protocol") {
		$ssh_protocol = shift(@ARGV);
		$ssh_protocol =~ /^[1-9]$/ ||
			&usage("SSH protocol must be a number");
		}
	elsif ($a eq "--ssh-nologin") {
		$ssh_nologin = 1;
		}
	elsif ($a eq "--webmin-same") {
		$webmin_same = 1;
		}
	elsif ($a eq "--webmin-user") {
		$webmin_user = shift(@ARGV);
		}
	elsif ($a eq "--webmin-pass") {
		$webmin_pass = shift(@ARGV);
		}
	elsif ($a eq "--webmin-ssl") {
		$webmin_ssl = 1;
		}
	elsif ($a eq "--webmin-port") {
		$webmin_port = shift(@ARGV);
		}
	else {
		&usage("Unknown flag $a");
		}
	}
@keys = &list_ssh_keys();

# Check for mandatory args
$host || &usage("Missing --host parameter");
$samelogin || $ssh_key || $ssh_pass || $ssh_nologin ||
	&usage("If --same-login is not given, you must specify an SSH password or key");

# Get the vhost
$vhost = &get_managed_server_by("host", $host);
$vhost || &usage("No system named $host was found");

# Guess the hosting type if not given
@types = &is_parent_server($vhost);
if (!$type) {
	@types || &usage("The system $host cannot host any virtual systems");
	@types == 1 || &usage("The system $host is registered to host more ".
			      "than one virtual system type - you must supply ".
			      "the --type parameter");
	$type = $types[0];
	}

# Validate the type
&indexof($type, @types) >= 0 ||
    &usage("The system $host does not support for $type virtual system type");

# Create the template object
$tmplserver = { 'manager' => $type };
if ($samelogin) {
	&copy_ssh_login_details($vhost, $tmplserver);
        &copy_webmin_login_details($vhost, $tmplserver);
	}
else {
	# Set SSH login fields
	$tmplserver->{'ssh_user'} = $ssh_user;
	$tmplserver->{'ssh_port'} = $ssh_port if ($ssh_port);
	$tmplserver->{'ssh_protocol'} = $ssh_protocol;
	if ($ssh_nologin) {
		$tmplserver->{'ssh_nologin'} = 1;
		}
	elsif ($ssh_pass) {
		$tmplserver->{'ssh_pass'} = $ssh_pass;
		}
	else {
		$tmplserver->{'key'} = $key->{'id'};
		}

	# Set Webmin login fields
	$tmplserver->{'ssl'} = $webmin_ssl;
	$tmplserver->{'port'} = $webmin_port;
	if ($webmin_same) {
		$tmplserver->{'user'} = $tmplserver->{'ssh_user'};
		$tmplserver->{'ssh_pass'} ||
			&usage("The --webmin-same flag cannot be given unless ".
			       "an SSH password is specified with --ssh-pass");
		$tmplserver->{'pass'} = $tmplserver->{'ssh_pass'};
		}
	elsif ($webmin_user) {
		$tmplserver->{'user'} = $webmin_user;
		$tmplserver->{'pass'} = $webmin_pass;
		}
	}

# Do it!
$ffunc = "type_".$type."_find_servers";
&$ffunc($vhost, $tmplserver, $running);
&cloudmin_api_log(\@OLDARGV);

sub usage
{
@crtypes = grep { $ffunc = "type_".$_."_find_servers"; defined(&$ffunc) }
		@server_management_types;
$crtypes = join("|", @crtypes);
print "$_[0]\n\n" if ($_[0]);
print "Searches a host system for existing virtual systems of some type.\n";
print "\n";
print "cloudmin find-systems --host name\n";
print "                     [--type $crtypes]\n";
print "                     [--running-only]\n";
print "                     [--same-login]\n";
print "                     [--ssh-key id | --ssh-pass password |\n";
print "                      --ssh-nologin]\n";
print "                     [--ssh-user username]\n";
print "                     [--ssh-port number]\n";
print "                     [--ssh-protocol number]\n";
print "                     [--webmin-same | --webmin-user username\n";
print "                                      --webmin-pass password]\n";
print "                     [--webmin-ssh]\n";
print "                     [--webmin-port number]\n";
exit(1);
}
