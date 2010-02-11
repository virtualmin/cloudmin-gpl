#!/usr/local/bin/perl

=head1 restore-systems.pl

Restores one or more Cloudmin-managed virtual systems.

XXX

=head1 Example usage

  cloudmin restore-systems --host openvzgpl.home
  XXX

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
$0 = "$pwd/restore-systems.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";
@OLDARGV = @ARGV;
&usage_if_cloudmin_replica();

# Parse command line
while(@ARGV > 0) {
	my $a = shift(@ARGV);
	if ($a eq "--host") { push(@hosts, shift(@ARGV)); }
	elsif ($a eq "--group") { push(@groups, shift(@ARGV)); }
	elsif ($a eq "--os") { push(@types, shift(@ARGV)); }
	elsif ($a eq "--type") { push(@managers, shift(@ARGV)); }
        elsif ($a eq "--owner") { push(@owners, shift(@ARGV)); }
	elsif ($a eq "--source") { $source = shift(@ARGV); }
	elsif ($a eq "--parallel") { $parallel = 1; }
	elsif ($a eq "--quiet") { $quiet = 1; }
	else {
		&usage();
		}
	}

# Validate args
$source || &usage("Missing --source parameter");
$sourcehash = &parse_backup_destination($source);
$sourcehash ||  &usage("Invalid --source specification $source");

# Work out who to restore
@servers = &find_managed_servers(0, \@hosts, \@groups, \@managers, \@types, \@owners);
@servers || &usage("No systems specified");
$backup = { 'dest' => $source,
	    'servers' => join(' ', map { $_->{'id'} } @servers),
	    'parallel' => $parallel };

# Make sure source and dest can be managed by the user
&can_action_usage(\@servers, "backup");
if ($sourcehash->{'mode'} <= 2) {
	foreach $s (@servers) {
		$vhost = &get_parent_server($s);
		$sourceserver = &get_backup_dest_server($sourcehash, $vhost);
		&can_action_usage($sourceserver, "backup");
		}
	}

# Do the restore
if ($quiet) {
	&set_all_null_print();
	}
else {
	&set_all_text_print();
	}
$rv = &execute_restore($backup);

# Show results
foreach $s (@servers) {
	$r = $rv->{$s->{'id'}};
	print $s->{'host'},": ";
	if ($r) {
		if ($r->{'ok'}) {
			print "OK ",&nice_size($r->{'size'});
			}
		else {
			print "FAILED ",$r->{'msg'};
			}
		}
	else {
		print "UNKNOWN";
		}
	print "\n";
	}
&cloudmin_api_log(\@OLDARGV);

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Restores one or more managed systems.\n";
print "\n";
print "cloudmin restore-systems [--host name]*\n";
print "                         [--group name]*\n";
my $types = join("|", @server_management_types);
print "                         [--type $types]*\n";
print "                         [--os oscode]*\n";
print "                         [--owner name]*\n";
print "                         --source source-directory\n";
print "                         [--parallel]\n";
exit(1);
}

