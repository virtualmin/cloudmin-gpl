#!/usr/local/bin/perl

=head1 modify-owner.pl

Updates a VM2 system owner

This command changes the details or permissions of a VM2 system owner account.
The account to modify is specified by the C<--name> parameter, and a new login,
real name, email address or password can be set with the C<--newname>, 
C<--real>, C<--email> or C<--pass> flags respectively.

To temporarily lock the account, use the C<--lock> flag. To reverse the lock,
use C<--unlock>.

To add a system to the list of those managed by this account, use the
C<--add-host> flag followed by a hostname known to VM2. Or to take away a
system, use C<--remove-host> followed by a hostname.

The C<--can-*> and C<--cannot-*> families of flags can be used to grant or
remove permissions on the hosts this account owners. For a full list, see
the documentation for the C<create-owner.pl> command.

=head1 Example usage

  ./modify-owner.pl --name freeman --add-host xenblah.home --can-run 
  Updated VM2 system owner freeman

=cut

package server_manager;
$main::no_acl_check++;
$ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
$ENV{'WEBMIN_VAR'} ||= "/var/webmin";
if ($0 =~ /^(.*\/)[^\/]+$/) {
	chdir($1);
	}
chop($pwd = `pwd`);
$0 = "$pwd/modify-owner.pl";
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
	elsif ($a eq "--newname") {
		$newname = shift(@ARGV);
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
	elsif ($a eq "--unlock") {
		$lock = 0;
		}
	elsif ($a eq "--add-host") {
		push(@addhosts, shift(@ARGV));
		}
	elsif ($a eq "--remove-host") {
		push(@remhosts, shift(@ARGV));
		}
	elsif ($a =~ /^--can-(\S+)$/ && &indexof($1, @allactions) >= 0) {
		push(@addactions, $1);
		}
	elsif ($a =~ /^--cannot-(\S+)$/ && &indexof($1, @allactions) >= 0) {
		push(@remactions, $1);
		}
	else {
		&usage();
		}
	}

# Validate parameters
$name || &usage("Missing --name parameter");
($owner) = grep { $_->{'name'} eq $name } &list_system_owners();
$owner || &usage("No system owner named $name exists");
if (defined($newname)) {
	$newname =~ /^[a-z0-9\.\-\_]+$/i ||
		&usage("Invalid new system owner login");
	($clash) = grep { $_->{'name'} eq $newname } &acl::list_users();
	$clash && &usage("A user named $newname already exists");
	}
$oldowner = { %$owner };

# Update the user
if (defined($newname)) {
	$owner->{'name'} = $newname;
	}
if (defined($real)) {
	$owner->{'real'} = $real;
	}
if (defined($email)) {
	$owner->{'acl'}->{'email'} = $email;
	}
if (defined($pass)) {
	$oldlock = $owner->{'pass'} =~ /^\!/ ? "!" : "";
	$owner->{'pass'} = $oldlock.&acl::encrypt_password($pass);
	}
if (defined($lock)) {
	$owner->{'pass'} =~ s/^\!//;
	$owner->{'pass'} = "!".$owner->{'pass'} if ($lock);
	}

# Update owned systems
%allservers = map { $_->{'host'}, $_ } &list_managed_servers();
@ids = split(/\s+/, $owner->{'acl'}->{'servers'});
foreach $n (@addhosts) {
	$s = $allservers{$n};
	$s || &usage("No system named $n exists");
	push(@ids, $s->{'id'});
	}
foreach $n (@remhosts) {
	$s = $allservers{$n};
	$s || &usage("No system named $n exists");
	@ids = grep { $_ ne $s->{'id'} } @ids;
	}
$owner->{'acl'}->{'servers'} = join(" ", &unique(@ids));

# Update allowed actions
@actions = split(/\s+/, $owner->{'acl'}->{'actions'});
push(@actions, @addactions);
foreach $a (@remactions) {
	@actions = grep { $_ ne $a } @actions;
	}
$owner->{'acl'}->{'actions'} = join(" ", &unique(@actions));

# Save the owner
&save_system_owner($owner, $oldowner);
print "Updated VM2 system owner $name\n";

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Updates an existing VM2 system owner.\n";
print "\n";
print "usage: modify-owner.pl --name username\n";
print "                       [--newname username]\n";
print "                       [--email address\@domain]\n";
print "                       [--pass password]\n";
print "                       [--lock | --unlock]\n";
print "                       [--real \"Real name\"]\n";
print "                       [--add-host hostname]*\n";
print "                       [--remove-host hostname]*\n";
foreach $a (@allactions) {
	print "                       [--can-$a | --cannot-$a]\n";
	}
exit(1);
}

