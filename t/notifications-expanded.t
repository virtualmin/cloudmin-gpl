use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use lib "$Bin/../lib";
use Cloudmin::Notifications;
use Cloudmin::NotificationSignals;
use Cloudmin::NotificationMessages;
use Test::More;
use File::Temp qw(tempdir);
use Encode qw(decode);
use URI ();

# Load decoded translations so message tests use the same text as the UI.
my %text;
open(my $lang, '<:encoding(UTF-8)', "$Bin/../lang/en") or die $!;
while (<$lang>) { chomp; $text{$1} = $2 if /^([^=]+)=(.*)$/; }
close($lang);

# fixture() creates independent rule and delivery storage without host services.
sub fixture
{
my $store = Cloudmin::Notifications->new(directory => tempdir(CLEANUP => 1));
my $target = $store->save_target({ name => 'Sink', type => 'email',
	address => 'fixture@example.invalid' })->{id};
return ($store, $target);
}

# reading(id, value) supplies one host reading for the given rule ID.
sub reading
{
my ($id, $value) = @_;
return { $id => [ { owner => 'host', subject => 'host/',
	label => 'Host', value => $value, running => 1 } ] };
}

# Check low-space alerts and the recovery margin.
subtest 'Free space, lower thresholds and recovery' => sub {
	my ($store, $target) = fixture();
	my $id = $store->save_rule({ name => 'Low space', metric => 'pool_free',
		scope => 'host', threshold => 10, duration => 0, cooldown => 0,
		targets => [ $target ] }, 1000)->{id};
	is($store->configuration()->{rules}[0]{comparison}, 'le',
		'free-space rules default to a lower threshold');
	# Equality fires, but a small improvement must not report recovery.
	$store->evaluate(reading($id, 11), 1000, { });
	is(scalar(@{$store->history()->{events}}), 0, 'adequate space stays quiet');
	$store->evaluate(reading($id, 10), 1060, { });
	my $event = $store->history()->{events}[0];
	is($event->{phase}, 'firing', 'threshold equality alerts');
	is($event->{unit}, 'GiB', 'event snapshots absolute units');
	is($event->{comparison}, 'le', 'event snapshots comparison');
	$store->evaluate(reading($id, 10.1), 1120, { });
	is(scalar(@{$store->history()->{events}}), 1, 'recovery margin prevents flaps');
	# Unknown data pauses the alert; enough free space resolves it.
	$store->evaluate(reading($id, undef), 1180, { });
	is(scalar(@{$store->history()->{events}}), 1, 'missing data is not recovery');
	$store->evaluate(reading($id, 10.2), 1240, { });
	is($store->history()->{events}[-1]{phase}, 'resolved',
		'recovery occurs at two percent past threshold');
	};

# Check percentage recovery and an exact zero threshold.
subtest 'Percentage and zero thresholds' => sub {
	my ($store, $target) = fixture();
	my $id = $store->save_rule({ name => 'Low activity', metric => 'cpu',
		threshold => 10, comparison => 'le', duration => 0,
		targets => [ $target ] }, 1000)->{id};
	$store->evaluate(reading($id, 10), 1000, { });
	$store->evaluate(reading($id, 11), 1060, { });
	is(scalar(@{$store->history()->{events}}), 1,
		'percent recovery uses percentage points, not relative percent');
	$store->evaluate(reading($id, 12), 1120, { });
	is($store->history()->{events}[-1]{phase}, 'resolved',
		'below-percent rule clears at threshold plus two');
	# A zero threshold must clear as soon as the rate becomes positive.
	my $zero = $store->save_rule({ name => 'No traffic',
		metric => 'network_receive', threshold => 0, comparison => 'le',
		duration => 0, targets => [ $target ] }, 1200)->{id};
	$store->evaluate(reading($zero, 0), 1200, { });
	$store->evaluate(reading($zero, .001), 1260, { });
	is($store->history()->{events}[-1]{phase}, 'resolved',
		'nonzero traffic clears a zero threshold');
	};

# Check scope, comparison and numeric validation.
subtest 'Validation preserves meaningful constraints' => sub {
	my ($store, $target) = fixture();
	for my $metric (qw(load_1 load_5 load_15 pool_free pool_inactive collector_stale)) {
		eval { $store->save_rule({ name => 'Invalid scope', metric => $metric,
			scope => 'guests', targets => [ $target ] }, 1000) };
		like($@, qr/host scope/, "$metric requires the host");
		}
	# Reject invalid values and comparisons without imposing percentage
	# limits on rates or other absolute measurements.
	for my $bad (
		{ metric => 'cpu', threshold => 101 },
		{ metric => 'load_1', threshold => -1 },
		{ metric => 'disk_read', threshold => 'NaN' },
		{ metric => 'memory_free', comparison => 'lt' }) {
		eval { $store->save_rule({ name => 'Invalid', targets => [ $target ],
			%$bad }, 1000) };
		ok($@, 'malformed or out-of-range setting is rejected');
		}
	# Rates have no upper limit.
	ok($store->save_rule({ name => 'Fast disk', metric => 'disk_read',
		threshold => 500, duration => 0, targets => [ $target ] }, 1000),
		'absolute rate thresholds can exceed 100');
	};

# Check host and guest fields, units and pool freshness.
subtest 'Measurements and pool health' => sub {
	my $guest = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
	my $gib = 1024**3;
	my $mib = 1024**2;
	# One snapshot holds host values, pool states and a running guest.
	my $snapshot = { checked_at => 1000, interval => 10,
		host => { values => { cpu => 96, memory_used => 10 * $gib,
			memory_allocated => 16 * $gib, load_1 => 2, load_5 => 3,
			load_15 => 4, disk_read => 20 * $mib, disk_write => 30 * $mib,
			network_receive => 40 * $mib, network_transmit => 50 * $mib },
			pools => [ { name => 'data', capacity => 10 * $gib,
				allocation => 2 * $gib, available => 7 * $gib } ],
			pool_checked_at => 1000,
			pool_states => [ { name => 'data', active => 0 },
				{ name => 'images', active => 1 }, { name => 'unknown' } ] },
		vms => { $guest => { checked_at => 1000, state => 'running',
			resources => { memory_used_bytes => 3 * $gib,
				memory_bytes => 4 * $gib, disk_read_bytes_sec => 7 * $mib,
				disk_write_bytes_sec => 8 * $mib, network_rx_bytes_sec => 9 * $mib,
				network_tx_bytes_sec => 10 * $mib },
			guest => { filesystems => [ { mountpoint => '/',
				'used-bytes' => 8 * $gib, 'total-bytes' => 20 * $gib } ] } } } };
	# Host readings use byte counts, rates and
	# independent filesystem probes.
	my %expected = ( cpu => 96, memory => 62.5, memory_free => 6,
		load_1 => 2, load_5 => 3, load_15 => 4, disk_read => 20,
		disk_write => 30, network_receive => 40, network_transmit => 50,
		pool => 20, pool_free => 7, filesystem => 80, filesystem_free => 20,
		collector_stale => 0 );
	# Build one host rule for each expected reading.
	my @rules = map { { id => $_, enabled => 1, metric => $_,
		scope => 'host', device => $_ =~ /^filesystem/ ? '/' : '' } }
		keys %expected;
	my $observations = Cloudmin::NotificationSignals::observations(
		\@rules, $snapshot, 1000, { '/' => { usage => 80, free => 20 } });
	for my $metric (sort keys %expected) {
		is($observations->{$metric}[0]{value}, $expected{$metric},
			"$metric uses the right host measurement and units");
		}
	# Guest fields have different names but must produce the same units.
	%expected = ( memory_free => 1, filesystem_free => 12, disk_read => 7,
		disk_write => 8, network_receive => 9, network_transmit => 10 );
	@rules = map { { id => $_, enabled => 1, metric => $_,
		scope => [ $guest ], device => '' } } keys %expected;
	$observations = Cloudmin::NotificationSignals::observations(
		\@rules, $snapshot, 1000, { });
	for my $metric (sort keys %expected) {
		is($observations->{$metric}[0]{value}, $expected{$metric},
			"$metric uses the right guest measurement and units");
		}
	# Stopped guests have no meaningful free-memory or activity reading.
	$snapshot->{vms}{$guest}{state} = 'shutoff';
	$observations = Cloudmin::NotificationSignals::observations(
		\@rules, $snapshot, 1000, { });
	ok(!defined($_->[0]{value}), 'stopped guest reading stays unknown')
		for values %$observations;

	# Unknown pool status must stay distinct from a confirmed inactive pool.
	my $rule = { id => 'pool', enabled => 1, metric => 'pool_inactive',
		scope => 'host', device => '' };
	$observations = Cloudmin::NotificationSignals::observations(
		[ $rule ], $snapshot, 1000, { });
	is_deeply([ map { $_->{value} } @{$observations->{pool}} ],
		[ 1, 0, undef ], 'known inactive, active and unreadable pools stay distinct');
	$snapshot->{host}{pool_checked_at} = 800;
	$observations = Cloudmin::NotificationSignals::observations(
		[ $rule ], $snapshot, 1000, { });
	ok(!defined($_->{value}), 'old pool inventory cannot establish inactivity')
		for @{$observations->{pool}};
	};

# Distinguish stale data from intentionally disabled collection.
subtest 'Collector health is one host condition' => sub {
	my $rule = { id => 'collector', enabled => 1,
		metric => 'collector_stale', scope => 'host' };
	# Each case gives a snapshot, the check time and the expected reading.
	for my $case (
		[ { checked_at => 1000, interval => 10 }, 1030, 0 ],
		[ { checked_at => 1000, interval => 10 }, 1031, 1 ],
		[ { checked_at => 1001, interval => 10 }, 1000, 1 ],
		[ { }, 1000, 1 ],
		[ { collection_enabled => 0 }, 1000, undef ]) {
		my $obs = Cloudmin::NotificationSignals::observations(
			[ $rule ], $case->[0], $case->[1], { });
		is(scalar(@{$obs->{collector}}), 1, 'one observation regardless of inventory');
		is($obs->{collector}[0]{value}, $case->[2],
			'collector health distinguishes stale, fresh and intentionally disabled');
		}
	};

# Check private URL storage, redaction and validation.
subtest 'Private chat URLs and transport validation' => sub {
	my ($store) = fixture();
	for my $type (qw(slack discord teams)) {
		my $url = 'https://chat.example.invalid/path/fixture-private?sig=fixture-secret';
		my $id = $store->save_target({ name => $type, type => $type,
			address => $url })->{id};
		my ($public) = grep { $_->{id} eq $id } @{$store->configuration()->{targets}};
		ok(!exists($public->{address}), "$type URL omitted from configuration");
		is($public->{address_host}, 'chat.example.invalid', 'hostname remains visible');
		is($store->target($id)->{address}, $url, 'authorized editor retains exact URL');
		# Switching it off and on must keep the private URL.
		$store->set_target_enabled($id, 0);
		$store->set_target_enabled($id, 1);
		is($store->target($id)->{address}, $url, 'switches retain private URL');
		eval { $store->save_target({ name => 'Unsafe', type => $type,
			address => 'http://chat.example.invalid/path' }) };
		like($@, qr/HTTPS/, 'chat credentials require HTTPS');
		}
	unlike(Cloudmin::Notifications::encode($store->configuration()),
		qr/fixture-private|fixture-secret/, 'configuration contains no URL credentials');
	# Reject login credentials, fragments and non-HTTP addresses.
	for my $url ('https://u:p@example.invalid/hook',
		'https://example.invalid/hook#fragment', 'file:///tmp/hook') {
		eval { $store->save_target({ name => 'Unsafe', type => 'teams', address => $url }) };
		ok($@, 'unsafe URL form is rejected');
		}
	};

# Reuse one low-space event across translation and provider-format checks.
my $event = { version => 1, id => 42, instance => 'fixture', host => 'cloudmin.invalid',
	name => 'Low free space', label => 'Guest /data', owner => 'host',
	metric => 'filesystem_free', threshold => 10, comparison => 'le',
	value => 8.5, phase => 'firing', severity => 'warning', duration => 5,
	created => 1700000000 };
my $link = 'https://cloudmin.invalid:10000/server-manager/notifications.cgi?tab=history';
my $message = Cloudmin::NotificationMessages::render($event, \%text, $link);
# Check translated messages, older events and status text.
subtest 'Readable messages and translations' => sub {
	like($message->{subject}, qr/Low free space - Alert$/, 'subject uses readable alert state');
	unlike($message->{body}, qr/\bfiring\b/, 'body has no machine phase');
	like($message->{body}, qr/Reading: 8.5 GiB/, 'body shows value and units');
	like($message->{body}, qr/At or below 10 GiB/, 'body shows comparison and threshold');
	like($message->{body}, qr/Required duration in minutes: 5/, 'body explains wait');
	like($message->{body}, qr/\Q$link\E/, 'body links to Cloudmin');
	# Translation placeholders can change order without corrupting Unicode.
	my %translated = ( %text,
		notifications_firing => 'Alarm',
		notifications_message_subject => '$2: $1',
		notifications_filesystem_free => 'Свободно място' );
	my $localized = Cloudmin::NotificationMessages::render(
		{ %$event, name => "Място\r\n" }, \%translated, $link);
	is($localized->{subject}, 'Alarm: Място', 'translations and Unicode survive without header breaks');
	like($localized->{body}, qr/Свободно място/, 'condition uses module translation');
	# Older events keep their default comparison; health events use words.
	my $legacy = Cloudmin::NotificationMessages::render(
		{ %$event, metric => 'cpu', comparison => undef, threshold => 90, value => 95 },
		\%text, $link);
	like($legacy->{body}, qr/At or above 90%/, 'older queued events remain readable');
	my $health = Cloudmin::NotificationMessages::render(
		{ %$event, metric => 'collector_stale', value => 0, phase => 'resolved' },
		\%text, $link);
	like($health->{body}, qr/providing fresh readings again/, 'health recovery explains actual state');
	unlike($health->{body}, qr/Reading:|Alert threshold:/, 'health messages do not display numeric flags');
	# Test messages name the test once instead of repeating it as a state.
	my $test = Cloudmin::NotificationMessages::render(
		{ %$event, name => 'Test notification', metric => 'test',
		  phase => 'test', severity => 'notice' }, \%text, $link);
	is($test->{subject}, 'Cloudmin: Test notification',
		'test subject does not repeat its name');
	like($test->{body}, qr/tests notification delivery/,
		'test body explains the message');
	};

# Check each request format without sending it.
subtest 'Provider requests' => sub {
	for my $type (qw(webhook slack discord teams ntfy)) {
		my $request = Cloudmin::NotificationMessages::request(
			{ type => $type, address => 'https://receiver.invalid/topic?thread_id=123&wait=false',
				secret => 'fixture-bearer' }, $event, $message);
		is($request->{headers}{'Idempotency-Key'}, 'cloudmin-fixture-42',
			"$type has stable delivery identity");
		is($request->{headers}{Authorization}, 'Bearer fixture-bearer',
			"$type keeps bearer in headers");
		unlike($request->{content}, qr/fixture-bearer/, 'body contains no credential');
		if ($type eq 'ntfy') {
			# ntfy sends plain text with priority in a header.
			like(decode('UTF-8', $request->{content}), qr/Reading: 8.5 GiB/,
				'ntfy receives plain readable text');
			is($request->{headers}{Priority}, 4, 'warning sets ntfy priority');
			next;
			}
		my $payload = WebminCore::convert_from_json($request->{content});
		if ($type eq 'webhook') {
			# Generic webhooks retain every event field.
			is_deeply($payload, $event, 'generic webhook retains complete structured payload');
			}
		elsif ($type eq 'slack') {
			# Slack must treat names as text,
			# including its fallback message.
			is($payload->{blocks}[0]{text}{type}, 'plain_text', 'Slack uses unparsed text');
			ok(!$payload->{mrkdwn}, 'Slack fallback also disables markup');
			}
		elsif ($type eq 'discord') {
			# Keep thread selection, require
			# acceptance and disable mentions.
			my %query = URI->new($request->{url})->query_form();
			is_deeply(\%query, { thread_id => '123', wait => 'true' },
				'Discord waits for creation without losing thread ID');
			is_deeply($payload->{allowed_mentions}{parse}, [ ], 'Discord cannot ping users');
			}
		else {
			# Teams uses a card inside the message attachment.
			is($payload->{attachments}[0]{content}{type}, 'AdaptiveCard',
				'Teams Workflows receives an Adaptive Card');
			}
		}
	# Limits apply to encoded size for ntfy and text length for chat.
	for my $type (qw(slack discord ntfy)) {
		my $request = Cloudmin::NotificationMessages::request(
			{ type => $type, address => 'https://receiver.invalid/topic' },
			$event, { subject => 'Long', body => '😀' x 5000 });
		if ($type eq 'ntfy') {
			# Byte truncation must leave valid UTF-8.
			cmp_ok(length($request->{content}), '<=', 4096, 'ntfy respects byte limit');
			ok(eval { decode('UTF-8', $request->{content}, Encode::FB_CROAK); 1 },
				'ntfy truncation preserves UTF-8');
			}
		else {
			# Slack and Discord limit characters
			# in their text fields.
			my $payload = WebminCore::convert_from_json($request->{content});
			my $body = $type eq 'slack' ? $payload->{blocks}[0]{text}{text}
				: $payload->{content};
			cmp_ok(length($body), '<=', $type eq 'slack' ? 3000 : 2000,
				"$type respects text limit");
			}
		}
	};

# Check that job failures show no waiting period.
subtest 'Job failures have no duration' => sub {
	my ($store, $target) = fixture();
	$store->save_rule({ name => 'Jobs', metric => 'job_failed',
		scope => 'all', targets => [ $target ] }, 1000);
	$store->failure('job:one', 'host', 'Backup job one failed.', 1001);
	my $failed = $store->history()->{events}[-1];
	is($failed->{duration}, undef, 'job failure event has no duration');
	# An event that still carries a duration must not show it either.
	for my $case ($failed, { %$failed, duration => 5 }) {
		my $body = Cloudmin::NotificationMessages::render(
			$case, \%text, '')->{body};
		unlike($body, qr/Required duration/,
			'job failure message shows no wait');
		like($body, qr/Job or scheduled backup failed/,
			'job failure message names its condition');
		}
	};

# Check decoded names in messages and JSON.
subtest 'Names from forms and the API' => sub {
	my ($store, $target) = fixture();
	# Decode the form name as the save handler does. The literal and emoji
	# names must pass through unchanged.
	my %names = ( form => "Gr\xC3\xB6\xC3\x9Fe \xD0\x9C", api => 'Größe М' );
	$names{form} = decode('UTF-8', $names{form});
	$names{literal} = 'Ã©';
	$names{emoji} = 'Alert 😀';
	for my $origin (sort keys %names) {
		my $id = $store->save_rule({ name => $names{$origin},
			metric => 'cpu', duration => 0, cooldown => 0,
			targets => [ $target ] }, 1000)->{id};
		$store->evaluate(reading($id, 95), 1001, { });
		my $saved = $store->history()->{events}[-1];
		my $rendered = Cloudmin::NotificationMessages::render(
			$saved, \%text, '');
		like($rendered->{subject}, qr/\Q$names{$origin}\E/,
			"$origin name is readable in messages");
		my $request = Cloudmin::NotificationMessages::request(
			{ type => 'webhook', address => 'https://receiver.invalid/hook' },
			$saved, { });
		my $payload = WebminCore::convert_from_json($request->{content});
		is($payload->{name}, $names{$origin},
			"$origin name is valid UTF-8 in webhook JSON");
		is($payload->{threshold}, 90, 'webhook numbers stay numbers');
		}
	is(Cloudmin::NotificationMessages::characters('Größe'), 'Größe',
		'characters above ASCII are not read as bytes');
	};

done_testing();
