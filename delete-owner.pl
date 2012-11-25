#!/usr/local/bin/perl

=head1 delete-owner.pl

Delete an existing Cloudmin system owner

This command deletes a single owner account, identified with the C<--name>
parameter. No confirmation is requested, but none of the systems he owns
are effected unless you also supply the C<--delete-systems> flag or unless
deletion of all systems has been enabled in the Cloudmin configuration.
Alternately, the flag C<--no-delete-systems> can be used to prevent removal
of any virtual systems belonging to this owner.

=head1 Example usage

  cloudmin delete-owner --name freeman
  Deleted Cloudmin system owner freeman

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
$0 = "$pwd/create-owner.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";
@OLDARGV = @ARGV;
&usage_if_cloudmin_replica();
&can_action_usage(undef, "global");

# Parse command line
$deletesystems = $config{'owner_delete'};
while(@ARGV > 0) {
	my $a = shift(@ARGV);
	if ($a eq "--name") {
		$name = shift(@ARGV);
		}
	elsif ($a eq "--multiline") {
		$multiline = 1;
		}
	elsif ($a eq "--delete-systems") {
		$deletesystems = 1;
		}
	elsif ($a eq "--no-delete-systems") {
		$deletesystems = 0;
		}
	else {
		&usage("Unknown parameter $a");
		}
	}

# Get the owner
$name || &usage("Missing --name parameter");
($owner) = grep { $_->{'name'} eq $name } &list_system_owners();
$owner || &usage("No system owner named $name exists");

# Find his systems
@oservers = ( );
foreach my $sid (split(/\s+/, $owner->{'acl'}->{'servers'})) {
	my $server = &get_managed_server($sid);
	push(@oservers, $server) if ($server);
	}

if ($deletesystems) {
	# Delete his systems
	foreach my $s (@oservers) {
		&obtain_lock_server($s);
		$tfunc = "type_".$s->{'manager'}."_desc";
		$tdesc = &$tfunc();

		# Run pre-deletion script
		&run_system_script($s, 'before', 'delete') || next;

		&delete_all_domains($s);

		print "Deleting $tdesc system $s->{'host'} ..\n";
		$dfunc = "type_".$s->{'manager'}."_delete";
		$err = &$dfunc($s, 0);
		if ($err) {
			print ".. deletion failed : $err\n\n";
			}
		else {
			&clear_ssh_host_key($s);
			&delete_managed_server($s, 0);
			print ".. deleted successfully\n\n";

			# Run post-deletion script
			&run_system_script($s, 'after', 'delete');
			}
		&release_lock_server($s);
		}
	}

# Delete him
&delete_system_owner($owner);
print "Deleted Cloudmin system owner $name\n";

&cloudmin_api_log(\@OLDARGV);

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Deletes an existing Cloudmin system owner.\n";
print "\n";
print "cloudmin delete-owner --name username\n";
print "                     [--delete-systems] | [--no-delete-systems]\n";
exit(1);
}

