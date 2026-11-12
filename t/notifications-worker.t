use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use Test::More;
use File::Temp qw(tempdir);
use WebminCore;
no warnings qw(redefine once);
our (%config, $module_root_directory, $module_var_directory,
     $cloudmin_notifications_directory);
# Load the worker with a private data directory, not host storage.
$module_root_directory = "$Bin/..";
$module_var_directory = tempdir(CLEANUP => 1);
require "$module_root_directory/cloudmin-notifications-lib.pl";
require "$module_root_directory/cloudmin-statistics-lib.pl";
require "$module_root_directory/cloudmin-config-lib.pl";

# WorkerJobs::list_pending(self) keeps this worker free of host job state.
sub WorkerJobs::list_pending { return [ ]; }
my $clock = time() + 100.75;
# time() returns a stable fractional timestamp for cache freshness checks.
local *Time::HiRes::time = sub { $clock };
# statistics_enabled() enables the isolated collector fixture.
local *main::statistics_enabled = sub { 1 };
# statistics_latest() returns one fresh host sample, reused by the next tick.
local *main::statistics_latest = sub {
	return { checked_at => $clock - .25, interval => 10,
		host => { values => { cpu => 95 } } };
	};
# get_vm_jobs() returns no pending jobs and never opens host job storage.
local *main::get_vm_jobs = sub { bless { }, 'WorkerJobs' };
my @sent;
# send_cloudmin_notification(target, event) records delivery without a network.
local *main::send_cloudmin_notification = sub { push @sent, $_[1] };
# A zero-duration rule fires on the first fresh sample.
my $store = get_notifications();
my $target = $store->save_target({ name => 'Fixture', type => 'email',
	address => 'fixture@example.invalid' })->{id};
$store->save_rule({ name => 'CPU', metric => 'cpu', scope => 'host',
	duration => 0, targets => [ $target ] }, $clock - 1);
run_cloudmin_notifications();
is(scalar(@sent), 1, 'fractional sample is evaluated and delivered immediately');
is($sent[0]->{phase}, 'firing', 'fresh CPU observation opens an incident');
# Receivers get whole seconds, as test and job failure events already send.
is($sent[0]->{created}, int($clock), 'event time has no fraction');
my $last = $store->configuration()->{targets}->[0]->{last_delivery};
is($last->{at}, int($clock), 'last delivery time has no fraction');
ok(!$store->metadata('worker')->{error}, 'worker records a successful check');
# Reusing a fresh sample neither pauses nor advances the incident.
run_cloudmin_notifications();
is(scalar(@sent), 1, 'reusing the same collector snapshot does not alert again');
is($store->history(undef, 0, 100)->{states}->[0]->{status}, 'active',
	'unchanged fresh snapshot retains the incident');
# Check that repeated samples do not reset waits.
subtest 'Checks faster than collection' => sub {
	local $cloudmin_notifications_directory = tempdir(CLEANUP => 1);
	local $config{notifications_interval} = 10;
	my $base = time() + 1000;
	my $sample = { checked_at => $base, interval => 60,
		host => { values => { cpu => 95 } } };
	# statistics_latest() reuses one sample until the fixture advances it.
	local *main::statistics_latest = sub { $sample };
	my $store = get_notifications();
	my $target = $store->save_target({ name => 'Timing', type => 'email',
		address => 'fixture@example.invalid' })->{id};
	$store->save_rule({ name => 'CPU', metric => 'cpu', scope => 'host',
		duration => 1, targets => [ $target ] }, $base - 1);
	@sent = ( );
	$clock = $base;
	run_cloudmin_notifications();
	for my $tick (10, 20, 30, 40, 50) {
		# The same reading cannot satisfy
		# the duration or erase its start.
		$clock = $base + $tick;
		run_cloudmin_notifications();
		my $state = $store->history(undef, 0, 100)->{states}->[0];
		is($state->{since}, $base, 'cached reading retains duration start');
		is($state->{last}, $base, 'cached reading does not advance the check');
		}
	is(scalar(@sent), 0, 'repeated cached readings do not fire');
	$clock = $sample->{checked_at} = $base + 60;
	run_cloudmin_notifications();
	is(scalar(@sent), 1, 'new reading confirms the full minute and fires');
	# Missing data must still pause without inventing a recovery.
	$clock = $base + 241;
	run_cloudmin_notifications();
	is($store->history(undef, 0, 100)->{states}->[0]->{status}, 'paused',
		'expired cached reading pauses the incident');
	is(scalar(@sent), 1, 'expired reading sends no recovery');
	# Host probes and delivery still run between collector updates.
	$sample->{checked_at} = $clock = $base + 300;
	run_cloudmin_notifications();
	my $fs = $store->save_rule({ name => 'Filesystem', metric => 'filesystem',
		scope => 'host', duration => 0, targets => [ $target ] }, $base + 300)->{id};
	# foreign_require(module) prevents loading the workstation mount module.
	local *main::foreign_require = sub { };
	# disk_space(disk, path) reports 95
	# percent usage without probing a disk.
	local *mount::disk_space = sub { (0, 0, 0, 95) };
	$clock = $base + 310;
	run_cloudmin_notifications();
	ok(grep($_->{rule} eq $fs, @sent),
		'host filesystem fires and delivers while collector sample is unchanged');
	};

# Readings from an old rule must not affect an edited rule.
subtest 'Rule edited while readings are collected' => sub {
	local $cloudmin_notifications_directory = tempdir(CLEANUP => 1);
	my $store = get_notifications();
	my $target = $store->save_target({ name => 'Editing', type => 'email',
		address => 'fixture@example.invalid' })->{id};
	my $id = $store->save_rule(
		{ name => 'Resource', metric => 'cpu', scope => 'host',
		  duration => 0, targets => [ $target ] },
		$clock - 1)->{id};
	my $edited = 0;
	my $memory = 30;
	# statistics_latest() models an edit after the worker
	# has read its rules.
	local *main::statistics_latest = sub {
		if (!$edited++) {
			# Keep the timestamp unchanged to cover edits
			# in the same second.
			$store->save_rule(
				{ id => $id, name => 'Resource',
				  metric => 'memory', scope => 'host',
				  duration => 0, targets => [ $target ] },
				$clock - 1);
			}
		# Every call returns a fresh host sample with CPU and memory.
		return { checked_at => $clock, interval => 10,
			host => { values => {
				cpu => 95, memory_allocated => 100,
				memory_used => $memory } } };
		};
	# The worker reads the CPU rule, then the rule changes during its run.
	@sent = ( );
	run_cloudmin_notifications();
	is(scalar(@sent), 0,
	   'old CPU reading cannot trigger the new memory rule');
	is_deeply($store->history()->{states}, [ ],
		'old readings do not recreate the edited rule state');
	# The next fresh sample uses the new condition and can alert normally.
	$clock += 60;
	$memory = 95;
	run_cloudmin_notifications();
	is(scalar(@sent), 1, 'the edited rule alerts on its own fresh reading');
	is($sent[0]->{metric}, 'memory', 'the alert uses the saved condition');
	};

# Reading a numeric-looking pool name must not look like a saved rule edit.
subtest 'Rule snapshot survives numeric field use' => sub {
	local $cloudmin_notifications_directory = tempdir(CLEANUP => 1);
	my $store = get_notifications();
	my $target = $store->save_target({ name => 'Pool', type => 'email',
		address => 'fixture@example.invalid' })->{id};
	$store->save_rule({ name => 'Pool usage', metric => 'pool',
		scope => 'host', device => '10', duration => 0,
		targets => [ $target ] }, $clock - 1);
	# statistics_latest() supplies one fresh pool usage reading.
	local *main::statistics_latest = sub {
		return { checked_at => $clock, interval => 10, host => {
			pools => [ { name => '10', capacity => 100,
				     allocation => 95 } ] } };
		};
	my $observe = \&Cloudmin::NotificationSignals::observations;
	# observations(rules, snapshot, now, filesystems)
	# models a numeric comparison that changes Perl's scalar flags
	# without changing the rule's value.
	local *Cloudmin::NotificationSignals::observations = sub {
		my ($rules) = @_;
		ok($rules->[0]->{device} == 10,
		   'pool name is used as a number');
		return $observe->(@_);
		};
	@sent = ( );
	run_cloudmin_notifications();
	is(scalar(@sent), 1,
	   'an unchanged rule still alerts after numeric field use');
	is($sent[0]->{subject}, 'host/10', 'alert belongs to the named pool');
	};

# Check waits with a five-minute check interval.
subtest 'Checks every five minutes' => sub {
	local $cloudmin_notifications_directory = tempdir(CLEANUP => 1);
	local $config{notifications_interval} = 300;
	my $base = time() + 2000;
	# statistics_latest() supplies a fresh reading at each five-minute tick.
	local *main::statistics_latest = sub {
		{ checked_at => $clock, interval => 10,
		  host => { values => { cpu => 95 } } };
		};
	my $store = get_notifications();
	my $target = $store->save_target({ name => 'Slow', type => 'email',
		address => 'fixture@example.invalid' })->{id};
	$store->save_rule({ name => 'CPU', metric => 'cpu', scope => 'host',
		duration => 5, targets => [ $target ] }, $base - 1);
	# Two runs five minutes apart must cover the five-minute duration.
	@sent = ( );
	$clock = $base;
	run_cloudmin_notifications();
	$clock = $base + 300;
	run_cloudmin_notifications();
	is(scalar(@sent), 1, 'five-minute interval can satisfy five-minute duration');
	};

# Check every enabled path with no duplicate probes.
subtest 'Many host mount points' => sub {
	local $cloudmin_notifications_directory = tempdir(CLEANUP => 1);
	# statistics_enabled() disables collection for independent disk checks.
	local *main::statistics_enabled = sub { 0 };
	# foreign_require(module) avoids loading real disk helpers.
	local *main::foreign_require = sub { };
	my @probed;
	# disk_space(disk, path) records probes and
	# returns a high usage reading.
	local *mount::disk_space = sub {
		push @probed, $_[1];
		return (0, 0, 0, 95);
		};
	my $store = get_notifications();
	my $target = $store->save_target({ name => 'Mounts', type => 'email',
		address => 'fixture@example.invalid' })->{id};
	# Use twelve paths, one shared by two rules, plus a disabled rule.
	my @paths = map { "/mount/$_" } 1..12;
	my @rules = map {
		$store->save_rule({ name => $_, metric => 'filesystem',
			scope => 'host', device => $_, duration => 0,
			targets => [ $target ] }, $clock - 1)->{id}
		} (@paths, $paths[0]);
	$store->save_rule({ name => 'Disabled', metric => 'filesystem',
		scope => 'host', device => '/disabled', enabled => 0,
		targets => [ $target ] }, $clock - 1);
	@sent = ( );
	run_cloudmin_notifications();
	is_deeply([ sort @probed ], [ sort @paths ],
		'all enabled paths are checked once despite shared rules');
	is_deeply([ sort map { $_->{rule} } @sent ], [ sort @rules ],
		'every matching mount rule delivers its alert');
	ok(!$store->metadata('worker')->{error}, 'large mount set checks succeed');
	};

# A concurrent check must leave an in-progress delivery worker alone.
{
	open(my $lock, '>>', "$store->{directory}/worker.lock") or die $!;
	flock($lock, 2) or die $!;
	my $before = $store->metadata('worker');
	run_cloudmin_notifications();
	is_deeply($store->metadata('worker'), $before,
		'overlapping check exits without evaluating or delivering');
	close($lock);
	}

# Check stale, recovered and disabled collection.
subtest 'Collector outage and recovery' => sub {
	local $cloudmin_notifications_directory = tempdir(CLEANUP => 1);
	local $config{notifications_interval} = 10;
	my $store = get_notifications();
	my $target = $store->save_target({ name => 'Health', type => 'email',
		address => 'fixture@example.invalid' })->{id};
	my $base = time() + 10000;
	my $sample = { checked_at => $base, interval => 10,
		host => { values => { cpu => 95 } } };
	# statistics_latest() exposes the sample controlled by this test.
	local *main::statistics_latest = sub { $sample };
	my $health = $store->save_rule({ name => 'Collector',
		metric => 'collector_stale', duration => 1, cooldown => 0,
		targets => [ $target ] }, $base)->{id};
	$store->save_rule({ name => 'CPU', metric => 'cpu',
		duration => 0, targets => [ $target ] }, $base);
	@sent = ( );
	$clock = $base;
	run_cloudmin_notifications();
	is(scalar(@sent), 1, 'fresh cache triggers only usage alert');
	# One stale cache starts the health timer and pauses the usage incident.
	for my $offset (31, 41, 51, 61, 71, 81, 91) {
		$clock = $base + $offset;
		run_cloudmin_notifications();
		}
	is(scalar(@sent), 2, 'collector outage adds one alert');
	is($sent[-1]{metric}, 'collector_stale', 'health alert identifies collector');
	is($sent[-1]{owner}, 'host', 'outage has a host incident');
	# Recovery needs a new fresh sample, not another read of the old cache.
	$clock = $sample->{checked_at} = $base + 100;
	run_cloudmin_notifications();
	is($sent[-1]{phase}, 'resolved', 'fresh collector data reports recovery');
	{
		# statistics_enabled() turns collection off
		# without simulating failure.
		local *main::statistics_enabled = sub { 0 };
		for my $offset (140, 180, 220) {
			$clock = $base + $offset;
			run_cloudmin_notifications();
			}
		is(scalar(@sent), 3, 'intentional disable sends no outage');
		}
	# A failed cache read must not skip evaluation of the health rule.
	{
		# statistics_latest() fails before
		# returning any cached readings.
		local *main::statistics_latest = sub { die "Fixture cache failure\n" };
		my @warnings;
		# __WARN__(messages...) captures the expected cache-read errors.
		local $SIG{__WARN__} = sub { push @warnings, @_ };
		for my $offset (240, 250, 260, 270, 280, 290, 300) {
			$clock = $base + $offset;
			run_cloudmin_notifications();
			}
		is($sent[-1]{phase}, 'firing', 'cache read failure still produces health alert');
		is($sent[-1]{metric}, 'collector_stale', 'cache failure is a health event');
		ok(@warnings, 'cache failure is logged');
		}
	};

# Check usage and free space from a single disk probe.
subtest 'Shared filesystem probe' => sub {
	local $cloudmin_notifications_directory = tempdir(CLEANUP => 1);
	# statistics_enabled() disables collection to isolate disk checks.
	local *main::statistics_enabled = sub { 0 };
	# foreign_require(module) avoids loading real disk helpers.
	local *main::foreign_require = sub { };
	my $probes = 0;
	# disk_space(disk, path) counts probes and returns one GiB free in KiB.
	local *mount::disk_space = sub {
		$probes++;
		return (20 * 1024**2, 1 * 1024**2, 19 * 1024**2, 95);
		};
	my $store = get_notifications();
	my $target = $store->save_target({ name => 'Filesystem', type => 'email',
		address => 'fixture@example.invalid' })->{id};
	# A usage rule and a free-space rule watch the same mount.
	for my $rule (
		{ metric => 'filesystem', threshold => 90 },
		{ metric => 'filesystem_free', threshold => 2 }) {
		$store->save_rule({ name => 'Disk', scope => 'host', device => '/',
			duration => 0, targets => [ $target ], %$rule }, $clock);
		}
	@sent = ( );
	run_cloudmin_notifications();
	is($probes, 1, 'one probe for two rules on the same mount');
	is(scalar(@sent), 2, 'both conditions alert without the collector');
	my ($free) = grep { $_->{metric} eq 'filesystem_free' } @sent;
	is($free->{value}, 1, 'free KiB converts to GiB exactly');
	};

done_testing();
