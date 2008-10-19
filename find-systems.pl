#!/usr/local/bin/perl

=head1 find-systems.pl

Scan a hosting system for Xen instances already running on it

XXX

=head1 Example usage
  ./find-systems.pl --host xenhost --type xen
  XXX

=cut

package server_manager;
$main::no_acl_check++;
$ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
$ENV{'WEBMIN_VAR'} ||= "/var/webmin";
if ($0 =~ /^(.*\/)[^\/]+$/) {
	chdir($1);
	}
chop($pwd = `pwd`);
$0 = "$pwd/find-systems.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";

# Parse command line
$ssh_user = 'root';
$ssh_protocol = 2;
while(@ARGV > 0) {
	local $a = shift(@ARGV);
	if ($a eq "--host") {
		$host = shift(@ARGV);
		}
	elsif ($a eq "--same-login") {
		$samelogin = 1;
		}
	elsif ($a eq "--running-only") {
		$running = 1;
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
	elsif ($a eq "--webmin") {
		$webmin_mode = 1;
		}
	elsif ($a eq "--webmin-pass") {
		$webmin_pass = shift(@ARGV);
		$webmin_mode = 2;
		}
	elsif ($a eq "--type") {
		$type = shift(@ARGV);
		}
	else {
		&usage();
		}
	}

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
	}

# Do it!
$ffunc = "type_".$type."_find_servers";
&$ffunc($vhost, $tmplserver, $running);

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Searches a host system for existing virtual systems of some type.\n";
print "\n";
print "usage: find-systems.pl --host name\n";
print "                       [--type $crtypes]\n";
print "                       [--running-only]\n";
print "                       [--same-login]\n";
print "                       [--ssh-key id | --ssh-pass password |\n";
print "                        --ssh-nologin]\n";
print "                       [--ssh-user username]\n";
print "                       [--ssh-port number]\n";
print "                       [--ssh-protocol number]\n";
exit(1);
}
