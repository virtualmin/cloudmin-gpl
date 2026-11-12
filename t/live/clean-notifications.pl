#!/usr/bin/perl
# clean-notifications.pl module-root removes only the
# supplied fixture test event.
use strict;
use warnings;
# Run only as root from a shell.
die "Run from a root Linux test shell\n" unless $^O eq 'linux' && $< == 0 &&
	!$ENV{GATEWAY_INTERFACE};
my ($module) = @ARGV;
die "Pass the installed module path\n" unless $module && -d $module;
# Load the installed module to reach its notification store.
$ENV{WEBMIN_CONFIG} = '/etc/webmin';
$ENV{WEBMIN_VAR} = '/var/webmin';
$ENV{REMOTE_USER} = 'root';
chdir($module) or die $!;
$0 = "$module/notification-fixture.pl";
require './server-manager-lib.pl';
# Read only the event and target supplied by this fixture run.
local $/;
my $data = WebminCore::convert_from_json(<STDIN>);
die "Invalid fixture event\n" unless ($data->{event} || '') =~ /^\d+$/ &&
	($data->{target} || '') =~ /^[a-f0-9]{32}$/;
# cleanup(db) verifies event ownership before deleting it and its receipts.
get_notifications()->transaction(sub {
	my ($db) = @_;
	my ($json) = $db->selectrow_array('SELECT record FROM events WHERE id = ?',
		undef, $data->{event});
	# A missing event needs no cleanup.
	return unless $json;
	my $event = Cloudmin::Notifications::decode($json);
	die "Not a test event\n" unless $event->{metric} eq 'test' &&
		$event->{phase} eq 'test' && $event->{owner} eq 'host';
	# Match a receipt as well as the host-only test
	# event before removing it.
	my ($matching) = $db->selectrow_array(
		'SELECT count(*) FROM deliveries WHERE event = ? AND target = ?',
		undef, $data->{event}, $data->{target});
	die "Test target does not match\n" unless $matching;
	$db->do('DELETE FROM events WHERE id = ?', undef, $data->{event});
	});
