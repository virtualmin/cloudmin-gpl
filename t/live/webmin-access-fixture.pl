#!/usr/bin/perl
# Create test server entries without contacting a guest.
use strict;
use warnings;
use FindBin qw($Bin);
use Cwd qw(abs_path);
BEGIN {
	# Run native account and record changes only from a root test shell.
	die "Run on a Linux test host as root\n" unless $^O eq 'linux' && $< == 0;
	die "Run from a root shell, not HTTP\n"
		if ($ENV{'GATEWAY_INTERFACE'} || $ENV{'REQUEST_METHOD'});
	$ENV{'WEBMIN_CONFIG'} = '/etc/webmin';
	$ENV{'WEBMIN_VAR'} = '/var/webmin';
	$ENV{'REMOTE_USER'} = 'root';
	# Load the installed Webmin tree containing this fixture module.
	my $root = abs_path("$Bin/../../..");
	chdir($root) or die $!;
	unshift(@INC, $root);
	$0 = "$root/cloudmin-ui-check.pl";
}
use WebminCore;
init_config();
foreign_require('servers', 'servers-lib.pl');
my ($action, $user, $id) = @ARGV;
# Reject arbitrary account names or record paths before touching Servers Index.
die "Invalid fixture identity\n" unless ($user || '') =~ /\Acloudmin-frame-check-[a-f0-9]{8}\z/
	&& ($id || '') =~ /\A[0-9]{12,20}\z/;
# Both records have unique IDs and an ownership marker checked before cleanup.
my @ids = ($id, $id + 1);
if ($action eq 'create') {
	# Refuse IDs that collide with existing records.
	die "Fixture ID already exists\n" if grep { servers::get_server($_) } @ids;
	servers::save_server({id => $ids[0], host => "$user.guest.test", cloudmin_uuid => $user,
		autouser => 1, port => 10000, cloudmin_test_owner => $user});
	servers::save_server({id => $ids[1], host => "$user.manual.test", desc => 'Synthetic server',
		user => 'fixture', pass => 'synthetic-secret', port => 10000, cloudmin_test_owner => $user});
}
elsif ($action eq 'restrict') {
	# Avoid returning unrelated real records while checking JSON redaction.
	save_module_acl({edit => 1, add => 1, links => 1, servers => $ids[1]}, $user, 'servers');
}
elsif ($action eq 'check' || $action eq 'delete') {
	# Verify record ownership after a denied delete and before cleanup.
	foreach my $entry (@ids) {
		my $server = servers::get_server($entry);
		die "Fixture missing or ownership changed\n" if !$server ||
			($server->{'cloudmin_test_owner'} || '') ne $user;
		# The post-denial check must leave records intact.
		servers::delete_server($entry) if $action eq 'delete';
	}
}
else {
	# Unknown actions must not fall through to a mutation.
	die "Unknown fixture action\n";
}
