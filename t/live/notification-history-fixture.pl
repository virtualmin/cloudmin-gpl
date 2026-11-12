#!/usr/bin/perl
# notification-history-fixture.pl add|remove module-root guest-uuid [count]
# Add history, delivery results and disabled destinations without creating
# rules, active incidents or queued messages.
# Source IDs and metadata identify this fixture's records and destinations.
# Adding again keeps existing samples. Removal affects only this guest's
# fixture events, delivery results and unused fixture destinations.
# module-root is the installed Cloudmin directory; guest-uuid selects a guest.
# count defaults to 125 and accepts 1 to 500 when adding samples.
use strict;
use warnings;
use Cwd qw(abs_path);

# Require root on Linux and reject HTTP execution before loading Webmin.
die "Run as root on a Linux test machine\n" unless $^O eq 'linux' && $< == 0 &&
	!$ENV{GATEWAY_INTERFACE};
# Validate the action, module path and guest ID before touching stored data.
my ($action, $module, $guest, $count) = @ARGV;
die "Pass add or remove, an installed module path and a guest UUID\n"
	unless ($action || '') =~ /\A(?:add|remove)\z/ &&
	$module && -f "$module/server-manager-lib.pl" &&
	($guest || '') =~ /\A[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}\z/;
# Default to enough events for five pages, with a limit of 500.
$count = 125 unless defined($count);
die "Count must be between 1 and 500\n"
	unless $count =~ /\A\d+\z/ && $count >= 1 && $count <= 500;
# Use installed Webmin initialization, keeping this helper inaccessible by HTTP.
$module = abs_path($module);
$ENV{WEBMIN_CONFIG} = '/etc/webmin';
$ENV{WEBMIN_VAR} = '/var/webmin';
$ENV{REMOTE_USER} = 'root';
chdir($module) or die $!;
$0 = "$module/notification-history-fixture.pl";
require './server-manager-lib.pl';
my $store = get_notifications();
my $prefix = "history-preview-v1:$guest:";
my $target_key = "history-preview-targets-v1:$guest";

# Match the guest and source prefix so removal leaves real events alone.
if ($action eq 'remove') {
	my $removed = $store->transaction(sub {
		# callback(db) removes samples atomically and returns the count.
		my ($db) = @_;
		# Load only destination IDs recorded for this guest's fixture.
		my ($saved) = $db->selectrow_array(
			'SELECT value FROM metadata WHERE key = ?', undef,
			$target_key);
		my $targets = $saved
			? Cloudmin::Notifications::decode($saved) : [ ];
		# Preserve destinations that were enabled or used outside
		# this fixture.
		for my $id (@$targets) {
			my ($target) = grep { $_->{id} eq $id }
				@{Cloudmin::Notifications::records(
					$db, 'targets')};
			# Refuse removal if events outside this fixture or
			# any rule use this destination.
			my ($other) = $db->selectrow_array(
				'SELECT COUNT(*) FROM deliveries d JOIN events e ON e.id = d.event
				 WHERE d.target = ? AND (e.owner != ? OR e.source IS NULL
				 OR substr(e.source, 1, ?) != ?)',
				undef, $id, $guest, length($prefix), $prefix);
			die "Preview destination is enabled or used outside this fixture\n"
				if ($target && $target->{enabled}) || $other || grep {
					my $rule = $_;
					grep { $_ eq $id } @{$rule->{targets}}
					} @{Cloudmin::Notifications::records(
						$db, 'rules')};
			}
		# Read SQLite's deletion count before deleting other records.
		$db->do(
			'DELETE FROM events WHERE owner = ? AND substr(source, 1, ?) = ?',
			undef, $guest, length($prefix), $prefix);
		my $removed = $db->selectrow_array('SELECT changes()');
		# Event deletion cascades to receipts; remove only the saved
		# fixture targets.
		for my $id (@$targets) {
			$db->do('DELETE FROM targets WHERE id = ?', undef, $id);
			$db->do('DELETE FROM metadata WHERE key = ?', undef,
				'delivery:'.$id);
			}
		$db->do('DELETE FROM metadata WHERE key = ?', undef, $target_key);
		return $removed;
		});
	print "Removed $removed sample notifications\n";
	exit;
	}
# Confirm the requested guest exists before adding visible samples to
# its history.
my $vm = get_libvirt()->get_domain($guest, 1) || die "Guest not found\n";
# Cases contain a metric, name, threshold, comparison and bad/good readings.
my @cases = (
	[ cpu => 'CPU pressure', 90, 'ge', 96.25, 42 ],
	[ memory => 'Memory pressure', 85, 'ge', 91.5, 64 ],
	[ filesystem_free => 'Free disk space', 5, 'le', 1.375, 12 ],
	[ network_receive => 'Network traffic', 100, 'ge', 125.125, 0 ],
	[ guest_down => 'Guest status', undef, 'ge', 1, 0 ],
	[ guest_agent => 'Guest agent', undef, 'ge', 1, 0 ],
	[ job_failed => 'Failed backup', undef, 'ge', undef, undef ],
	[ memory_free => "Caf\x{e9} free memory", 1, 'le', .25, 3 ],
);
my $result = $store->transaction(sub {
	# callback(db) adds samples and returns new event and receipt counts.
	my ($db) = @_;
	# Repeated runs reuse the destinations saved for this guest.
	my ($saved) = $db->selectrow_array(
		'SELECT value FROM metadata WHERE key = ?', undef, $target_key);
	my $targets = $saved ? Cloudmin::Notifications::decode($saved) : [ ];
	if ($saved) {
		# Reuse destinations only while they remain present
		# and disabled.
		for my $id (@$targets) {
			my ($target) = grep { $_->{id} eq $id }
				@{Cloudmin::Notifications::records(
					$db, 'targets')};
			die "Preview destination is missing or enabled\n"
				unless $target && !$target->{enabled};
			}
		}
	else {
		# Disabled destinations keep manual retries from sending
		# any messages.
		for my $target (
			{ name => 'Operations email', type => 'email',
			  address => 'alerts@example.invalid', enabled => 0 },
			{ name => 'Team webhook', type => 'webhook',
			  address => 'http://127.0.0.1:9/notification-preview',
			  enabled => 0 },
		) {
			push @$targets, $store->save_target($target, $db)->{id};
			}
		# Save target IDs for reuse and scoped cleanup.
		$db->do('INSERT INTO metadata VALUES (?, ?)', undef,
			$target_key,
			Cloudmin::Notifications::encode($targets));
		}
	my ($added, $receipts) = ( 0, 0 );
	for my $n (1 .. $count) {
		# Mix numeric readings, status changes and muted events on
		# every page.
		my ($metric, $name, $threshold, $comparison, $bad, $good) =
			@{$cases[($n - 1) % @cases]};
		my $phase = $metric eq 'job_failed'
			? 'failed'
			: $n % 3 == 0
				? 'resolved'
				: $n % 3 == 1 ? 'firing' : 'reminder';
		# Empty targets prevent sends; events are two minutes apart.
		my $id = Cloudmin::Notifications::event($db,
			{ id => 'history-preview', name => "$name $n",
			  metric => $metric, threshold => $threshold,
			  comparison => $comparison, duration => 5,
			  severity => $n % 4 ? 'warning' : 'error',
			  targets => [ ] },
			{ owner => $guest, subject => "$guest:$metric",
			  label => $vm->{name}.
				($metric eq 'filesystem_free' ? ' /var' : ''),
			  value => $phase eq 'resolved' ? $good : $bad },
			$phase, time() - ($count - $n + 1) * 120, $prefix.$n,
			$n % 5 == 0 ? 'guest' : undef);
		# Duplicate source IDs return undef, not a new event.
		$added++ if defined($id);
		# Reload the event so new receipts keep its saved
		# timestamp and mute state on repeated runs.
		my ($event_id, $record) = $db->selectrow_array(
			'SELECT id, record FROM events WHERE owner = ? AND source = ?',
			undef, $guest, $prefix.$n);
		my $event = Cloudmin::Notifications::decode($record);
		my @destinations = $n % 7 == 0
			? @$targets : ( $targets->[$n % 2] );
		for my $i (0 .. $#destinations) {
			# Vary delivery results without queuing messages.
			my $state = $event->{silenced}
				? 'muted'
				: (qw(sent sent failed cancelled))[($n + $i) % 4];
			my $error = $state eq 'failed' ? 'Delivery expired' : '';
			my $attempts = $state eq 'failed'
				? 6 : $state eq 'sent' ? 1 : 0;
			# Keep existing receipts and count only new ones.
			$db->do('INSERT OR IGNORE INTO deliveries
				(event, target, state, attempts, due, error) VALUES (?, ?, ?, ?, ?, ?)',
				undef, $event_id, $destinations[$i], $state,
				$attempts, $event->{created}, $error);
			$receipts += $db->selectrow_array('SELECT changes()');
			}
		}
	return [ $added, $receipts ];
	});
print "Added $result->[0] sample notifications and $result->[1] delivery results ".
	"for $vm->{name}; no deliveries queued\n";
