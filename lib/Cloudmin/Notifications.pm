package Cloudmin::Notifications;

# Store rules, current problems, event history and delivery results on disk.
use strict;
use warnings;

use JSON::PP ();
use Fcntl qw(:DEFAULT :flock O_NOFOLLOW);
use File::Path qw(make_path);
use Sys::Hostname qw(hostname);
use File::Basename qw(dirname);
require(dirname(__FILE__).'/NotificationTypes.pm');

# new(class, directory => path) creates a store for the supplied data directory.
# The required directory path is not opened until the first read or write.
sub new
{
my ($class, %args) = @_;
die "Notification directory is required\n" unless $args{directory};
return bless \%args, $class;
}

# encode(value) returns stable JSON for stored records and rule comparison.
sub encode
{
return JSON::PP->new->canonical->utf8->encode($_[0]);
}

# decode(json) decodes a stored UTF-8 JSON record.
sub decode
{
return JSON::PP->new->utf8->decode($_[0]);
}

# id() creates an opaque identifier without relying on process or clock values.
sub id
{
open(my $fh, '<:raw', '/dev/urandom') or die "Cannot create notification ID\n";
read($fh, my $bytes, 16) == 16 or die "Cannot create notification ID\n";
close($fh);
return unpack('H*', $bytes);
}

# text(value, label, limit, [empty]) validates a single-line string.
# limit counts characters; empty defaults to false. label names input errors.
sub text
{
my ($value, $label, $limit, $empty) = @_;
$value = '' unless defined($value);
die "Invalid $label\n" if ref($value) || length($value) > $limit ||
	$value =~ /[\x00-\x1f\x7f]/ || (!$empty && !length($value));
return "$value";
}

# number(value, label, default, min, [max]) validates a decimal number.
# Omit max when the setting imposes no additional maximum. Missing or empty
# values use default; at most three decimal places are allowed.
sub number
{
my ($v, $label, $default, $min, $max) = @_;
$v = $default unless defined($v) && length($v);
die "Invalid $label\n" if ref($v) ||
	$v !~ /\A\d{1,12}(?:\.\d{1,3})?\z/ || $v < $min ||
	defined($max) && $v > $max;
return 0 + $v;
}

# flag(value, default) handles form integers and JSON booleans consistently.
# Return default for undef; otherwise accept only 0, 1 or a JSON boolean.
sub flag
{
my ($v, $default) = @_;
return $default unless defined($v);
return $v ? 1 : 0 if JSON::PP::is_bool($v);
die "Invalid enabled value\n" if ref($v) || $v !~ /\A[01]\z/;
return 0 + $v;
}

# connect(self, write) opens private SQLite storage; true write allows changes.
# A read returns undef when the database or its initial schema is absent.
# A write creates the schema or upgrades it to version 3. Reads accept
# versions 1 to 3 without upgrading.
sub connect
{
my ($self, $write) = @_;
my $dir = $self->{directory};

# Empty read-only views must not create notification state.
my $path = "$dir/notifications.sqlite";
return undef if !$write && !-e $path;
# Refuse links and broadly readable storage because it holds tokens and
# private URLs.
die "Unsafe notification directory\n" if -l $dir;
make_path($dir, { mode => 0700 }) unless -d $dir;
die "Notification directory must be private\n"
	if ((stat($dir))[2] & 0077);
die "Unsafe notification database\n" if -l $path;
if ($write) {
	# O_NOFOLLOW rejects a symlink created since the check above.
	sysopen(my $fh, $path, O_RDWR | O_CREAT | O_NOFOLLOW, 0600)
		or die "Cannot open notification database\n";
	die "Notification database must be private\n"
		if ((stat($fh))[2] & 0077);
	close($fh);
	}
# Open the existing file. Readers need write access so SQLite can recover
# interrupted writes. query_only still prevents readers from changing data.
require DBI;
my $db = DBI->connect("dbi:SQLite:dbname=$path", '', '', {
	RaiseError => 1, PrintError => 0, AutoCommit => 1,
	sqlite_open_flags => 2,
});
# Wait up to five seconds for another connection's commit.
$db->do('PRAGMA busy_timeout = 5000');
$db->do('PRAGMA foreign_keys = ON');
$db->do('PRAGMA query_only = ON') unless $write;
my ($version) = $db->selectrow_array('PRAGMA user_version');
die "Unsupported notification database version\n" if $version > 3;
if (!$write && !$version) {
	# A first writer may still be publishing the schema.
	$db->disconnect();
	return undef;
	}
if ($write) {
	# Keep deleted webhook credentials out of reusable SQLite pages.
	$db->do('PRAGMA secure_delete = ON');
	$db->do('PRAGMA synchronous = FULL');
	}
if ($write && $version < 3) {
	# Create or upgrade the schema and instance identity in one transaction.
	$db->do('BEGIN IMMEDIATE');
	$db->do('CREATE TABLE IF NOT EXISTS targets
		(id TEXT PRIMARY KEY, record TEXT NOT NULL)');
	$db->do('CREATE TABLE IF NOT EXISTS rules
		(id TEXT PRIMARY KEY, record TEXT NOT NULL)');
	# Keep changing incident state separate from saved events.
	$db->do('CREATE TABLE IF NOT EXISTS states
		(rule TEXT NOT NULL, subject TEXT NOT NULL, record TEXT NOT NULL,
		 PRIMARY KEY(rule, subject))');
	$db->do('CREATE TABLE IF NOT EXISTS events
		(id INTEGER PRIMARY KEY AUTOINCREMENT, source TEXT UNIQUE,
		 owner TEXT NOT NULL, created INTEGER NOT NULL, record TEXT NOT NULL)');
	$db->do('CREATE INDEX IF NOT EXISTS events_owner ON events(owner, id)');
	# Each destination has its own retry state;
	# deleting an event removes it.
	$db->do('CREATE TABLE IF NOT EXISTS deliveries
		(event INTEGER NOT NULL REFERENCES events(id) ON DELETE CASCADE,
		 target TEXT NOT NULL, state TEXT NOT NULL, attempts INTEGER NOT NULL,
		 due INTEGER NOT NULL, error TEXT NOT NULL DEFAULT \'\',
		 PRIMARY KEY(event, target))');
	$db->do('CREATE INDEX IF NOT EXISTS deliveries_due
		ON deliveries(state, due)');
	# Persist scan cursors and planned downtime across worker restarts.
	$db->do('CREATE TABLE IF NOT EXISTS metadata
		(key TEXT PRIMARY KEY, value TEXT NOT NULL)');
	$db->do('CREATE TABLE IF NOT EXISTS suppressions
		(owner TEXT PRIMARY KEY, until_time INTEGER NOT NULL)');
	# The instance ID distinguishes webhook events from different hosts.
	$db->do('INSERT OR IGNORE INTO metadata VALUES (?, ?)', undef,
		'instance', encode(id()));
	# Store mute intervals. Zero until_time means the mute has not ended.
	# Upgrades keep existing events and receipts.
	$db->do('CREATE TABLE IF NOT EXISTS mutes
		(owner TEXT NOT NULL, start_time INTEGER NOT NULL,
		 until_time INTEGER NOT NULL)');
	$db->do('CREATE INDEX IF NOT EXISTS mutes_owner
		ON mutes(owner, until_time)');
	if ($version == 2) {
		# Version 2 came from an unreleased build with timed mutes.
		# Keep its active mutes as manual ones with no end time.
		$db->do('UPDATE mutes SET until_time = 0 WHERE until_time > ?',
			undef, time());
		# Drop its schedule table and each rule's schedule list.
		$db->do('DROP TABLE IF EXISTS windows');
		for my $row (@{$db->selectall_arrayref('SELECT id, record FROM rules')}) {
			my $rule = decode($row->[1]);
			delete $rule->{windows};
			$db->do('UPDATE rules SET record = ? WHERE id = ?',
				undef, encode($rule), $row->[0]);
			}
		}
	$db->do('PRAGMA user_version = 3');
	$db->commit();
	}
return $db;
}

# transaction(self, callback) runs callback(database) under a write lock.
# Commit changes and return the callback's scalar result on success.
# On failure, roll back and rethrow the original error.
sub transaction
{
my ($self, $callback) = @_;
my $db = $self->connect(1);
$db->do('BEGIN IMMEDIATE');
my $result;
my $ok = eval { $result = $callback->($db); $db->commit(); 1 };
# Cleanup must not replace the error raised by the callback or commit.
my $error = $@;
eval { $db->rollback() } unless $ok;
$db->disconnect();
die $error unless $ok;
return $result;
}

# records(database, table) returns saved rules or targets in ID order.
# table must be rules or targets. An undef database returns an empty array.
sub records
{
my ($db, $table) = @_;
die "Invalid notification table\n" unless $table =~ /\A(?:rules|targets)\z/;
return [ ] unless $db;
return [ map { decode($_->[0]) }
	@{$db->selectall_arrayref("SELECT record FROM $table ORDER BY id")} ];
}

# target(self, id) reads one destination, including its saved token.
# The editor must check host and management access before calling this method.
sub target
{
my ($self, $id) = @_;
die "Invalid target ID\n" unless defined($id) && !ref($id) &&
	$id =~ /\A[a-f0-9]{32}\z/;
my $db = $self->connect(0);
my ($json) = $db ? $db->selectrow_array(
	'SELECT record FROM targets WHERE id = ?', undef, $id) : ();
$db->disconnect() if $db;
die "Notification destination not found\n" unless defined($json);
return decode($json);
}

# configuration(self) returns saved rules and destinations for host viewers.
# Each destination reports token presence and delivery status, but no token.
sub configuration
{
my ($self) = @_;
my $db = $self->connect(0);
my $targets = records($db, 'targets');
for my $t (@$targets) {
	# Lists and API responses report token presence without its value.
	$t->{has_secret} = length(delete($t->{secret}) || '') ? 1 : 0;
	if (Cloudmin::NotificationTypes::private_address($t->{type})) {
		# Show only the hostname of private URLs. The editor checks
		# access before loading the full address.
		require URI;
		$t->{address_host} = URI->new(delete($t->{address}))->host;
		$t->{has_private_address} = 1;
		}
	elsif ($t->{type} eq 'pushover') {
		# Pushover user and group keys are private credentials.
		delete($t->{address});
		$t->{has_private_address} = 1;
		}
	# Keep the last attempted delivery independent of history pagination.
	my ($json) = $db->selectrow_array(
		'SELECT value FROM metadata WHERE key = ?', undef,
		'delivery:'.$t->{id});
	my $last = defined($json) ? decode($json) : undef;
	my $receipt = $last && $db->selectrow_hashref(
		'SELECT state, error FROM deliveries WHERE event = ?
		 AND target = ?', undef, $last->{event}, $t->{id});
	if ($receipt) {
		# Read the current receipt so retries and
		# cancellation stay accurate.
		$t->{last_delivery} = { %$last, %$receipt };
		}
	else {
		# Without a saved attempt, use the newest receipt's state. Its
		# due time does not show when a delivery was attempted.
		$t->{last_delivery} = $db->selectrow_hashref(
			'SELECT event, state, error FROM deliveries WHERE target = ?
			 ORDER BY event DESC LIMIT 1', undef, $t->{id});
		}
	}
my $result = { targets => $targets, rules => records($db, 'rules') };
$db->disconnect() if $db;
return $result;
}

# save_target(self, input, [db]) validates and saves a destination hashref.
# An existing id updates the record; omitting id creates one. Optional db reuses
# a caller's transaction, otherwise this method opens its own.
sub save_target
{
my ($self, $in, $db) = @_;
die "Expected a target object\n" unless ref($in) eq 'HASH';
# save(db) validates and writes inside the caller's transaction or a new one.
my $save = sub {
	my ($db) = @_;
	# Resolve edits before validating the destination and its saved token.
	my $id = text($in->{id} || id(), 'target ID', 32);
	die "Invalid target ID\n" unless $id =~ /\A[a-f0-9]{32}\z/;
	my ($old) = grep { $_->{id} eq $id } @{records($db, 'targets')};
	die "Notification destination not found\n" if $in->{id} && !$old;
	# Each supported transport has a fixed request format.
	my $type = text($in->{type}, 'target type', 16);
	die "Unknown notification delivery method\n" unless
		grep { $_ eq $type } Cloudmin::NotificationTypes::transports();
	my $address = text($in->{address}, 'target address', 2048);
	# Invalid structured tokens must not be mistaken
	# for an empty replacement.
	my $token_label = $type eq 'telegram' ? 'bot token'
		: $type eq 'pushover' || $type eq 'gotify'
			? 'application token' : 'webhook token';
	die "Invalid $token_label\n" if ref($in->{secret});
	# A submitted token replaces the saved value. API callers may omit it
	# to keep a saved token for the same method and destination address.
	my $secret = exists($in->{secret})
		? text($in->{secret}, $token_label, 2048, 1)
		: $old && $old->{type} eq $type && $old->{address} eq $address
			? $old->{secret} : '';
	# Apply explicit removal before checking whether
	# this method needs a token.
	$secret = '' if flag($in->{clear_secret}, 0);
	if ($type eq 'email') {
		# A target is one mailbox, not an arbitrary mail header.
		die "Enter one email address\n" unless $address =~
			/\A[A-Za-z0-9.!#\$%&'*+\/=?^_`{|}~-]+\@[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\z/;
		$secret = '';
		}
	elsif ($type eq 'telegram') {
		# Telegram identifiers fit in 52 bits. Compare a copy so the
		# saved address remains a string in configuration responses.
		my $numeric = $address =~ /\A-?[1-9][0-9]{0,15}\z/ &&
			abs("$address") <= 4503599627370495;
		die "Enter a Telegram chat ID or \@username\n" unless $numeric ||
			$address =~ /\A\@[A-Za-z0-9_]{4,32}\z/;
		# The bot token becomes a URL path
		# segment, never a bearer header.
		die "Enter a valid Telegram bot token\n" unless defined($secret) &&
			$secret =~ /\A[0-9]+:[A-Za-z0-9_-]+\z/;
		}
	elsif ($type eq 'pushover') {
		# Recipient keys and tokens contain 30 ASCII letters or digits.
		# Never include their values in validation errors.
		die "Enter a valid Pushover user or group key\n"
			unless $address =~ /\A[A-Za-z0-9]{30}\z/;
		die "Enter a valid Pushover application token\n"
			unless $secret =~ /\A[A-Za-z0-9]{30}\z/;
		}
	else {
		# Allow query strings only for private chat URLs. Reject
		# embedded login credentials and fragments;
		# delivery handles redirects.
		require URI;
		my $url = URI->new($address);
		my $url_error = $type eq 'gotify'
			? 'Enter a Gotify server URL with no query or fragment'
			: 'Enter an HTTP or HTTPS webhook URL';
		die "$url_error\n" unless
			$url->scheme && $url->scheme =~ /\Ahttps?\z/ &&
			$url->host && !$url->userinfo && !$url->fragment &&
			(!$url->query ||
			 Cloudmin::NotificationTypes::private_address($type)) &&
			$address !~ /\s/;
		if ($type eq 'gotify') {
			# Gotify application tokens travel in a request header.
			die "Enter a valid Gotify application token\n"
				unless $secret =~ /\A[!-~]+\z/;
			die "Gotify server URLs require HTTPS\n"
				unless $url->scheme eq 'https';
			}
		# Private chat URLs and tokens must not travel over plain HTTP.
		die "Chat webhook URLs require HTTPS\n" if
			Cloudmin::NotificationTypes::private_address($type) &&
			$url->scheme ne 'https';
		die "Webhook tokens require HTTPS\n"
			if length($secret || '') && $url->scheme ne 'https';
		}
	# Store only validated fields, with new destinations enabled by default.
	my $target = { id => $id, name => text($in->{name}, 'target name', 100),
		type => $type, address => $address, secret => $secret || '',
		enabled => flag($in->{enabled}, 1) };
	$db->do('INSERT OR REPLACE INTO targets VALUES (?, ?)', undef,
		$id, encode($target));
	# Disabling a destination cancels its pending deliveries immediately.
	$db->do("UPDATE deliveries SET state = 'cancelled' WHERE target = ?
		AND state IN ('queued', 'sending')", undef, $id)
		unless $target->{enabled};
	return { id => $id };
	};
return $db ? $save->($db) : $self->transaction($save);
}

# set_target_enabled(self, id, enabled) changes only the destination switch.
# Reload the stored record inside the transaction to preserve its other fields.
sub set_target_enabled
{
my ($self, $id, $enabled) = @_;
$id = text($id, 'target ID', 32);
die "Invalid target ID\n" unless $id =~ /\A[a-f0-9]{32}\z/;
$enabled = flag($enabled, 0);
return $self->transaction(sub {
	# callback(db) reloads the destination before changing its enabled flag.
	my ($db) = @_;
	my ($target) = grep { $_->{id} eq $id } @{records($db, 'targets')};
	die "Notification destination not found\n" unless $target;
	# Reuse validation and cancellation without
	# exposing or replacing secrets.
	return $self->save_target({ %$target, enabled => $enabled }, $db);
	});
}

# set_rule_enabled(self, id, enabled, now) changes a stored rule's switch.
# now is the new check period's start time, in Unix seconds.
sub set_rule_enabled
{
my ($self, $id, $enabled, $now) = @_;
$id = text($id, 'rule ID', 32);
die "Invalid rule ID\n" unless $id =~ /\A[a-f0-9]{32}\z/;
$enabled = flag($enabled, 0);
return $self->transaction(sub {
	# callback(db) preserves settings and skips an unchanged enabled flag.
	my ($db) = @_;
	my ($rule) = grep { $_->{id} eq $id } @{records($db, 'rules')};
	die "Notification rule not found\n" unless $rule;
	# Repeated submissions must not restart a running rule's baseline.
	return { id => $id } if $rule->{enabled} == $enabled;
	return $self->save_rule({ %$rule, enabled => $enabled }, $now, undef, $db);
	});
}

# save_rule(self, input, now, [target], [database]) saves a rule hashref.
# input.id updates an existing rule; omitting it creates one. Optional target is
# a new destination hash saved in the same transaction. Optional database reuses
# an open transaction; otherwise this method opens one. Both saves roll back on
# failure. Edits restart checks at now in Unix seconds.
sub save_rule
{
my ($self, $in, $now, $target, $db) = @_;
die "Expected a rule object\n" unless ref($in) eq 'HASH';
# save(db) validates and writes inside the caller's transaction or a new one.
my $save = sub {
	my ($db) = @_;
	# Updating an unknown ID must not create a replacement rule by accident.
	my $id = text($in->{id} || id(), 'rule ID', 32);
	die "Invalid rule ID\n" unless $id =~ /\A[a-f0-9]{32}\z/;
	my ($old) = grep { $_->{id} eq $id } @{records($db, 'rules')};
	die "Notification rule not found\n" if $in->{id} && !$old;
	# Reject conditions the worker cannot check.
	my $metric = text($in->{metric}, 'condition', 32);
	my $definition = Cloudmin::NotificationTypes::metric($metric);
	die "Unknown notification condition\n" unless $definition;
	my $scope = $in->{scope};
	if (ref($scope) eq 'ARRAY') {
		# Explicit guest sets stay fixed when new guests are added.
		die "Choose at least one guest\n" unless @$scope;
		my %seen;
		for my $guest (@$scope) {
			# Accept UUIDs only, never host or wildcard selectors.
			text($guest, 'guest UUID', 36);
			die "Invalid notification guest\n" unless $guest =~
				/\A[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}\z/;
			}
		$scope = [ grep { !$seen{$_}++ } @$scope ];
		}
	else {
		# A scalar scope is host, guests, all or one guest UUID.
		$scope = text($scope || 'host', 'scope', 40);
		die "Invalid notification scope\n" unless $scope =~
			/\A(?:host|guests|all|[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12})\z/;
		die "This condition requires guests\n" if
			$metric =~ /\Aguest_/ && $scope =~ /\A(?:host|all)\z/;
		die "Choose job failures to monitor the host and all guests\n"
			if $scope eq 'all' && $metric ne 'job_failed';
		}
	# Pools, load averages and collector health can monitor only the host.
	my $host = !ref($scope) && $scope eq 'host';
	die "Pool rules require the host scope\n"
		if $metric =~ /\Apool/ && !$host;
	die "This condition requires the host scope\n"
		if $definition->{host_only} && !$host;
	# Default to high usage or low free space. Status checks always use ge.
	my $comparison = text($in->{comparison} || $definition->{comparison},
		'comparison', 2);
	die "Choose at or above, or at or below\n"
		unless $comparison =~ /\A(?:ge|le)\z/;
	$comparison = 'ge' unless $definition->{numeric};
	my $percent = $definition->{unit} eq '%';
	my $threshold = number($in->{threshold}, 'threshold',
		$definition->{threshold}, $percent ? 0.1 : 0,
		$percent ? 100 : undef);
	# Severity changes the message's importance, not when the rule fires.
	my $severity = text($in->{severity} || 'warning', 'severity', 16);
	die "Invalid severity\n" unless $severity =~ /\A(?:notice|warning|error)\z/;
	if (defined($target)) {
		# Inline creation cannot replace an existing destination.
		die "Expected a new notification destination\n"
			unless ref($target) eq 'HASH' && !exists($target->{id});
		my $saved = $self->save_target($target, $db);
		$in = { %$in, targets => [ $saved->{id} ] };
		}
	# Accept API arrays and form lists, but require saved destination IDs.
	my $targets = $in->{targets};
	$targets = [ split(/[,\s\0]+/, $targets || '') ] unless ref($targets);
	die "Choose notification destinations\n"
		unless ref($targets) eq 'ARRAY' && @$targets;
	my %valid = map { $_->{id} => 1 } @{records($db, 'targets')};
	my %seen;
	for my $target (@$targets) {
		die "Unknown notification destination\n"
			if ref($target) || !$valid{$target};
		}
	# A host filesystem defaults to root and must be an absolute path.
	my $device = text($in->{device}, 'device', 512, 1);
	$device = '/' if $metric =~ /\Afilesystem/ && $host && !$device;
	die "Enter an absolute filesystem path\n" if $metric =~ /\Afilesystem/ &&
		$host && $device !~ m{\A/};
	# Normalize timing and flags before replacing
	# configuration or incident state.
	my $rule = { id => $id, name => text($in->{name}, 'rule name', 100),
		metric => $metric, scope => $scope, device => $device,
		severity => $severity,
		targets => [ grep { !$seen{$_}++ } @$targets ],
		enabled => flag($in->{enabled}, 1),
		recovery => flag($in->{recovery}, 1),
		threshold => $threshold, comparison => $comparison,
		duration => number($in->{duration}, 'duration', 5, 0),
		reminder => number($in->{reminder}, 'reminder', 0, 0),
		cooldown => number($in->{cooldown}, 'cooldown', 5, 0),
		created => $now };
	# Edits apply to future events, and cancel obsolete queued messages.
	cancel_rule($db, $id);
	$db->do('INSERT OR REPLACE INTO rules VALUES (?, ?)', undef,
		$id, encode($rule));
	$db->do('DELETE FROM states WHERE rule = ?', undef, $id);
	return { id => $id };
	};
return $db ? $save->($db) : $self->transaction($save);
}

# remove(self, kind, id) deletes a rule or destination while keeping history.
# Cancel its pending deliveries; a destination still used by a rule is rejected.
sub remove
{
my ($self, $kind, $id) = @_;
die "Invalid notification object\n" unless $kind =~ /\A(?:rule|target)\z/;
$id = text($id, 'notification ID', 32);
return $self->transaction(sub {
	# callback(db) checks references and removes the selected saved record.
	my ($db) = @_;
	if ($kind eq 'target') {
		# Removing a referenced target would silently disable a rule.
		die "Remove this destination from its rules first\n" if grep {
			my $r = $_; grep { $_ eq $id } @{$r->{targets}}
			} @{records($db, 'rules')};
		$db->do("UPDATE deliveries SET state = 'cancelled' WHERE target = ?
			AND state IN ('queued', 'sending')", undef, $id);
		$db->do('DELETE FROM metadata WHERE key = ?', undef,
			'delivery:'.$id);
		}
	else {
		# Deleting a rule also removes its current
		# incidents and pending messages.
		cancel_rule($db, $id);
		$db->do('DELETE FROM states WHERE rule = ?', undef, $id);
		}
	$db->do("DELETE FROM ${kind}s WHERE id = ?", undef, $id);
	return { id => $id };
	});
}

# cancel_rule(database, id) cancels pending deliveries for a rule ID.
# A transport already running outside the transaction may still finish.
sub cancel_rule
{
my ($db, $id) = @_;
for my $row (@{$db->selectall_arrayref("SELECT DISTINCT e.id, e.record
	FROM events e JOIN deliveries d ON d.event = e.id
	WHERE d.state IN ('queued', 'sending')")}) {
	next unless decode($row->[1])->{rule} eq $id;
	$db->do("UPDATE deliveries SET state = 'cancelled'
		WHERE event = ? AND state IN ('queued', 'sending')", undef, $row->[0]);
	}
}

# event(database, rule, observation, phase, now, [source], [quiet])
# records an event and a receipt for each enabled destination of the rule.
# rule supplies saved settings; observation supplies owner, subject, label and
# value. phase identifies firing, resolved, reminder, failed or test. now is
# Unix seconds. source prevents duplicate job-failure events; omit it for
# sampled conditions. The event is recorded as muted when a mute is active at
# now, or when quiet supplies a mute reason, all or guest, after the mute has
# ended. Test events are never muted.
# Return the new event ID, or undef for a duplicate.
sub event
{
my ($db, $rule, $obs, $phase, $now, $source, $quiet) = @_;
my ($instance) = $db->selectrow_array(
	'SELECT value FROM metadata WHERE key = ?', undef, 'instance');
# The worker clock has fractions. Receivers always get whole seconds.
my $created = int($now);
# Save the rule and affected resource so later edits do not change old events.
my $record = { version => 1, host => hostname(),
	instance => decode($instance), rule => $rule->{id},
	name => $rule->{name},
	owner => $obs->{owner}, subject => $obs->{subject},
	label => $obs->{label},
	metric => $rule->{metric}, threshold => $rule->{threshold},
	comparison => $rule->{comparison} || 'ge',
	unit => (Cloudmin::NotificationTypes::metric($rule->{metric}) || { })->{unit},
	# Job failures alert at once, so their events carry no duration.
	duration => $rule->{metric} eq 'job_failed' ? undef : $rule->{duration},
	value => $obs->{value}, phase => $phase,
	severity => $phase eq 'resolved' ? 'notice' : $rule->{severity},
	created => $created };
# Muted events stay in history, and their receipts are never queued.
my $silenced = $phase eq 'test' ? undef
	: $quiet || silence($db, $obs->{owner}, $now);
$record->{silenced} = $silenced if $silenced;
# Repeated job scans must not create another event or delivery receipt.
$db->do('INSERT OR IGNORE INTO events(source, owner, created, record)
	VALUES (?, ?, ?, ?)', undef, $source, $obs->{owner}, $created,
	encode($record));
return unless $db->selectrow_array('SELECT changes()');
my $id = $db->sqlite_last_insert_rowid();
# Only destinations enabled at event creation receive a queued copy.
my %targets = map { $_->{id} => $_ } @{records($db, 'targets')};
for my $target (@{$rule->{targets}}) {
	next unless $targets{$target} && $targets{$target}->{enabled};
	$db->do('INSERT INTO deliveries(event, target, state, attempts, due)
		VALUES (?, ?, ?, 0, ?)', undef, $id, $target,
		$silenced ? 'muted' : 'queued', $now);
	}
return $id;
}

# silence_context(database, now) snapshots the scopes muted at Unix time now.
# Return a hash keyed by each muted scope, all or a guest UUID. Stores before
# version 2 have no mutes. Zero until_time means the mute has not ended.
sub silence_context
{
my ($db, $now) = @_;
return { } unless $db && $db->selectrow_array('PRAGMA user_version') >= 2;
return { map { $_->[0] => 1 }
	@{$db->selectall_arrayref('SELECT DISTINCT owner FROM mutes
	WHERE start_time <= ? AND (until_time = 0 OR until_time > ?)',
	undef, $now, $now)} };
}

# silence(database, owner, now, [context]) returns all, guest or undef.
# owner is host or a guest UUID; only the global mute covers the host.
# Optional context reuses a silence_context() snapshot from the same
# transaction. A global mute takes precedence over a guest's own mute.
sub silence
{
my ($db, $owner, $now, $context) = @_;
$context ||= silence_context($db, $now);
return $context->{all} ? 'all' : $context->{$owner} ? 'guest' : undef;
}

# mute_event(database, id, event, reason) mutes an event's pending deliveries.
# id is the event ID, event its decoded record, and reason all or guest.
# Sent and failed copies stay unchanged. An active incident is flagged to
# alert again after the mute ends. A transport already running may finish.
sub mute_event
{
my ($db, $id, $event, $reason) = @_;
# Mark queued and leased copies muted, and save the reason in the event.
$db->do("UPDATE deliveries SET state = 'muted', error = ''
	WHERE event = ? AND state IN ('queued', 'sending')", undef, $id);
$event->{silenced} = $reason;
$db->do('UPDATE events SET record = ? WHERE id = ?', undef, encode($event), $id);
my ($json) = $db->selectrow_array('SELECT record FROM states
	WHERE rule = ? AND subject = ?', undef, $event->{rule}, $event->{subject});
if ($json) {
	# Flag a still-active incident and keep the rest of its state.
	my $state = decode($json);
	$state->{notify_after_mute} = $reason if $state->{active};
	$db->do('UPDATE states SET record = ? WHERE rule = ? AND subject = ?',
		undef, encode($state), $event->{rule}, $event->{subject});
	}
}

# mute(self, owner, enabled, now) starts or ends a manual mute.
# owner is a guest UUID, or all for the host and every guest. enabled is 0 or
# 1, and now is Unix seconds. A mute has no expiry. Ending one keeps its past
# interval for delayed job-failure scans. Return the scope and new state.
sub mute
{
my ($self, $owner, $enabled, $now) = @_;
# Accept only an explicit scope, so bad input never mutes everything.
$owner = lc(text($owner, 'mute scope', 36));
die "Use a guest UUID or all for the mute scope\n" unless $owner eq 'all' ||
	$owner =~ /\A[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}\z/;
$enabled = flag($enabled, 0);
return $self->transaction(sub {
	# callback(db) saves the mute and updates pending alerts in its scope.
	my ($db) = @_;
	my $active = silence_context($db, $now);
	if (!$enabled) {
		# Close this scope's open interval. Other scopes are unchanged.
		$db->do('UPDATE mutes SET until_time = ? WHERE owner = ?
			AND (until_time = 0 OR until_time > ?)', undef, $now, $owner, $now);
		}
	elsif (!$active->{$owner}) {
		# Open an interval with no end. Repeating a mute keeps the
		# existing interval.
		$db->do('INSERT INTO mutes VALUES (?, ?, 0)', undef, $owner, $now);
		}
	if ($enabled) {
		# Mute pending alerts in this scope at once, including retries
		# due much later. Destination tests still send.
		my $reason = $owner eq 'all' ? 'all' : 'guest';
		for my $row (@{$db->selectall_arrayref("SELECT DISTINCT e.id, e.record
			FROM events e JOIN deliveries d ON d.event = e.id
			WHERE d.state IN ('queued', 'sending')")}) {
			my $event = decode($row->[1]);
			next if $event->{phase} eq 'test';
			next unless $owner eq 'all' || $event->{owner} eq $owner;
			mute_event($db, $row->[0], $event, $reason);
			}
		# Mark current incidents muted. Flag active ones to alert again
		# at the first fresh check after unmuting.
		for my $row (@{$db->selectall_arrayref(
			'SELECT rule, subject, record FROM states')}) {
			my $state = decode($row->[2]);
			next unless $owner eq 'all' || $state->{owner} eq $owner;
			$state->{muted} = $reason;
			$state->{notify_after_mute} = $reason if $state->{active};
			$db->do('UPDATE states SET record = ? WHERE rule = ? AND subject = ?',
				undef, encode($state), @$row[0, 1]);
			}
		}
	return { id => $owner, muted => $enabled };
	});
}

# suppress(self, owner, until) pauses alerts for a guest's planned downtime.
# owner is a guest UUID. A positive until is the Unix time a reboot grace
# period ends. Zero waits for the guest to run again. A negated start time
# marks a requested stop: a later check that sees the guest stopped pauses
# alerts until restart, and a check that still sees it running after two
# minutes ends the pause.
sub suppress
{
my ($self, $owner, $until) = @_;
$self->transaction(sub {
	# callback(db) saves this guest's pause across worker restarts.
	$_[0]->do('INSERT OR REPLACE INTO suppressions VALUES (?, ?)',
		undef, $owner, $until);
	});
}

# evaluate(self, observations, now, suppressed, [timing]) checks rule state.
# observations maps rule IDs to arrays of owner, subject, label, value and
# running readings; an undef value is unknown. now is Unix seconds. suppressed
# maps guest UUIDs with unfinished jobs to true. Missing readings pause checks
# without clearing an active alert. timing sets max_gap in seconds, default 150,
# and skip_cached, default false, to retain collector-based state while
# waiting for a new fresh sample. Optional rule_snapshot maps rule IDs to their
# canonical JSON captured before collecting readings. Rules added or edited
# since then wait for the next run. Muted owners are still checked, but their
# events are recorded as muted.
sub evaluate
{
my ($self, $observations, $now, $suppressed, $timing) = @_;
$timing ||= { };
my $max_gap = $timing->{max_gap} || 150;
my $expected = $timing->{rule_snapshot};
return $self->transaction(sub {
	# callback(db) saves state changes and their events in one transaction.
	my ($db) = @_;
	# Read the active mutes once for every reading in this run.
	my $silences = silence_context($db, $now);
	for my $rule (@{records($db, 'rules')}) {
		# Skip disabled rules. Job failure rules are handled
		# by failure(), not by readings.
		next unless $rule->{enabled} && $rule->{metric} ne 'job_failed';
		# Skip readings collected for an earlier version of this rule.
		next if $expected && (!exists($expected->{$rule->{id}}) ||
			$expected->{$rule->{id}} ne encode($rule));
		# Independent disk probes and the collector health clock must
		# run even between fresh collector updates.
		next if $timing->{skip_cached} &&
			$rule->{metric} ne 'collector_stale' &&
			!($rule->{metric} =~ /\Afilesystem/ &&
			  !ref($rule->{scope}) && $rule->{scope} eq 'host');
		my %seen;
		for my $obs (@{$observations->{$rule->{id}} || [ ]}) {
			my $subject = $obs->{subject};
			$seen{$subject} = 1;
			# Restore this subject's incident and any planned
			# power-action suppression.
			my ($json) = $db->selectrow_array('SELECT record FROM states
				WHERE rule = ? AND subject = ?', undef, $rule->{id}, $subject);
			my $s = $json ? decode($json) : { active => 0 };
			# Checks continue while muted. Save the mute for the
			# status badge, and flag an active incident to alert
			# again after unmuting.
			my $muted = silence($db, $obs->{owner}, $now, $silences);
			$s->{muted} = $muted;
			$s->{notify_after_mute} = $muted if $muted && $s->{active};
			my ($until) = $db->selectrow_array(
				'SELECT until_time FROM suppressions WHERE owner = ?',
				undef, $obs->{owner});
			if (defined($until) && $until < 0 && !$obs->{running}) {
				# The stop is now observed; remain quiet
				# until the guest runs again.
				$db->do('UPDATE suppressions SET until_time = 0 WHERE owner = ?',
					undef, $obs->{owner});
				$until = 0;
				}
			if (defined($until) && ($until > 0 && $until <= $now ||
				$until < 0 && $now > -$until + 120 ||
				!$until && $obs->{running})) {
				# End reboot grace, a requested stop that left the
				# guest running for two minutes, or a restart.
				$db->do('DELETE FROM suppressions WHERE owner = ?',
					undef, $obs->{owner});
				$until = undef;
				}
			my $paused = !defined($obs->{value}) ||
				$suppressed->{$obs->{owner}} || defined($until);
			if ($paused) {
				# Paused checks cannot confirm a recovery.
				delete $s->{since};
				$s->{status} = 'paused';
				# Prefer a known maintenance reason over a
				# generic missing reading.
				$s->{pause_reason} = defined($until)
					? $until > 0
						? 'planned_restart'
						: 'planned_stop'
					: $suppressed->{$obs->{owner}}
						? 'active_job' : 'unavailable';
				}
			else {
				# Fresh unsuppressed data can advance
				# or resolve the incident.
				delete $s->{pause_reason};
				my $definition =
					Cloudmin::NotificationTypes::metric($rule->{metric});
				my $boolean = $definition->{boolean};
				my $threshold = $boolean ? 1 : $rule->{threshold};
				my $below = !$boolean &&
					($rule->{comparison} || 'ge') eq 'le';
				# Percentages clear two percentage points past
				# the threshold. Other measurements use two
				# percent of the threshold value.
				my $margin = $boolean ? 1 : $definition->{unit} eq '%'
					? 2 : $threshold * .02;
				my $clear = $threshold + ($below ? $margin : -$margin);
				$clear = 0 if $clear < 0;
				# An active alert stays bad until the reading
				# passes the clear point. Without a margin, or
				# before an alert, compare with the threshold.
				my $bad = $s->{active} && $margin
					? $below ? $obs->{value} < $clear : $obs->{value} > $clear
					: $below ? $obs->{value} <= $threshold
						 : $obs->{value} >= $threshold;
				if ($bad) {
					# Gaps and backward clock changes break
					# the sustained interval.
					delete $s->{since} if !$s->{last} ||
						$now - $s->{last} > $max_gap || $now < $s->{last};
					$s->{since} = $now unless defined($s->{since});
					if (!$s->{active} &&
						$now - $s->{since} >= 60 * $rule->{duration} &&
						(!defined($s->{sent}) || $now - $s->{sent} >=
						60 * ($rule->{cooldown} || 0))) {
						# The duration and minimum gap
						# between alerts have passed.
						event($db, $rule, $obs, 'firing', $now, undef);
						$s->{active} = 1;
						$s->{sent} = $now;
						}
					elsif ($s->{active} && !$muted &&
					       $s->{notify_after_mute}) {
						# After a mute ends, alert once
						# for a still-active incident,
						# even without reminders.
						event($db, $rule, $obs, 'firing', $now, undef);
						$s->{sent} = $now;
						delete $s->{notify_after_mute};
						}
					elsif ($s->{active} && $rule->{reminder} &&
						$now - ($s->{sent} || 0) >= 60 * $rule->{reminder}) {
						# Repeat an active alert once
						# its reminder interval passes.
						event($db, $rule, $obs, 'reminder', $now, undef);
						$s->{sent} = $now;
						}
					# An alert raised while muted is
					# announced after unmuting.
					$s->{notify_after_mute} = $muted if $muted && $s->{active};
					$s->{status} = $s->{active} ? 'active' : 'pending';
					}
				else {
					# Clear active and pending conditions.
					# Report recovery only after an alert
					# and when recovery is enabled. The
					# recovery of an incident not announced
					# since its mute is recorded as muted.
					event($db, $rule, $obs, 'resolved', $now, undef,
						$s->{notify_after_mute})
						if $s->{active} && $rule->{recovery};
					$s->{active} = 0;
					delete $s->{notify_after_mute};
					delete $s->{since};
					$s->{status} = 'ok';
					}
				}
			# Save the latest reading even when paused, so the UI
			# shows current context.
			$s->{name} = $rule->{name};
			@$s{qw(owner label last value)} =
				($obs->{owner}, $obs->{label}, $now, $obs->{value});
			$db->do('INSERT OR REPLACE INTO states VALUES (?, ?, ?)',
				undef, $rule->{id}, $subject, encode($s));
			}
		# Missing devices or samples pause the last known state.
		for my $row (@{$db->selectall_arrayref('SELECT subject, record FROM
			states WHERE rule = ?', undef, $rule->{id})}) {
			next if $seen{$row->[0]};
			my $s = decode($row->[1]);
			my $cooldown = 60 * ($rule->{cooldown} || 0);
			if (!$s->{active} && (!defined($s->{sent}) ||
			    $now - $s->{sent} >= $cooldown)) {
				# Without an incident or cooldown to keep,
				# forget guests, guest mounts and pools that
				# are no longer reported, instead of listing
				# them as paused forever.
				$db->do('DELETE FROM states
					WHERE rule = ? AND subject = ?',
					undef, $rule->{id}, $row->[0]);
				next;
				}
			delete $s->{since};
			$s->{status} = 'paused';
			$s->{pause_reason} = 'unavailable';
			$db->do('UPDATE states SET record = ? WHERE rule = ? AND subject = ?',
				undef, encode($s), $rule->{id}, $row->[0]);
			}
		}
	return 1;
	});
}

# failure(self, source, owner, label, timestamp) records matching job failures.
# source identifies the failed job, owner is host or a guest UUID, and timestamp
# is Unix seconds. Repeated scans reuse each rule/source pair.
# label is the public failure description, truncated to 300 characters.
# A mute active at timestamp records the event as muted.
sub failure
{
my ($self, $source, $owner, $label, $now) = @_;
return $self->transaction(sub {
	# callback(db) records one event for each matching rule and failed job.
	my ($db) = @_;
	for my $r (@{records($db, 'rules')}) {
		# Match each selected guest without widening the rule's scope.
		my @scopes = ref($r->{scope}) eq 'ARRAY'
			? @{$r->{scope}} : ($r->{scope});
		next unless $r->{enabled} && $r->{metric} eq 'job_failed' &&
			$now >= $r->{created} && grep {
				$_ eq 'all' || $_ eq $owner ||
				$_ eq 'guests' && $owner ne 'host' } @scopes;
		event($db, $r, { owner => $owner, subject => $source,
			label => substr($label, 0, 300) }, 'failed', $now,
			$r->{id}.':'.$source);
		}
	return 1;
	});
}

# test_target(self, id, now, [send]) queues a test or sends it immediately.
# send(target, event), when supplied, performs delivery and throws on failure.
# Reserve an immediate test before a worker can send it. now is Unix seconds.
sub test_target
{
my ($self, $id, $now, $send) = @_;
my $work;
my $result = $self->transaction(sub {
	# callback(db) queues the test and optionally
	# reserves it for this caller.
	my ($db) = @_;
	my ($t) = grep { $_->{id} eq $id } @{records($db, 'targets')};
	die "Enable the notification destination before testing\n"
		unless $t && $t->{enabled};
	# A test has its own host event and does not depend
	# on a notification rule.
	my $event = event($db, { id => 'test', name => 'Test notification',
		metric => 'test', severity => 'notice', targets => [ $id ] },
		{ owner => 'host', subject => 'test', label => 'Cloudmin' },
		'test', $now, undef);
	if ($send) {
		# Reserve just this test, leaving unrelated queued alerts alone.
		$db->do("UPDATE deliveries SET state = 'sending', attempts = 1,
			due = ? WHERE event = ?", undef, $now + 300, $event);
		my ($json) = $db->selectrow_array(
			'SELECT record FROM events WHERE id = ?',
			undef, $event);
		$work = { event => $event, target => $id, attempts => 0,
			target_record => $t,
			event_record => { %{decode($json)}, id => $event } };
		}
	return { id => $event };
	});
if ($work) {
	# Record the delivery outcome and return a safe error on failure.
	my $error = $self->send_delivery($work, $send, $now);
	$result->{error} = $error if length($error);
	}
return $result;
}

# history(self, [owner], [after], [limit]) reads events and current incidents.
# owner is a guest UUID; omit it only for authorized host viewers. Without
# after, return the latest events; zero starts at the oldest.
# limit defaults to 100 and allows 1 to 500. muted is 1 when the owner's own
# mute is active, or the global mute when owner is omitted. all_muted is 1
# when the global mute is active.
sub history
{
my ($self, $owner, $after, $limit) = @_;
# A missing cursor selects the newest events. The cursor and limit must be
# whole numbers.
my $recent = !defined($after);
$after = number($after, 'notification cursor', 0, 0);
$limit = number($limit, 'notification limit', 100, 1, 500);
die "Use whole cursor and limit values\n" if int($after) != $after ||
	int($limit) != $limit;
# A store that was never written has no history.
my $db = $self->connect(0);
return { events => [ ], cursor => $after, states => [ ],
	muted => 0, all_muted => 0 } unless $db;
my @args = ( $after );
my $scope = '';
if (defined($owner)) {
	# Restrict guest history in SQL before decoding or
	# returning any records.
	$scope = ' AND owner = ?';
	push @args, $owner;
	}
# Cursor pages move forward; recent pages are reversed into ascending ID order.
my $rows = $db->selectall_arrayref('SELECT id, record FROM events
	WHERE id > ?'.$scope.' ORDER BY id '.($recent ? 'DESC' : 'ASC').
	' LIMIT ?', undef, @args, $limit);
@$rows = reverse @$rows if $recent;
my @events;
for my $row (@$rows) {
	my $event = { %{decode($row->[1])}, id => 0 + $row->[0] };
	# Delegates see their event, never host destinations or delivery errors.
	$event->{deliveries} = $db->selectall_arrayref(
		'SELECT target, state, attempts, error FROM deliveries WHERE event = ?',
		{ Slice => { } }, $row->[0]) unless defined($owner);
	push @events, $event;
	}
# Read current mutes, so badges change without waiting for the next reading.
my $silences = silence_context($db, time());
# Current incidents use the same guest restriction as historical events.
my @states;
for my $row (@{$db->selectall_arrayref(
	'SELECT rule, subject, record FROM states')}) {
	my $state = decode($row->[2]);
	next if defined($owner) && $state->{owner} ne $owner;
	$state->{muted} = silence($db, $state->{owner}, time(), $silences);
	push @states, { %$state, rule => $row->[0], subject => $row->[1] };
	}
# A guest reports its own mute; combined history reports the global mute.
my $muted = $silences->{defined($owner) ? $owner : 'all'} ? 1 : 0;
$db->disconnect();
return { events => \@events, states => \@states,
	muted => $muted, all_muted => $silences->{all} ? 1 : 0,
	cursor => @events ? $events[-1]->{id} : $after };
}

# deliver(self, send, now) attempts up to 20 due deliveries.
# Stop starting attempts after 25 seconds; a final send may finish later.
# send(target, event) throws on failure. now is Unix time. Lease each receipt
# under a write lock, then release the lock before calling the transport.
# Due copies in a muted scope are marked muted instead and are not counted.
sub deliver
{
my ($self, $send, $now) = @_;
my $count = 0;
my $started = time();
for (1 .. 20) {
	last if time() - $started >= 25;
	my $work = $self->transaction(sub {
		# callback(db) reserves one due delivery,
		# or cancels an invalid one.
		my ($db) = @_;
		# An expired lease lets a later worker recover
		# an interrupted attempt.
		my $row = $db->selectrow_hashref("SELECT * FROM deliveries
			WHERE (state = 'queued' OR state = 'sending') AND due <= ?
			ORDER BY event, target LIMIT 1", undef, $now);
		return undef unless $row;
		my ($target) = grep { $_->{id} eq $row->{target} }
			@{records($db, 'targets')};
		unless ($target && $target->{enabled}) {
			# Removed or disabled destinations must not
			# receive old queued messages.
			$db->do("UPDATE deliveries SET state = 'cancelled'
				WHERE event = ? AND target = ?", undef,
				$row->{event}, $row->{target});
			return { skip => 1 };
			}
		# Check the mute again at send time. It may have started
		# after queueing, or a retry may have requeued this copy.
		my ($json) = $db->selectrow_array('SELECT record FROM events WHERE id = ?',
			undef, $row->{event});
		my $event = decode($json);
		my $muted = $event->{phase} eq 'test' ? undef
			: silence($db, $event->{owner}, $now);
		if ($muted) {
			# Mute every pending copy, so no backlog is sent
			# after unmuting.
			mute_event($db, $row->{event}, $event, $muted);
			return { skip => 1 };
			}
		# Reserve this event/destination pair for five
		# minutes before sending.
		$db->do("UPDATE deliveries SET state = 'sending', attempts = attempts + 1,
			due = ? WHERE event = ? AND target = ?", undef,
			$now + 300, $row->{event}, $row->{target});
		return { %$row, target_record => $target,
			event_record => { %{decode($json)}, id => 0 + $row->{event} } };
		});
	# Stop when nothing is due. A cancelled delivery is not an attempt.
	last unless $work;
	next if $work->{skip};
	$self->send_delivery($work, $send, $now);
	$count++;
	}
return $count;
}

# permanent_failure() marks a rejection that must not retry automatically.
sub permanent_failure
{
die bless { }, 'Cloudmin::Notifications::PermanentFailure';
}

# send_delivery(self, work, send, now) completes one leased delivery attempt.
# work holds the event, target and previous attempt count; now is Unix seconds.
# send(target, event) uses the private target record and throws on failure.
# A PermanentFailure stops automatic retries; other failures use backoff.
# Return an empty string on success or a safe error without transport secrets.
sub send_delivery
{
my ($self, $work, $send, $now) = @_;
# Bound the transport call and clear the alarm on either success or failure.
my $ok = eval {
	# ALRM() aborts a delivery after ten seconds;
	# signal arguments are unused.
	local $SIG{ALRM} = sub { die "Delivery timed out\n" };
	alarm(10);
	$send->($work->{target_record}, $work->{event_record});
	alarm(0);
	1;
	};
my $permanent = ref($@) eq 'Cloudmin::Notifications::PermanentFailure';
alarm(0);
# Stop on permanent rejection or after six attempts. Other failures back off.
# Keep raw transport errors, including possible tokens, out of public receipts.
my $attempts = $work->{attempts} + 1;
my $state = $ok ? 'sent' : $permanent || $attempts >= 6 ? 'failed' : 'queued';
my $error = $ok ? ''
	: $permanent
		? 'Delivery rejected; check the destination or provider quota'.
			' before retrying'
		: 'Delivery failed; check the destination and mail settings';
$self->transaction(sub {
	# callback(db) saves the result and last-attempt time together.
	my ($db) = @_;
	# Apply the result only while this receipt still has a sending lease.
	my $updated = $db->do('UPDATE deliveries SET state = ?, due = ?, error = ?
		WHERE event = ? AND target = ? AND state = ?', undef,
		$state, $now + 60 * 2**$attempts,
		$error,
		$work->{event}, $work->{target}, 'sending');
	# Cancelled or deleted destinations must not acquire a stale result.
	if ($updated > 0) {
		$db->do('INSERT OR REPLACE INTO metadata VALUES (?, ?)', undef,
			'delivery:'.$work->{target}, encode({
				event => $work->{event}, at => int($now) }));
		}
	});
return $error;
}

# retry(self, event, now) requeues failed receipts for an existing event ID.
# Reset the attempt count to zero and the due time to now in Unix seconds.
# Leave successful and cancelled copies alone.
sub retry
{
my ($self, $event, $now) = @_;
$event = number($event, 'event ID', 0, 1, 999999999999);
die "Invalid event ID\n" unless int($event) == $event;
return $self->transaction(sub {
	# callback(db) verifies the event and resets only its failed deliveries.
	my ($db) = @_;
	my ($exists) = $db->selectrow_array('SELECT id FROM events WHERE id = ?',
		undef, $event);
	die "Notification event not found\n" unless $exists;
	$db->do("UPDATE deliveries SET state = 'queued', attempts = 0, due = ?,
		error = '' WHERE event = ? AND state = 'failed'", undef, $now, $event);
	return { id => $event };
	});
}

# prune(self, now) removes completed history and mutes that ended over 30 days
# ago. now is Unix seconds. Pending receipts remain until delivered or expired.
sub prune
{
my ($self, $now) = @_;
$self->transaction(sub {
	# callback(db) expires overdue deliveries and removes completed history.
	# Expire messages more than a day overdue, including abandoned leases.
	$_[0]->do("UPDATE deliveries SET state = 'failed', error = 'Delivery expired'
		WHERE state IN ('queued', 'sending') AND due < ?", undef, $now - 86400);
	# Delete mutes that ended over 30 days ago. Newer intervals stay for
	# delayed job-failure scans. Active mutes never expire.
	$_[0]->do('DELETE FROM mutes WHERE until_time > 0 AND until_time < ?', undef,
		$now - 30 * 86400);
	# Retain pending deliveries even when their event is older than 30 days.
	$_[0]->do("DELETE FROM events WHERE created < ? AND NOT EXISTS
		(SELECT 1 FROM deliveries WHERE event = events.id
		AND state IN ('queued', 'sending'))", undef, $now - 30 * 86400);
	});
}

# metadata(self, key, [value]) reads or writes a named JSON value. Omit value to
# read; an explicit undef writes JSON null. Missing keys return undef.
sub metadata
{
my ($self, $key, $value) = @_;
if (@_ > 2) {
	# Serialize metadata updates with the same lock as
	# configuration and events.
	return $self->transaction(sub {
		# callback(db) stores the JSON value under its metadata key.
		$_[0]->do('INSERT OR REPLACE INTO metadata VALUES (?, ?)',
			undef, $key, encode($value));
		});
	}
# Reading absent metadata must not create the store.
my $db = $self->connect(0);
return undef unless $db;
my ($json) = $db->selectrow_array('SELECT value FROM metadata WHERE key = ?',
	undef, $key);
$db->disconnect();
return defined($json) ? decode($json) : undef;
}

package Cloudmin::Notifications::PermanentFailure;

# This error marks permanent rejection without keeping provider responses.
use overload '""' => \&as_string, fallback => 1;

# as_string(self, [other], [swapped]) supplies safe text for exception handlers.
# The optional arguments belong to Perl's string-conversion interface.
sub as_string
{
return "Notification delivery was not accepted\n";
}

1;
