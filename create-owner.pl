#!/usr/local/bin/perl
# Create a new VM2 system owner

package server_manager;
$main::no_acl_check++;
$ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
$ENV{'WEBMIN_VAR'} ||= "/var/webmin";
if ($0 =~ /^(.*\/)[^\/]+$/) {
	chdir($1);
	}
chop($pwd = `pwd`);
$0 = "$pwd/create-owner.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";
&foreign_require("acl", "acl-lib.pl");

# Parse command line
@allactions = &list_owner_actions();
while(@ARGV > 0) {
	local $a = shift(@ARGV);
	if ($a eq "--name") {
		$name = shift(@ARGV);
		}
	elsif ($a eq "--real") {
		$real = shift(@ARGV);
		}
	elsif ($a eq "--email") {
		$email = shift(@ARGV);
		}
	elsif ($a eq "--pass") {
		$pass = shift(@ARGV);
		}
	elsif ($a eq "--lock") {
		$lock = 1;
		}
	elsif ($a eq "--host") {
		push(@hosts, shift(@ARGV));
		}
	elsif ($a =~ /^--can-(\S+)$/ && &indexof($1, @allactions) >= 0) {
		push(@actions, $1);
		}
	else {
		&usage();
		}
	}

# Validate parameters
$name || &usage("Missing --name parameter");
$email || &usage("Missing --email parameter");
$pass || &usage("Missing --pass parameter");
%allservers = map { $_->{'host'}, $_ } &list_managed_servers();
foreach $n (@hosts) {
	$s = $allservers{$n};
	$s || &usage("No system named $n exists");
	push(@ids, $s->{'id'});
	}
$name =~ /^[a-z0-9\.\-\_]+$/i || &usage("Invalid system owner login");
($clash) = grep { $_->{'name'} eq $name } &acl::list_users();
$clash && &usage("A user named $name already exists");

# Create the user
$owner = { 'name' => $name,
	   'pass' => &acl::encrypt_password($pass),
	   'real' => $real,
	   'acl' => { 'email' => $email,
		      'servers' => join(" ", @ids),
		      'actions' => join(" ", @actions),
		    },
	 };
if ($lock) {
	$owner->{'pass'} = "!".$owner->{'pass'};
	}
&save_system_owner($owner);
print "Created VM2 system owner $name\n";

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Creates a new VM2 system owner.\n";
print "\n";
print "usage: create-owner.pl --name username\n";
print "                       --email address\@domain\n";
print "                       --pass password\n";
print "                       [--lock]\n";
print "                       [--real \"Real name\"]\n";
print "                       [--host hostname]*\n";
foreach $a (@allactions) {
	print "                       [--can-$a]\n";
	}
exit(1);
}

