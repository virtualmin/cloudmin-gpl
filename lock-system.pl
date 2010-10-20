#!/usr/local/bin/perl

=head1 lock-systemwd.pl

Locks the root password for some or all virtual systems using SSH keys.

This command locks the root password for some or all virtual systems
that Cloudmin is using an SSH key to login to. This will prevent password-based
SSH logins, while still allowing access via any SSH keys that have been setup.

It can be used if you have created virtual systems from an image without
setting a password, in which case the default password may still be set.
This is a potential security risk, so the root password should be locked on
any such systems, unless it has already been changed manually.

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
$0 = "$pwd/lock-systemwd.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";
@OLDARGV = @ARGV;
&usage_if_cloudmin_replica();

# Parse command line
@keys = &list_ssh_keys();
while(@ARGV > 0) {
	my $a = shift(@ARGV);
	if ($a eq "--host") { push(@hosts, shift(@ARGV)); }
	elsif ($a eq "--group") { push(@groups, shift(@ARGV)); }
	elsif ($a eq "--os") { push(@types, shift(@ARGV)); }
	elsif ($a eq "--type") { push(@managers, shift(@ARGV)); }
        elsif ($a eq "--owner") { push(@owners, shift(@ARGV)); }
        elsif ($a eq "--host-on") { push(@hostons, shift(@ARGV)); }
        elsif ($a eq "--status") { push(@statuses, shift(@ARGV)); }
	elsif ($a eq "--all-hosts") { $all = 1; }
	else {
		&usage();
		}
	}

# Find systems
@servers = &find_managed_servers($all, \@hosts, \@groups, \@managers, \@types, \@owners, \@statuses, \@hostons);
@servers = grep { $_->{'key'} && &get_parent_server($_) } @servers;
@servers || &usage("No virtual systems with SSH keys selected");
&can_action_usage(\@servers, "pass"); 

# Do each one
&obtain_lock_server(\@servers);
foreach $s (@servers) {
	print "Locking root password on $s->{'host'} ..\n";
	$err = &set_shadow_root_password($s, undef);
	if ($err) {
		print ".. failed : $err\n";
		}
	else {
		print ".. done\n";
		}

	print "Refreshing status of $s->{'host'} ..\n";
	&check_server_status($s, 0, 1);
	&refresh_server_usage($s);
	&save_managed_server($s);
	$desc = $text{'status_'.$s->{'status'}};
	print ".. new status is : $s->{'status'} ($desc)\n\n";
	}
&release_lock_server(\@servers);
&cloudmin_api_log(\@OLDARGV);

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Locks the root password for some or all virtual systems using SSH keys\n";
print "\n";
print "cloudmin lock-system [--all-hosts]\n";
print "                     [--host name]*\n";
print "                     [--group name]*\n";
my $types = join("|", @server_management_types);
print "                     [--type $types]*\n";
print "                     [--os oscode]*\n";
print "                     [--owner name]*\n";
print "                     [--status status-code|\"up\"|\"wm\"|\"bad\"]\n";
print "                     [--host-on name]\n";
exit(1);
}

