use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use lib "$Bin/../lib";
use Cloudmin::Notifications;
use Test::More;
use File::Temp qw(tempdir);

# Two fixed guest UUIDs show that mutes stay within their own scope.
my $guest = '11111111-1111-4111-8111-111111111111';
my $other = '22222222-2222-4222-8222-222222222222';
# fixture() returns a private store, a guest CPU rule ID and an email
# destination ID. The rule covers all guests and alerts at once at 80 percent
# or more, without reminders.
sub fixture
{
my $store = Cloudmin::Notifications->new(directory => tempdir(CLEANUP => 1));
my $target = $store->save_target({ name => 'Email', type => 'email',
	address => 'fixture@example.invalid' })->{id};
my $rule = $store->save_rule({ name => 'CPU', metric => 'cpu', scope => 'guests',
	threshold => 80, duration => 0, cooldown => 0, reminder => 0,
	targets => [ $target ] }, 0)->{id};
return ($store, $rule, $target);
}
# reading(store, rule, now, value, [owner]) evaluates one running owner's
# reading at Unix time now. owner defaults to the first fixture guest. An undef
# value is an unknown reading.
sub reading
{
my ($store, $rule, $now, $value, $owner) = @_;
$owner ||= $guest;
$store->evaluate({ $rule => [ { owner => $owner, subject => $owner,
	label => 'Guest', running => 1, value => $value } ] }, $now, { });
}

# Mutes have no expiry, and unmuting alerts once for a current problem.
subtest 'Manual mutes persist until explicitly undone' => sub {
	my ($store, $rule, $target) = fixture();
	# A muted guest still records its alert, but the receipt is muted.
	$store->mute($guest, 1, 1000);
	reading($store, $rule, 1000, 95);
	my $h = $store->history($guest);
	is($h->{muted}, 1, 'guest mute is active');
	is($h->{events}[0]{silenced}, 'guest', 'event records the mute reason');
	is($store->history()->{events}[0]{deliveries}[0]{state}, 'muted',
		'receipt never queues');
	ok($h->{states}[0]{active}, 'checks still detect the incident');
	# Reopening the store, pruning and a year passing keep the mute.
	$store = Cloudmin::Notifications->new(directory => $store->{directory});
	my $later = 1000 + 366 * 86400;
	$store->prune($later);
	reading($store, $rule, $later, 95);
	ok($store->history($guest)->{muted}, 'pruning does not expire a manual mute');
	is($store->deliver(sub { die 'unexpected send' }, $later), 0,
		'no delivery after reopening and waiting a year');
	# Unmuting sends one fresh firing alert for the ongoing incident.
	$store->mute($guest, 0, $later + 1);
	reading($store, $rule, $later + 1, 95);
	my @sent;
	$store->deliver(sub { push @sent, $_[1] }, $later + 1);
	is(scalar(@sent), 1, 'ongoing incident alerts after unmute without reminders');
	is($sent[0]{phase}, 'firing', 'fresh firing rather than replay');
	is($sent[0]{created}, $later + 1, 'fresh event timestamp');
	# Later readings do not repeat it, and recovery is reported normally.
	reading($store, $rule, $later + 2, 95);
	$store->deliver(sub { push @sent, $_[1] }, $later + 2);
	is(scalar(@sent), 1, 'unmute fires once');
	reading($store, $rule, $later + 3, 20);
	$store->deliver(sub { push @sent, $_[1] }, $later + 3);
	is($sent[-1]{phase}, 'resolved', 'normal recovery resumes');
	};

# Global and guest mutes start and end separately.
subtest 'Global and guest mutes are independent' => sub {
	my ($store, $rule, $target) = fixture();
	# Add a host rule beside the guest rule.
	my $host = $store->save_rule({ name => 'Host', metric => 'cpu',
		scope => 'host', threshold => 80, duration => 0, cooldown => 0,
		targets => [ $target ] }, 0)->{id};
	# A guest mute leaves the host and the other guest alerting.
	$store->mute($guest, 1, 1000);
	reading($store, $rule, 1000, 95, $guest);
	reading($store, $rule, 1000, 95, $other);
	reading($store, $host, 1000, 95, 'host');
	is($store->deliver(sub { }, 1000), 2, 'guest mute leaves host and other guest alerts');
	# History reports the global mute apart from a guest's own mute.
	$store->mute('all', 1, 1001);
	ok($store->history()->{muted}, 'combined history reports global mute');
	ok($store->history($other)->{all_muted}, 'guest history reports global mute');
	ok(!$store->history($other)->{muted}, 'global mute does not set individual mute');
	# Unmuting a guest cannot override the global mute.
	$store->mute($guest, 0, 1002);
	reading($store, $rule, 1002, 95);
	is($store->deliver(sub { die 'unexpected send' }, 1002), 0,
		'guest unmute cannot override global mute');
	# Ending the global mute resumes the host and the other guest. The
	# first guest's own mute stays.
	$store->mute($guest, 1, 1003);
	$store->mute('all', 0, 1004);
	reading($store, $rule, 1004, 95, $guest);
	reading($store, $rule, 1004, 95, $other);
	reading($store, $host, 1004, 95, 'host');
	my @sent;
	$store->deliver(sub { push @sent, $_[1]{owner} }, 1004);
	is_deeply([ sort @sent ], [ sort ($other, 'host') ],
		'unmute all resumes host and other guest, preserving individual mute');
	ok($store->history($guest)->{muted}, 'separate guest mute remains set');
	};

# Only a fresh bad reading after unmuting announces an incident.
subtest 'Recoveries and missing readings do not release old incidents' => sub {
	my ($store, $rule, $target) = fixture();
	# A problem that recovers while muted sends nothing after unmuting.
	$store->mute($guest, 1, 1000);
	reading($store, $rule, 1000, 95);
	reading($store, $rule, 1001, 20);
	$store->mute($guest, 0, 1002);
	is($store->deliver(sub { die 'unexpected send' }, 1002), 0,
		'recovered incident has no replay');
	# An unknown reading after unmuting does not announce the incident.
	$store->mute($guest, 1, 1003);
	reading($store, $rule, 1003, 95);
	$store->mute($guest, 0, 1004);
	reading($store, $rule, 1004, undef);
	is($store->deliver(sub { die 'unexpected send' }, 1004), 0,
		'unknown reading does not announce a continuing incident');
	# Its later recovery stays muted, as the incident was never announced.
	reading($store, $rule, 1005, 20);
	is($store->history()->{events}[-1]{deliveries}[0]{state}, 'muted',
		'recovery first seen after unmute does not announce a quiet incident');
	};

# Mutes cover pending retries and past job times, but not destination tests.
subtest 'Queued retries, test messages and historical jobs' => sub {
	my ($store, $rule, $target) = fixture();
	# Queue a failed alert for retry and a destination test.
	reading($store, $rule, 1000, 95);
	$store->deliver(sub { die 'temporary' }, 1000);
	$store->test_target($target, 1000);
	# A global mute mutes the retry at once. The test still sends.
	$store->mute('all', 1, 1001);
	is($store->history()->{events}[0]{deliveries}[0]{state}, 'muted',
		'global mute cancels future retry immediately');
	is($store->deliver(sub { }, 1001), 1, 'explicit destination test still delivers');
	# A muted receipt cannot be retried or sent after unmuting.
	$store->retry(1, 1002);
	$store->mute('all', 0, 1003);
	is($store->deliver(sub { die 'unexpected send' }, 1200), 0,
		'muted receipt cannot be retried or released later');
	# A late job scan checks the mute at each job's own time.
	my $job = $store->save_rule({ name => 'Jobs', metric => 'job_failed',
		scope => 'all', targets => [ $target ] }, 0)->{id};
	$store->failure('during', 'host', 'failed job', 1002);
	is($store->history()->{events}[-1]{silenced}, 'all',
		'late job scan honors historical global mute');
	$store->failure('after', $guest, 'failed job', 1004);
	is($store->history()->{events}[-1]{deliveries}[0]{state}, 'queued',
		'job after unmute can deliver');
	};

# Bad input fails, repeated actions are harmless, and status is current.
subtest 'Validation, repeated actions and current status' => sub {
	my ($store, $rule, $target) = fixture();
	# Reject bad scopes and non-boolean flags.
	for my $bad (undef, '', 'host', '*', [ ], '../all') {
		eval { $store->mute($bad, 1, 1000) };
		ok($@, 'invalid scope rejected');
		}
	for my $bad (-1, 2, 60, [ ]) {
		eval { $store->mute($guest, $bad, 1000) };
		ok($@, 'mute flag must be boolean');
		}
	# Muting twice keeps one interval.
	$store->mute($guest, 1, 1000);
	$store->mute($guest, 1, 1001);
	my $db = $store->connect(0);
	is($db->selectrow_array('SELECT COUNT(*) FROM mutes'), 1,
		'repeated mute preserves one interval');
	$db->disconnect();
	# Incident badges follow the mute without waiting for a new reading.
	reading($store, $rule, 1001, 95);
	ok($store->history($guest)->{states}[0]{muted}, 'current mute badge is visible');
	$store->mute($guest, 0, 1002);
	ok(!$store->history($guest)->{states}[0]{muted},
		'unmute refreshes the badge without another reading');
	# Unmuting twice leaves the guest unmuted.
	$store->mute($guest, 0, 1003);
	ok(!$store->history($guest)->{muted}, 'repeated unmute stays unmuted');
	};

# Version 1 stores stay readable, and the first write upgrades them.
subtest 'Version-one stores remain readable before migration' => sub {
	my ($store, $rule, $target) = fixture();
	# Turn a store with a queued alert back into the version 1 schema.
	reading($store, $rule, 1000, 95);
	my $db = $store->connect(1);
	$db->do('DROP TABLE mutes');
	$db->do('PRAGMA user_version = 1');
	$db->disconnect();
	# Reads work on the old schema without upgrading it.
	is(scalar(@{$store->history($guest)->{events}}), 1, 'old history is readable');
	ok(!$store->history($guest)->{muted}, 'old store has no manual mute');
	$db = $store->connect(0);
	is($db->selectrow_array('PRAGMA user_version'), 1, 'reads do not upgrade schema');
	$db->disconnect();
	# Muting upgrades to version 3, keeps rules and mutes the queued alert.
	$store->mute($guest, 1, 1001);
	$db = $store->connect(0);
	is($db->selectrow_array('PRAGMA user_version'), 3, 'first write upgrades schema');
	$db->disconnect();
	is($store->configuration()->{rules}[0]{id}, $rule, 'rule survives migration');
	is($store->history()->{events}[0]{deliveries}[0]{state}, 'muted',
		'existing pending delivery handled after migration');
	};

# Version 2 stores came from an unreleased build with timed mutes and rule
# schedules.
subtest 'Earlier test installs keep active mutes and drop schedules' => sub {
	my ($store, $rule, $target) = fixture();
	# Build a version 2 store with an active timed mute and a rule schedule.
	my $db = $store->connect(1);
	my $now = time();
	$db->do('INSERT INTO mutes VALUES (?, ?, ?)', undef, $guest, $now - 60, $now + 60);
	$db->do('CREATE TABLE windows (id TEXT PRIMARY KEY, record TEXT NOT NULL)');
	my $record = $store->configuration()->{rules}[0];
	$record->{windows} = [ 'old-schedule' ];
	$db->do('UPDATE rules SET record = ? WHERE id = ?', undef,
		Cloudmin::Notifications::encode($record), $rule);
	$db->do('PRAGMA user_version = 2');
	$db->disconnect();
	# Opening it for writing keeps the mute with no end time and removes
	# the schedules.
	$db = $store->connect(1);
	is($db->selectrow_array('SELECT until_time FROM mutes'), 0,
		'active timed mute becomes manual');
	is($db->selectrow_array('PRAGMA user_version'), 3, 'test schema is upgraded');
	$db->disconnect();
	ok(!exists($store->configuration()->{rules}[0]{windows}),
		'old rule schedule selection is removed');
	ok($store->history($guest)->{muted}, 'active mute survives migration');
	};

done_testing();
