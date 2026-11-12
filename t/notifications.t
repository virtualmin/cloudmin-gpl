use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use lib "$Bin/../lib";
use Cloudmin::Notifications;
use Cloudmin::NotificationSignals;
use Test::More;
use File::Temp qw(tempdir);

# Reading an unused store must not create persistent state.
my $dir = tempdir(CLEANUP => 1);
my $store = Cloudmin::Notifications->new(directory => $dir);
is_deeply($store->configuration(), { rules => [ ], targets => [ ] },
	'fresh reader has empty configuration');
ok(!-e "$dir/notifications.sqlite", 'reader creates no database');
eval { $store->target('a' x 32) };
like($@, qr/destination not found/, 'fresh store has no saved destination');
ok(!-e "$dir/notifications.sqlite", 'target reader creates no database');
# Check that readers recover a killed writer's journal.
subtest 'Interrupted writer' => sub {
	my $dir = tempdir(CLEANUP => 1);
	my $store = Cloudmin::Notifications->new(directory => $dir);
	$store->save_target({ name => 'Interrupted', type => 'email',
		address => 'ops@example.invalid' });
	my $pid = fork();
	die "Cannot fork: $!\n" unless defined($pid);
	if (!$pid) {
		# A tiny cache makes SQLite write part of the change to disk
		# early. The child then dies as a killed worker would.
		my $db = $store->connect(1);
		$db->do('PRAGMA cache_size = 1');
		$db->do('BEGIN IMMEDIATE');
		$db->do('INSERT INTO metadata VALUES (?, ?)', undef,
			"spill$_", 'x' x 4000) for 1 .. 200;
		$db->do('DELETE FROM targets');
		kill('KILL', $$);
		}
	# The parent finds the leftover journal. A reader must then clear it.
	waitpid($pid, 0);
	ok(-s "$dir/notifications.sqlite-journal",
		'killed writer leaves its journal');
	is(scalar(@{$store->configuration()->{targets}}), 1,
		'reader rolls back the interrupted change');
	ok(!-e "$dir/notifications.sqlite-journal",
		'recovery removes the journal');
	};
# Check long waits and reminders without sleeping.
subtest 'Long notification timings' => sub {
	my $store = Cloudmin::Notifications->new(directory => tempdir(CLEANUP => 1));
	my $target = $store->save_target({ name => 'Timing', type => 'email',
		address => 'ops@example.invalid' })->{id};
	my $input = { name => 'Timing', metric => 'filesystem', scope => 'host',
		device => '/', duration => 2880, cooldown => 20160,
		reminder => 20160, targets => [ $target ] };
	my $rule = $store->save_rule($input, 1000)->{id};
	my $record = $store->configuration()->{rules}[0];
	is_deeply({ map { $_ => $record->{$_} } keys %$input }, $input,
		'long durations survive saving');

	# Timings have no maximum, but malformed or negative values are
	# still rejected.
	for my $field (qw(duration cooldown reminder)) {
		for my $invalid (-1, 'NaN', 'Inf', [ ]) {
			eval { $store->save_rule({ %$input, $field => $invalid }, 1000) };
			ok($@, "$field rejects invalid input");
			}
		}

	# A two-day duration waits for its full period before creating an alert.
	my $readings = { $rule => [ { owner => 'host', subject => 'host/',
		label => '/', value => 95, running => 1 } ] };
	my $timing = { max_gap => 60 * 20161 };
	$store->evaluate($readings, 1000, { }, $timing);
	$store->evaluate($readings, 1000 + 60 * 2880 - 1, { }, $timing);
	is(scalar(@{$store->history()->{events}}), 0,
		'long duration does not alert early');
	my $fired = 1000 + 60 * 2880;
	$store->evaluate($readings, $fired, { }, $timing);
	is(scalar(@{$store->history()->{events}}), 1,
		'long duration eventually creates its alert');
	# The reminder repeats only after its own two-week interval.
	$store->evaluate($readings, $fired + 60 * 20160 - 1, { }, $timing);
	is(scalar(@{$store->history()->{events}}), 1,
		'long reminder interval does not repeat early');
	$store->evaluate($readings, $fired + 60 * 20160, { }, $timing);
	is($store->history()->{events}[-1]{phase}, 'reminder',
		'long reminder interval eventually repeats');
	};

# Check pagination beyond a billion event IDs.
subtest 'Large event cursor' => sub {
	my $store = Cloudmin::Notifications->new(directory => tempdir(CLEANUP => 1));
	my $target = $store->save_target({ name => 'Cursor', type => 'email',
		address => 'ops@example.invalid' })->{id};
	$store->test_target($target, 1000);
	# callback(db) makes the next event ID one billion.
	$store->transaction(sub {
		$_[0]->do("UPDATE sqlite_sequence SET seq = 999999999 WHERE name = 'events'");
		});
	my $first = $store->test_target($target, 1001)->{id};
	my $second = $store->test_target($target, 1002)->{id};
	my $page = $store->history(undef, $first, 100);
	is_deeply([ map { $_->{id} } @{$page->{events}} ], [ $second ],
		'large cursor returns only later events');
	is($page->{cursor}, $second, 'returned cursor advances');
	};

# Saved settings must validate transport inputs and redact credentials.
my $target = $store->save_target({ name => 'Operations', type => 'email',
	address => 'ops@example.invalid' })->{id};
my $hook = $store->save_target({ name => 'Hook', type => 'webhook',
	address => 'https://example.invalid/events', secret => 'private-token' })->{id};
my $config = $store->configuration();
unlike(Cloudmin::Notifications::encode($config), qr/private-token/,
	'configuration never returns bearer credentials');
# Each case is an unsafe address, token or enabled flag.
for my $case (
	{ type => 'email', address => "ops\@example.invalid\nBcc: victim" },
	{ type => 'webhook', address => 'file:///etc/passwd' },
	{ type => 'webhook', address => 'https://user:password@example.invalid/' },
	{ type => 'webhook', address => 'http://example.invalid/', secret => 'token' },
	{ type => 'webhook', address => 'https://example.invalid/', secret => [ ] },
	{ type => 'email', address => 'ops@example.invalid', enabled => 0.5 },
) {
	eval { $store->save_target({ name => 'Bad', %$case }) };
	ok($@, 'unsafe destination or flag rejected');
	}
# Check token preservation, replacement and removal.
subtest 'Saved destination tokens' => sub {
	my $store = Cloudmin::Notifications->new(directory => tempdir(CLEANUP => 1));
	my $input = { name => 'Token editor', type => 'webhook',
		address => 'https://example.invalid/token', secret => q{token"<>&'} };
	my $id = $store->save_target($input)->{id};
	my $saved = $store->target($id);
	is($saved->{secret}, $input->{secret}, 'editor reads the saved token');
	$store->save_target($saved);
	is($store->target($id)->{secret}, $input->{secret},
		'unchanged form preserves the token');
	# Explicit edits replace the token;
	# omitting it preserves the current value.
	$store->save_target({ %$saved, secret => 'replacement' });
	is($store->target($id)->{secret}, 'replacement', 'replacement is saved');
	my %without_token = %$saved;
	delete $without_token{secret};
	$store->save_target(\%without_token);
	is($store->target($id)->{secret}, 'replacement',
		'omitted token preserves the saved value at the same URL');
	# Blank input clears the token, and a changed URL cannot inherit it.
	$store->save_target({ %$saved, secret => '' });
	is($store->target($id)->{secret}, '', 'blank token removes the saved value');
	ok(!$store->configuration()->{targets}[0]{has_secret},
		'configuration reports the token removal');
	$store->save_target($saved);
	$store->save_target({ %without_token,
		address => 'https://example.invalid/changed' });
	is($store->target($id)->{secret}, '',
		'changed URL does not inherit an omitted token');
	$store->save_target($saved);
	# clear_secret removes the token even when one is supplied.
	$store->save_target({ %$saved, clear_secret => 1 });
	is($store->target($id)->{secret}, '', 'removal overrides the populated field');
	for my $invalid (undef, [ $id ], "bad-id", 'a' x 32) {
		# Missing and malformed IDs must never
		# resolve to another destination.
		eval { $store->target($invalid) };
		like($@, qr/Invalid target ID|destination not found/,
			'invalid or unknown destination is rejected');
		}
	};
# The main fixture alerts after two minutes and reminds after five.
my $rule = $store->save_rule({ name => 'CPU pressure', metric => 'cpu',
	scope => 'host', threshold => 90, duration => 2, reminder => 5,
	targets => [ $target, $hook ] }, 1000)->{id};

# tick(time, value, [suppressed]) evaluates the host CPU fixture.
# time is Unix seconds; value may be undef; suppressed is an owner map, empty
# by default. The store and rule ID come from the surrounding fixture.
sub tick
{
my ($now, $value, $suppressed) = @_;
$store->evaluate({ $rule => [ { owner => 'host', subject => 'host/',
	label => 'Host', value => $value, running => 1 } ] }, $now,
	$suppressed || { });
}

# events() reads up to 500 fixture events to check for duplicates.
sub events
{
return $store->history(undef, 0, 500)->{events};
}
# Sustained readings fire once and retain the incident across store reopen.
tick(1000, 91);
tick(1060, 95);
is(scalar(@{events()}), 0, 'short spikes do not alert');
tick(1120, 94);
is(scalar(@{events()}), 1, 'sustained threshold creates one event');
is(scalar(@{events()->[0]->{deliveries}}), 2, 'both destinations queued');
$store = Cloudmin::Notifications->new(directory => $dir);
tick(1180, 96);
is(scalar(@{events()}), 1, 'restart does not duplicate active incident');
# Near-threshold and missing readings must not claim recovery.
tick(1240, 89);
is(scalar(@{events()}), 1, 'hysteresis avoids near-limit flapping');
tick(1300, undef);
is($store->history(undef, 0, 100)->{states}->[0]->{status}, 'paused',
	'missing data pauses an active alert');
is(scalar(@{events()}), 1, 'missing data never announces recovery');
tick(1360, 87);
is(events()->[-1]->{phase}, 'resolved', 'fresh low reading resolves');
# A sample gap restarts duration; planned work pauses an existing incident.
tick(1420, 99);
tick(1600, 99);
is(scalar(@{events()}), 2, 'sampling gap resets duration');
tick(1660, 99);
tick(1720, 99);
is(scalar(@{events()}), 3, 'new continuous interval fires');
tick(1780, 99, { host => 1 });
is(scalar(@{events()}), 3, 'planned work does not clear the incident');
tick(2020, 99);
is(events()->[-1]->{phase}, 'reminder', 'optional reminder is rate limited');

# Network failure for one target never loses another
# target's successful receipt.
my @sent;
# send(target, event) rejects only the webhook and records accepted event IDs.
$store->deliver(sub {
	my ($t, $e) = @_;
	die "secret-in-transport-error\n" if $t->{id} eq $hook;
	push @sent, $e->{id};
	}, 2100);
ok(@sent, 'healthy destination delivered despite another failing');
my $history = $store->history(undef, 0, 100);
unlike(Cloudmin::Notifications::encode($history), qr/secret-in|private-token/,
	'receipts redact transport errors and credentials');
# Retry only failed destinations after their due time, using the same event IDs.
my %delivered = map { $_ => 1 } @sent;
# send(target, event) records any send attempted before the retry deadline.
$store->deliver(sub { push @sent, $_[1]->{id} }, 2101);
is(scalar(@sent), scalar(keys %delivered), 'retry waits for its deadline');
my @retry;
# send(target, event) records both IDs so retries can be matched to failures.
$store->deliver(sub { push @retry, [ $_[0]->{id}, $_[1]->{id} ] }, 2300);
ok(@retry && !grep({ $_->[0] ne $hook } @retry),
	'retry only delivers previously failed target');
is_deeply([ sort map { $_->[1] } @retry ], [ sort keys %delivered ],
	'retry preserves original event IDs');
# Disabling a destination cancels pending sends but leaves references intact.
my $test = $store->test_target($hook, 2400)->{id};
$store->save_target({ id => $hook, name => 'Hook', type => 'webhook',
	address => 'https://example.invalid/events', enabled => 0 });
# send(target, event) fails the test if a cancelled delivery is attempted.
$store->deliver(sub { fail('disabled destination was contacted') }, 2500);
is($store->history(undef, $test - 1, 1)->{events}->[0]->{deliveries}->[0]->{state},
	'cancelled', 'disabling target cancels queued message');
eval { $store->remove('target', $target) };
like($@, qr/rules first/, 'referenced target cannot disappear silently');

# Failed jobs survive restarts and do not reappear when scanned again.
my $vm = '11111111-1111-4111-8111-111111111111';
my $jobs = $store->save_rule({ name => 'Failures', metric => 'job_failed',
	scope => 'all', targets => [ $target ] }, 2600)->{id};
$store->failure('job:one', $vm, 'Backup failed', 2599);
my $count = scalar(@{events()});
$store->failure('job:two', $vm, 'Backup failed', 2700);
$store->failure('job:two', $vm, 'Backup failed', 2700);
is(scalar(@{events()}), $count + 1, 'job failure is routed once');
my $guest = $store->history($vm, 0, 100);
is(scalar(@{$guest->{events}}), 1, 'guest history excludes host alerts');
ok(!exists($guest->{events}->[0]->{deliveries}), 'guest cannot read destinations');

# Planned shutdowns must wait for shutdown to finish
# before watching for restart.
my $down = $store->save_rule({ name => 'Guest down', metric => 'guest_down',
	scope => $vm, duration => 0, targets => [ $target ] }, 2800)->{id};
$store->suppress($vm, -2800);
for my $case ([ 2810, 1, 0 ], [ 2860, 0, 1 ], [ 2920, 0, 1 ]) {
	$store->evaluate({ $down => [ { owner => $vm, subject => $vm,
		label => 'Guest', running => $case->[1], value => $case->[2] } ] },
		$case->[0], { });
	}
is(scalar(@{events()}), $count + 1, 'planned stop remains suppressed');
# Once the guest has run again, a new stop is unplanned and alerts.
$store->evaluate({ $down => [ { owner => $vm, subject => $vm,
	label => 'Guest', running => 1, value => 0 } ] }, 3000, { });
$store->evaluate({ $down => [ { owner => $vm, subject => $vm,
	label => 'Guest', running => 0, value => 1 } ] }, 3060, { });
is(events()->[-1]->{phase}, 'firing', 'unexpected stop after restart alerts');
$store->remove('rule', $down);
# send(target, event) accepts any remaining delivery without network access.
$store->deliver(sub { }, 3200);
is(events()->[-1]->{deliveries}->[0]->{state}, 'cancelled',
	'deleting a rule cancels unsent incidents');

# Check pause reasons without creating events.
subtest 'Pause reasons follow the current condition' => sub {
	my $store = Cloudmin::Notifications->new(
		directory => tempdir(CLEANUP => 1));
	my $target = $store->save_target({ name => 'Paused fixture',
		type => 'email', address => 'fixture@example.invalid' })->{id};
	my $rule = $store->save_rule({ name => 'Guest', metric => 'guest_down',
		scope => $vm, duration => 0, targets => [ $target ] },
		1000)->{id};
	my $obs = { owner => $vm, subject => $vm, label => 'Guest',
		running => 0, value => undef };
	# A stop requested through Cloudmin explains the missing readings.
	$store->suppress($vm, -1000);
	$store->evaluate({ $rule => [ $obs ] }, 1010, { });
	is($store->history($vm, 0, 100)->{states}->[0]->{pause_reason},
		'planned_stop', 'planned stop explains missing readings');
	# Observed recovery clears a stop marker and its displayed pause reason.
	$obs->{running} = 1;
	$obs->{value} = 0;
	$store->evaluate({ $rule => [ $obs ] }, 1020, { });
	ok(!exists($store->history($vm, 0, 100)->{states}->[0]->{pause_reason}),
		'restart removes the old explanation');
	# A timed reboot pause yields to a current job after the grace expires.
	$store->suppress($vm, 1100);
	$store->evaluate({ $rule => [ $obs ] }, 1030, { });
	is($store->history($vm, 0, 100)->{states}->[0]->{pause_reason},
		'planned_restart', 'reboot grace period has a distinct reason');
	$store->evaluate({ $rule => [ $obs ] }, 1100, { $vm => 1 });
	is($store->history($vm, 0, 100)->{states}->[0]->{pause_reason},
		'active_job', 'active job replaces expired reboot grace');
	# A missing subject without an incident is forgotten, not kept paused.
	$store->evaluate({ }, 1110, { });
	is_deeply($store->history($vm, 0, 100)->{states}, [ ],
		'missing subject without an incident is no longer listed');
	# Unknown readings replace obsolete pause causes.
	$obs->{value} = undef;
	$store->evaluate({ $rule => [ $obs ] }, 1120, { });
	is($store->history($vm, 0, 100)->{states}->[0]->{pause_reason},
		'unavailable', 'unknown reading waits for fresh status');
	is_deeply($store->history($vm, 0, 100)->{events}, [ ],
		'pause explanations do not create alerts or recoveries');
	};
# Removed guests drop out unless an incident or cooldown must be kept.
subtest 'Missing subjects keep only meaningful state' => sub {
	my $store = Cloudmin::Notifications->new(
		directory => tempdir(CLEANUP => 1));
	my $target = $store->save_target({ name => 'Missing fixture',
		type => 'email', address => 'fixture@example.invalid' })->{id};
	my $rule = $store->save_rule({ name => 'Guests', metric => 'guest_down',
		scope => 'guests', duration => 0, cooldown => 10,
		targets => [ $target ] }, 1000)->{id};
	my ($one, $two) =
		map { sprintf('%08d-0000-0000-0000-000000000000', $_) } 1, 2;
	# obs(owner, value) builds one guest power reading.
	my $obs = sub { +{ owner => $_[0], subject => $_[0], label => $_[0],
		running => $_[1] ? 0 : 1, value => $_[1] } };
	# The first guest alerts and recovers; the second stays healthy.
	for my $step ([ 1010, 1 ], [ 1020, 0 ]) {
		$store->evaluate({ $rule => [ $obs->($one, $step->[1]),
			$obs->($two, 0) ] }, $step->[0], { });
		}
	# Both guests vanish while the first one's cooldown is running.
	$store->evaluate({ $rule => [ ] }, 1030, { });
	my %states = map { $_->{owner} => $_ }
		@{$store->history(undef, 0, 100)->{states}};
	is_deeply([ sort keys %states ], [ $one ],
		'healthy missing guest is forgotten');
	is($states{$one}->{status}, 'paused',
		'cooldown keeps the missing guest paused');
	# Once the cooldown ends, the missing guest is forgotten too.
	$store->evaluate({ $rule => [ ] }, 1010 + 600, { });
	is_deeply($store->history(undef, 0, 100)->{states}, [ ],
		'expired cooldown releases the missing guest');
	# An active incident survives a missing reading without recovering.
	$store->evaluate({ $rule => [ $obs->($two, 1) ] }, 1700, { });
	$store->evaluate({ $rule => [ ] }, 3000, { });
	my ($active) = @{$store->history(undef, 0, 100)->{states}};
	ok($active->{active} && $active->{status} eq 'paused',
		'missing guest keeps its active incident paused');
	is(scalar(grep { $_->{phase} eq 'resolved' }
		@{$store->history(undef, 0, 100)->{events}}), 1,
		'only the observed recovery is reported');
	};
# Collector readings decide which subjects drop out and which stay paused.
subtest 'Removed resources through collector readings' => sub {
	my $store = Cloudmin::Notifications->new(
		directory => tempdir(CLEANUP => 1));
	my $target = $store->save_target({ name => 'Removed fixture',
		type => 'email', address => 'fixture@example.invalid' })->{id};
	my ($one, $two) =
		map { sprintf('%08d-0000-0000-0000-000000000000', $_) } 1, 2;
	my %rule = ( metric => 'guest_down', duration => 0,
		targets => [ $target ] );
	my $all = $store->save_rule({ %rule, name => 'All guests',
		scope => 'guests' }, 1000)->{id};
	my $picked = $store->save_rule({ %rule, name => 'Selected guest',
		scope => [ $one ] }, 1000)->{id};
	my $mount = $store->save_rule({ %rule, name => 'Missing mount',
		metric => 'filesystem', scope => 'host',
		device => '/srv/missing' }, 1000)->{id};
	# check(now, guests) evaluates fresh readings for the listed guests.
	my $check = sub {
		my ($now, @guests) = @_;
		my $snapshot = { checked_at => $now, interval => 10,
			vms => { map { $_ => { state => 'running',
				checked_at => $now, name => $_ } } @guests } };
		$store->evaluate(Cloudmin::NotificationSignals::observations(
			$store->configuration()->{rules}, $snapshot, $now,
			{ '/srv/missing' => undef }), $now, { });
		};
	$check->(1010, $one, $two);
	$check->(1020, $two);
	my %states = map { $_->{rule}.' '.$_->{owner} => $_ }
		@{$store->history(undef, 0, 100)->{states}};
	ok(!$states{"$all $one"}, 'removed guest leaves the all-guests rule');
	is($states{"$all $two"}->{status}, 'ok',
		'remaining guest stays checked');
	is($states{"$picked $one"}->{pause_reason}, 'unavailable',
		'explicitly selected guest stays paused');
	is($states{"$mount host"}->{pause_reason}, 'unavailable',
		'missing host mount point stays paused');
	};

# Check immediate tests and their later retries.
subtest 'Immediate test delivery' => sub {
	my $store = Cloudmin::Notifications->new(
		directory => tempdir(CLEANUP => 1));
	my $target = $store->save_target({ name => 'Test', type => 'email',
		address => 'fixture@example.invalid' })->{id};
	my $queued = $store->test_target($target, 1000)->{id};
	my @sent;
	# send(target, event) checks that the foreground
	# receipt is already leased.
	my $result = $store->test_target($target, 1010, sub {
		my ($target, $event) = @_;
		push @sent, $event->{id};
		my $data = $store->history(undef, $event->{id} - 1, 1);
		is($data->{events}->[0]->{deliveries}->[0]->{state}, 'sending',
			'test is reserved before the sender runs');
		});
	# The earlier queued test stays queued for the worker.
	is_deeply(\@sent, [ $result->{id} ], 'only the new test is sent');
	ok(!$result->{error}, 'accepted test reports success');
	my $events = $store->history(undef, 0, 100)->{events};
	is($events->[0]->{deliveries}->[0]->{state}, 'queued',
		'unrelated queued delivery is untouched');
	is($events->[1]->{deliveries}->[0]->{state}, 'sent',
		'accepted test records its delivery');
	# A transport exception becomes a safe result and a normal queued retry.
	$result = $store->test_target($target, 1020,
		# send(target, event) simulates a failure whose
		# raw error contains a token.
		sub { die "Bearer private-token in transport error\n" });
	like($result->{error}, qr/Delivery failed/,
		'failed test reports failure');
	unlike(Cloudmin::Notifications::encode($result), qr/private-token/,
		'transport secrets never reach the progress result');
	$events = $store->history(undef, $result->{id} - 1, 1)->{events};
	is($events->[0]->{deliveries}->[0]->{state}, 'queued',
		'failed test remains eligible for scheduled retry');
	is($events->[0]->{deliveries}->[0]->{attempts}, 1,
		'foreground attempt counts toward the retry limit');
	};

# Signals keep missing totals distinct from zero and retain real overcommit.
is(Cloudmin::NotificationSignals::percent(0, 100), 0, 'zero is measured');
is(Cloudmin::NotificationSignals::percent(200, 100), 200, 'overcommit retained');
is(Cloudmin::NotificationSignals::percent(50, 0), undef, 'zero total unknown');
# One running guest with a failed agent supplies every guest signal.
my @rules = map { { id => $_, metric => $_, enabled => 1, scope => $vm } }
	qw(cpu memory guest_down guest_agent filesystem);
my $snapshot = { checked_at => 4000, interval => 10, vms => { $vm => {
	name => 'Guest', state => 'running', checked_at => 4000,
	resources => { cpu_percent => 95, memory_bytes => 100, memory_used_bytes => 92 },
	agent_available => 0, agent_checked_at => 3990,
	guest => { filesystems => [ { mountpoint => '/', 'total-bytes' => 100,
		'used-bytes' => 97 } ] } } } };
# A fresh snapshot gives every signal a reading.
my $obs = Cloudmin::NotificationSignals::observations(\@rules, $snapshot, 4000, { });
is($obs->{cpu}->[0]->{value}, 95, 'CPU signal');
is($obs->{memory}->[0]->{value}, 92, 'memory signal');
is($obs->{guest_agent}->[0]->{value}, 1, 'failed agent signal');
is($obs->{guest_down}->[0]->{value}, 0, 'running guest is healthy');
is($obs->{filesystem}->[0]->{value}, 97, 'guest filesystem signal');
# Stale snapshots cannot establish health or extend a sustained duration.
$obs = Cloudmin::NotificationSignals::observations(\@rules, $snapshot, 4100, { });
is($obs->{cpu}->[0]->{value}, undef, 'stale cache does not accumulate duration');
# Failed agent probes remain useful within the collector retry window.
$snapshot->{vms}->{$vm}->{agent_checked_at} = 800;
$obs = Cloudmin::NotificationSignals::observations(\@rules, $snapshot, 4000, { });
is($obs->{guest_agent}->[0]->{value}, 1,
	'active collector retains failed probes through their retry backoff');
$snapshot->{vms}->{$vm}->{agent_checked_at} = 50;
$obs = Cloudmin::NotificationSignals::observations(\@rules, $snapshot, 4000, { });
is($obs->{guest_agent}->[0]->{value}, undef,
	'agent results beyond the retry window pause the rule');
# A powered-off guest has a power signal but no meaningful agent signal.
$snapshot->{vms}->{$vm}->{state} = 'shutoff';
$obs = Cloudmin::NotificationSignals::observations(\@rules, $snapshot, 4000, { });
is($obs->{guest_down}->[0]->{value}, 1, 'stopped guest alerts independently');
is($obs->{guest_agent}->[0]->{value}, undef, 'stopped guest cannot lose its agent');
# Retention removes events and receipts, never saved monitoring rules.
$store->prune(4000000);
is(scalar(@{events()}), 0, 'expired events and deliveries are removed');
is(scalar(@{$store->configuration()->{rules}}), 2, 'pruning preserves rules');
# Cooldown limits separate incidents without hiding a real recovery.
my $quiet_dir = tempdir(CLEANUP => 1);
my $quiet = Cloudmin::Notifications->new(directory => $quiet_dir);
my $qt = $quiet->save_target({ name => 'Quiet', type => 'email',
	address => 'quiet@example.invalid' })->{id};
my $qr = $quiet->save_rule({ name => 'Threshold', metric => 'cpu',
	scope => 'host', duration => 0, cooldown => 5, threshold => 1,
	targets => [ $qt ] }, 10)->{id};
# Alert, recover, then exceed the threshold again inside the cooldown.
for my $case ([ 20, 2 ], [ 30, 0 ], [ 40, 2 ]) {
	$quiet->evaluate({ $qr => [ { owner => 'host', subject => 'host/',
		label => 'Host', value => $case->[1] } ] }, $case->[0], { });
	}
is(scalar(@{$quiet->history(undef, 0, 100)->{events}}), 2,
	'cooldown delays a second incident after recovery');
$quiet->evaluate({ $qr => [ { owner => 'host', subject => 'host/',
	label => 'Host', value => 2 } ] }, 330, { });
is(scalar(@{$quiet->history(undef, 0, 100)->{events}}), 3,
	'still-bad condition alerts after cooldown');
# Six failed attempts exhaust automatic retries; explicit retry can resume.
for my $when (400, 10000, 20000, 30000, 40000, 50000) {
	# send(target, event) fails every attempt without using a real service.
	$quiet->deliver(sub { die "Unavailable\n" }, $when);
	}
is($quiet->history(undef, 0, 100)->{events}->[0]->{deliveries}->[0]->{state},
	'failed', 'delivery stops after six failures');
my $retry_id = $quiet->history(undef, 0, 100)->{events}->[0]->{id};
$quiet->retry($retry_id, 51000);
# send(target, event) accepts the manually retried delivery.
$quiet->deliver(sub { }, 51000);
is($quiet->history(undef, 0, 100)->{events}->[0]->{deliveries}->[0]->{state},
	'sent', 'explicit retry resumes a failed receipt');

# A crashed sender's lease is recovered, but cannot be claimed prematurely.
my $lease = $quiet->test_target($qt, 52000)->{id};
# callback(db) reserves a queued delivery as if its worker had crashed.
$quiet->transaction(sub {
	$_[0]->do("UPDATE deliveries SET state = 'sending', due = ? WHERE event = ?",
		undef, 52300, $lease);
	});
# send(target, event) must not run while another worker owns the delivery.
is($quiet->deliver(sub { fail('Lease stolen before expiration') }, 52200), 0,
	'unexpired delivery lease stays owned');
# send(target, event) accepts the delivery after its reservation expires.
is($quiet->deliver(sub { }, 52301), 1, 'abandoned delivery lease is recovered');
# Saving a rule with a new destination is atomic, including later validation.
{
	my $setup = Cloudmin::Notifications->new(
		directory => tempdir(CLEANUP => 1));
	my $input = { name => 'First rule', metric => 'cpu',
		scope => 'host', enabled => 0 };
	my $dest = { name => 'First email', type => 'email',
		address => 'ops@example.invalid' };
	# Save a disabled rule and a new email destination in one call.
	my $before = Cloudmin::Notifications::encode($input);
	my $saved = $setup->save_rule($input, 1000, $dest);
	my $cfg = $setup->configuration();
	is(scalar(@{$cfg->{targets}}), 1, 'rule creates its destination');
	is_deeply($cfg->{rules}[0]{targets}, [ $cfg->{targets}[0]{id} ],
		'new rule uses the new destination');
	is(Cloudmin::Notifications::encode($input), $before,
		'combined save leaves caller input unchanged');
	# Each invalid rule or destination must leave both lists unchanged.
	for my $bad (
		[ { %$input, name => '' }, $dest ],
		[ { %$input, threshold => 101 }, $dest ],
		[ $input, { %$dest, address => 'invalid' } ],
		[ $input, { %$dest, id => $cfg->{targets}[0]{id} } ],
		[ $input, [ ] ],
	) {
		eval { $setup->save_rule($bad->[0], 1001, $bad->[1]) };
		ok($@, 'invalid combined input is rejected');
		is_deeply($setup->configuration(), $cfg,
			'failed save leaves both inventories unchanged');
		}
	# Editing may create a replacement destination
	# without deleting the old one.
	$setup->save_rule({ %$input, id => $saved->{id} }, 1002,
		{ name => 'New webhook', type => 'webhook',
		  address => 'https://example.invalid/events',
		  secret => 'fixture-token' });
	my $updated = $setup->configuration();
	my ($hook) = grep { $_->{type} eq 'webhook' } @{$updated->{targets}};
	ok($hook->{has_secret}, 'new webhook keeps its token private');
	is_deeply($updated->{rules}[0]{targets}, [ $hook->{id} ],
		'editing a rule can assign a new webhook');
	is(scalar(@{$updated->{targets}}), 2,
		'editing a rule leaves its previous destination available');
}
# Check delivery across multiple worker batches.
subtest 'More than 32 saved destinations' => sub {
	my $dir = tempdir(CLEANUP => 1);
	my $store = Cloudmin::Notifications->new(directory => $dir);
	my @targets = map {
		$store->save_target({ name => "Destination $_", type => 'email',
			address => "ops$_\@example.invalid" })->{id}
		} 1..35;
	my $input = { name => 'All destinations', metric => 'cpu',
		duration => 0, targets => \@targets };
	my $rule = $store->save_rule($input, 1000)->{id};
	# Reopen the store to check what was saved.
	$store = Cloudmin::Notifications->new(directory => $dir);
	is_deeply($store->configuration()->{rules}[0]{targets}, \@targets,
		'all destinations survive reopening');

	# Form submissions accept the same set and still remove duplicates.
	$store->save_rule({ %$input, id => $rule,
		targets => join("\0", @targets, $targets[0]) }, 1001);
	is_deeply($store->configuration()->{rules}[0]{targets}, \@targets,
		'form lists retain every destination without duplicates');
	for my $bad ([ ], { }, [ 'unknown' ]) {
		eval { $store->save_rule({ %$input, targets => $bad }, 1002) };
		ok($@, 'empty or invalid destination lists are still rejected');
		}

	# Queue every copy, then drain it through the normal worker limit.
	$store->evaluate({ $rule => [ { owner => 'host', subject => 'host/',
		label => 'Host', value => 95, running => 1 } ] }, 1010, { });
	my $event = $store->history(undef, 0, 100)->{events}[0];
	is(scalar(@{$event->{deliveries}}), 35,
		'every destination receives a queued copy');
	my @sent;
	# send(target, event) records destinations without sending messages.
	my $send = sub { push @sent, $_[0]->{id} };
	is($store->deliver($send, 1020), 20, 'first batch keeps its limit');
	is($store->deliver($send, 1080), 15, 'next batch sends the remainder');
	is_deeply([ sort @sent ], [ sort @targets ],
		'each destination is contacted exactly once');
	};

# Check that every saved rule is evaluated.
subtest 'More than 128 saved rules' => sub {
	my $dir = tempdir(CLEANUP => 1);
	my $store = Cloudmin::Notifications->new(directory => $dir);
	my $target = $store->save_target({ name => 'Operations', type => 'email',
		address => 'ops@example.invalid' })->{id};
	my @rules = map {
		$store->save_rule({ name => "Rule $_", metric => 'cpu',
			duration => 0, targets => [ $target ] }, 1000)->{id}
		} 1..129;
	$store = Cloudmin::Notifications->new(directory => $dir);
	is_deeply([ sort map { $_->{id} } @{$store->configuration()->{rules}} ],
		[ sort @rules ], 'all rules survive reopening');

	# A matching reading must create an alert for every rule.
	my %readings = map { $_ => [ { owner => 'host', subject => 'host/',
		label => 'Host', value => 95, running => 1 } ] } @rules;
	$store->evaluate(\%readings, 1010, { });
	my $events = $store->history(undef, 0, 500)->{events};
	is_deeply([ sort map { $_->{rule} } @$events ], [ sort @rules ],
		'every rule produces its own alert');
	};

# Selected guests have independent incidents and exclude other guests.
{
	my $multi = Cloudmin::Notifications->new(
		directory => tempdir(CLEANUP => 1));
	my $dest = $multi->save_target({ name => 'Selected guests',
		type => 'email', address => 'ops@example.invalid' })->{id};
	my @ids = map { sprintf('%08d-1111-4111-8111-111111111111', $_) }
		1..4;
	my $input = { name => 'Selected power', metric => 'guest_down',
		scope => [ @ids[0, 1, 0] ], duration => 0,
		targets => [ $dest ] };
	my $id = $multi->save_rule($input, 1000)->{id};
	# Reopen the store. The duplicate guest is gone and the input is intact.
	$multi = Cloudmin::Notifications->new(directory => $multi->{directory});
	my $rules = $multi->configuration()->{rules};
	is_deeply($rules->[0]{scope}, [ @ids[0, 1] ],
		'guest selection survives reopening without duplicates');
	is_deeply($input->{scope}, [ @ids[0, 1, 0] ],
		'validation preserves the caller selection');
	# Only selected guests produce incidents, even
	# when inventory is broader.
	my $sample = { checked_at => 1000, interval => 10, vms => {
		map { $_ => { name => $_, state => 'shutoff',
			      checked_at => 1000 } } @ids[0..2] } };
	my $readings = Cloudmin::NotificationSignals::observations(
		$rules, $sample, 1000, { });
	$multi->evaluate($readings, 1000, { });
	my $events = $multi->history(undef, 0, 100)->{events};
	is_deeply([ sort map { $_->{owner} } @$events ], [ @ids[0, 1] ],
		'only the two selected guests alert');
	# One guest's recovery must not close the other guest's incident.
	$sample->{vms}{$ids[0]}{state} = 'running';
	$readings = Cloudmin::NotificationSignals::observations(
		$rules, $sample, 1001, { });
	$multi->evaluate($readings, 1001, { });
	$events = $multi->history(undef, 0, 100)->{events};
	is(scalar(@$events), 3,
		'one recovery leaves the other incident active');
	is($events->[-1]{owner}, $ids[0],
		'recovery belongs to the first guest');
	is($events->[-1]{phase}, 'resolved', 'healthy guest resolves');

	# New inventory entries affect all-guests rules but not selected sets.
	$sample->{vms}{$ids[3]} = { state => 'shutoff', checked_at => 1000 };
	my $all = { %{$rules->[0]}, id => 'all-guests', scope => 'guests' };
	$readings = Cloudmin::NotificationSignals::observations(
		[ @$rules, $all ], $sample, 1002, { });
	is(scalar(@{$readings->{$id}}), 2,
		'new guests do not widen a selection');
	is(scalar(@{$readings->{'all-guests'}}), 4,
		'all guests includes newly discovered guests');

	# Failed jobs use the same selection and keep per-guest history scoped.
	my $failed = $multi->save_rule({ %$input, name => 'Selected jobs',
		metric => 'job_failed' }, 1000)->{id};
	$multi->failure('job:'.$_, $_, 'Backup failed', 1003)
		for (@ids, 'host');
	my @failures = grep { $_->{rule} eq $failed }
		@{$multi->history(undef, 0, 100)->{events}};
	is_deeply([ sort map { $_->{owner} } @failures ], [ @ids[0, 1] ],
		'job failures exclude the host and unselected guests');
	is_deeply($multi->history($ids[2], 0, 100)->{events}, [ ],
		'unselected guest has no events from the shared rules');

	# Invalid or empty sets cannot silently become host or all-guest rules.
	for my $scope ([ ], [ 'host' ], [ 'guests' ], [ 'all' ], [ undef ],
		      [ { id => $ids[0] } ], [ 'invalid' ]) {
		eval { $multi->save_rule({ %$input, scope => $scope }, 1004) };
		ok($@, 'invalid guest selection rejected');
		}
	eval { $multi->save_rule({ %$input, metric => 'pool' }, 1004) };
	like($@, qr/host scope/, 'pool rules still require the host');

	# Large selections retain every guest and still remove duplicates.
	my @many = map { sprintf('%08d-1111-4111-8111-111111111111', $_) }
		1..300;
	my $large = $multi->save_rule({ %$input,
		scope => [ @many, $many[0] ] }, 1005)->{id};
	$multi = Cloudmin::Notifications->new(directory => $multi->{directory});
	my ($saved) = grep { $_->{id} eq $large }
		@{$multi->configuration()->{rules}};
	is_deeply($saved->{scope}, \@many,
		'more than 256 selected guests persist without duplicates');
	# Every selected guest must produce its own observation and incident.
	$sample = { checked_at => 1005, interval => 10, vms => {
		map { $_ => { name => $_, state => 'shutoff',
			      checked_at => 1005 } } @many } };
	$readings = Cloudmin::NotificationSignals::observations(
		[ $saved ], $sample, 1005, { });
	$multi->evaluate($readings, 1005, { });
	is_deeply([ sort map { $_->{owner} } grep { $_->{rule} eq $large }
		@{$multi->history(undef, 0, 500)->{events}} ], \@many,
		'every selected guest gets an independent alert');
}
# Inline switches preserve secrets and cancel pending sends atomically.
my $row_store = Cloudmin::Notifications->new(directory => tempdir(CLEANUP => 1));
my $row_id = $row_store->save_target({ name => 'Row', type => 'webhook',
	address => 'https://example.invalid/row', secret => 'row-secret' })->{id};
my $row_event = $row_store->test_target($row_id, 1000)->{id};
$row_store->set_target_enabled($row_id, 0);
is($row_store->history(undef, 0, 100)->{events}[0]{deliveries}[0]{state},
	'cancelled', 'inline disable cancels queued delivery');
my $row_cfg = $row_store->configuration()->{targets}[0];
ok(!$row_cfg->{enabled} && $row_cfg->{has_secret},
	'inline disable preserves the saved token');
is($row_cfg->{address}, 'https://example.invalid/row', 'switch preserves address');
# Unknown destinations and invalid states are rejected.
eval { $row_store->set_target_enabled('a' x 32, 1) };
like($@, qr/not found/, 'switch rejects an unknown destination');
eval { $row_store->set_target_enabled($row_id, 2) };
like($@, qr/Invalid enabled/, 'switch rejects an invalid state');
# Re-enabling preserves the bearer token and records a real last attempt.
$row_store->set_target_enabled($row_id, 1);
my $sent_secret;
$row_event = $row_store->test_target($row_id, 2000,
	# send(target, event) captures the private token used for delivery.
	sub { $sent_secret = $_[0]->{secret} })->{id};
is($sent_secret, 'row-secret', 'enabled destination retains its credential');
my $receipt = $row_store->configuration()->{targets}[0]{last_delivery};
is_deeply($receipt, { event => $row_event, at => 2000,
	state => 'sent', error => '' }, 'list exposes a real successful attempt');
# Retry and pruning keep the list's delivery summary tied to retained receipts.
# send(target, event) throws private error details that must stay hidden.
$row_store->test_target($row_id, 3000, sub { die "private transport details" });
$receipt = $row_store->configuration()->{targets}[0]{last_delivery};
is($receipt->{state}, 'queued', 'failed attempt remains queued for retry');
is($receipt->{at}, 3000, 'latest attempt timestamp advances');
unlike($receipt->{error}, qr/private/, 'list does not expose transport secrets');
# send(target, event) accepts the retry without contacting a destination.
$row_store->deliver(sub { }, 3200);
is($row_store->configuration()->{targets}[0]{last_delivery}{state}, 'sent',
	'retry updates the last delivery result');
$row_store->prune(3200 + 31 * 86400);
ok(!$row_store->configuration()->{targets}[0]{last_delivery},
	'pruned receipts do not claim an unrecorded delivery');
$row_store->remove('target', $row_id);
ok(!$row_store->metadata('delivery:'.$row_id),
	'deleting a destination removes its last-attempt marker');

# Rule switches preserve configuration and discard obsolete incidents and sends.
{
my $switch = Cloudmin::Notifications->new(directory => tempdir(CLEANUP => 1));
my $dest = $switch->save_target({ name => 'Switch target', type => 'email',
	address => 'switch@example.invalid' })->{id};
my $id = $switch->save_rule({ name => 'Switch rule', metric => 'cpu',
	scope => [ $vm ], threshold => 72, duration => 0, cooldown => 17,
	reminder => 23, recovery => 0, severity => 'error',
	targets => [ $dest ] }, 1000)->{id};
my $observe = { $id => [ { owner => $vm, subject => $vm.'/',
	label => 'Switch guest', value => 90, running => 1 } ] };
$switch->evaluate($observe, 1001, { });
# Disabling clears the old incident while preserving the configured condition.
my $before = $switch->configuration()->{rules}[0];
$switch->set_rule_enabled($id, 0, 1002);
is_deeply($switch->configuration()->{rules}[0],
	{ %$before, enabled => 0, created => 1002 },
	'switch preserves rule settings and starts a new baseline');
is($switch->history(undef, 0, 100)->{events}[0]{deliveries}[0]{state},
	'cancelled', 'rule disable cancels queued delivery');
is_deeply($switch->history(undef, 0, 100)->{states}, [ ],
	'rule disable clears the previous incident');
$switch->evaluate($observe, 2000, { });
is(scalar(@{$switch->history(undef, 0, 100)->{events}}), 1,
	'disabled rules do not create alerts');
# Re-enabling starts a baseline only once, then permits a fresh alert.
$switch->set_rule_enabled($id, 1, 2001);
$switch->set_rule_enabled($id, 1, 2002);
is($switch->configuration()->{rules}[0]{created}, 2001,
	'repeated state submission keeps the current baseline');
$switch->evaluate($observe, 2003, { });
is(scalar(@{$switch->history(undef, 0, 100)->{events}}), 2,
	'enabled rule can alert again');
# Malformed IDs, unknown rules and invalid states are rejected.
for my $case ([ 'bad', 1 ], [ 'a' x 32, 1 ], [ $id, 2 ]) {
	eval { $switch->set_rule_enabled(@$case, 2004) };
	like($@, qr/Invalid|not found/, 'rule switch rejects invalid input');
	}
}

done_testing();
