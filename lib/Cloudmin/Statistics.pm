package Cloudmin::Statistics;

# Local history and mergeable summaries. Only the collector opens a writer.
# Request handlers use short, read-only connections to the same WAL database.
use strict;
use warnings;
use DBI;
use DBD::SQLite ();
use JSON::PP ();
use Fcntl qw(:DEFAULT :flock O_NOFOLLOW);
use File::Path qw(make_path);
use List::Util qw(min max);

# metrics() defines units and gauge/counter types for the wire format. Gauge
# sums are value times seconds. Counter sums integrate interval rates into
# increments. Every duration is measured in seconds.

sub metrics
{
return {
	cpu => [ 'percent', 'gauge' ],
	cpu_time => [ 'seconds', 'counter' ],
	cpu_wait => [ 'percent', 'gauge' ],
	cpu_wait_time => [ 'seconds', 'counter' ],
	vcpus => [ 'count', 'gauge' ],
	guest_vcpus => [ 'count', 'gauge' ],
	guest_memory => [ 'bytes', 'gauge' ],
	storage_total => [ 'bytes', 'gauge' ],
	storage_used => [ 'bytes', 'gauge' ],
	load_1 => [ 'load', 'gauge' ],
	load_5 => [ 'load', 'gauge' ],
	load_15 => [ 'load', 'gauge' ],
	memory_allocated => [ 'bytes', 'gauge' ],
	memory_used => [ 'bytes', 'gauge' ],
	filesystem_total => [ 'bytes', 'gauge' ],
	filesystem_used => [ 'bytes', 'gauge' ],
	disk_capacity => [ 'bytes', 'gauge' ],
	disk_read => [ 'bytes', 'counter' ],
	disk_write => [ 'bytes', 'counter' ],
	disk_reads => [ 'operations', 'counter' ],
	disk_writes => [ 'operations', 'counter' ],
	network_receive => [ 'bytes', 'counter' ],
	network_transmit => [ 'bytes', 'counter' ],
};
}
my @metrics = sort keys %{metrics()};
my @fields =
	map { my $m =
		$_; map { "${m}_$_" } qw(sum duration min max count) } @metrics;

# uuid() creates an installation or database identity without machine metadata.

sub uuid
{
open(my $fh, '<:raw', '/dev/urandom') or
	die "Cannot read random identity: $!\n";
read($fh, my $bytes, 16) == 16 or die "Cannot create random identity\n";
close($fh);
# Set the UUID version and variant bits after reading 128 random bits.
my @b = unpack('C*', $bytes);
$b[6] = ($b[6] & 15) | 64;
$b[8] = ($b[8] & 63) | 128;
my $h = unpack('H*', pack('C*', @b));
return join('-', substr($h, 0, 8), substr($h, 8, 4), substr($h, 12, 4),
	    substr($h, 16, 4), substr($h, 20, 12));
}

# host_id(directory) persists identity outside history, including DB recreation.

sub host_id
{
my ($directory) = @_;
# Serialize first-run identity creation without following lock-file symlinks.
make_path($directory, { mode => 0700 }) if (!-d $directory);
my $path = "$directory/statistics-host-id";
sysopen(my $lock, "$path.lock", O_RDWR | O_CREAT | O_NOFOLLOW, 0600) or
	die "Cannot open statistics identity lock: $!\n";
flock($lock, LOCK_EX) or die "Cannot lock statistics identity: $!\n";
# Reuse and validate the installation identity even after history is recreated.
if (-e $path) {
	sysopen(my $fh, $path, O_RDONLY | O_NOFOLLOW) or
		die "Cannot read statistics host identity: $!\n";
	my $id = <$fh>;
	close($fh);
	chomp($id);
	die "Invalid statistics host identity\n" unless $id =~
		/\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/;
	return $id;
	}
# Only the first caller creates an identity. Publish it
# before releasing the lock.
my $id = uuid();
atomic_write($path, "$id\n");
return $id;
}

# atomic_write(path, contents) publishes a private cache or
# identity in one rename.

sub atomic_write
{
my ($path, $contents) = @_;
my $temporary = "$path.$$-".uuid();
sysopen(my $fh, $temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600) or
	die "Cannot create statistics file: $!\n";
my $ok = eval {
	print($fh $contents) or die "Cannot write statistics file: $!\n";
	close($fh) or die "Cannot close statistics file: $!\n";
	rename($temporary, $path) or die "Cannot publish statistics file: $!\n";
	1;
	};
my $error = $@;
# Remove an unpublished temporary file and preserve the original write error.
unlink($temporary) if (!$ok);
die $error if (!$ok);
}

# latest(directory, now) reads the bounded live cache. Now is Unix seconds.
# Expired readings stay unknown.

sub latest
{
my ($directory, $now) = @_;
my $path = "$directory/statistics-latest.json";
# Reject missing, oversized or indirect cache files before decoding JSON.
return { } unless -f $path && !-l $path && -s $path < 32 * 1024 * 1024;
sysopen(my $fh, $path, O_RDONLY | O_NOFOLLOW) or return { };
local $/;
my $data = eval { JSON::PP->new->utf8->decode(<$fh>) };
close($fh);
# Unknown cache versions cannot safely supply live readings.
return { } unless ref($data) eq 'HASH' && ($data->{version} || 0) == 1;
my $age = $now - ($data->{checked_at} || 0);
if ($age < 0 || $age > 3 * ($data->{interval} || 10)) {
	# Retain diagnostics, but never expose stale
	# resources as a fresh reading.
	$data->{vms} = { };
	$data->{host} = { };
	$data->{stale} = 1;
	}
return $data;
}

# new(class, directory => path, [write => boolean], [host_id => uuid],
# [hardware_uuid => uuid]) opens history. Write defaults to false. A writer
# requires host_id. Hardware UUID is an inventory hint, not identity. Readers
# never initialize a store; an absent database is a normal empty result.

sub new
{
my ($class, %args) = @_;
my $self = bless \%args, $class;
die "Statistics directory is required\n" unless $self->{directory};
my $path = "$self->{directory}/metrics.sqlite";
# A missing store is normal for readers. Only the collector may create it.
return $self if (!$self->{write} && !-f $path);
die "Statistics database must be a regular file\n" if -l $path ||
	(-e $path && !-f $path);
# Create private writer state and restore the caller's umask after connection.
make_path($self->{directory}, { mode => 0700 })
	if ($self->{write} && !-d $self->{directory});
my $old = umask(0077);
my $db = eval { DBI->connect("dbi:SQLite:dbname=$path", '', '', {
	RaiseError => 1, PrintError => 0, AutoCommit => 1,
	sqlite_unicode => 1,
	sqlite_open_flags => $self->{write} ? 6 : 1,
}) };
my $error = $@;
umask($old);
die $error unless $db;
$self->{db} = $db;
$db->sqlite_busy_timeout(2000);
# The sole writer initializes WAL, maintenance settings and schema.
if ($self->{write}) {
	$db->do('PRAGMA journal_mode=WAL');
	$db->do('PRAGMA synchronous=NORMAL');
	$db->do('PRAGMA wal_autocheckpoint=1000');
	$db->do('PRAGMA auto_vacuum=INCREMENTAL');
	$self->schema();
	}
# Readers cannot change history, including through accidental SQL writes.
else {
	$db->do('PRAGMA query_only=ON');
	}
# Reject unsupported schemas and stores belonging to another installation.
my $meta = $db->selectall_arrayref('SELECT name,value FROM metadata');
$self->{meta} = { map { @$_ } @$meta };
die "Unsupported statistics schema\n"
	unless ($self->{meta}->{version} || '') eq '1';
die "Statistics database belongs to a different host\n" if $self->{host_id} &&
	$self->{host_id} ne $self->{meta}->{host_id};
return $self;
}

# schema(self) creates the version-one schema only in the collector process.

sub schema
{
my ($self) = @_;
my $db = $self->{db};
$db->begin_work;
eval {
	$db->do(
		'CREATE TABLE IF NOT EXISTS metadata (name TEXT PRIMARY KEY, value TEXT NOT NULL)');
	my $version =
		$db->selectrow_array(
			"SELECT value FROM metadata WHERE name='version'");
	die "Unsupported statistics schema\n" if defined($version) &&
		$version ne '1';
	# Preserve the generation and host identity once the
	# database has been created.
	for my $pair ( [ version => 1 ], [ generation => uuid() ],
		       [ host_id => $self->{host_id} ||
				    die "Host identity required\n" ] ) {
		$db->do('INSERT OR IGNORE INTO metadata VALUES (?,?)',
			undef,
			@$pair);
		}
	# Refresh the optional hardware hint without replacing
	# the installation ID.
	$db->do('INSERT OR REPLACE INTO metadata VALUES (?,?)', undef,
		'hardware_uuid', $self->{hardware_uuid})
		if $self->{hardware_uuid};
	# Track owners separately from the wide numeric sample rows.
	$db->do(
		'CREATE TABLE IF NOT EXISTS entities (id TEXT PRIMARY KEY, owner TEXT NOT NULL, kind TEXT NOT NULL, label TEXT NOT NULL, seen REAL NOT NULL)');
	$db->do('CREATE INDEX IF NOT EXISTS entities_owner ON entities(owner)');
	$db->do(
		'CREATE TABLE IF NOT EXISTS samples (entity TEXT NOT NULL, step INTEGER NOT NULL, t REAL NOT NULL, end REAL NOT NULL, observed_end REAL, closed INTEGER NOT NULL DEFAULT 0,'.
		join(',',
		     map { "$_ REAL" } @fields).
		', PRIMARY KEY(entity,step,t)) WITHOUT ROWID');
	# Databases from earlier versions gain the columns later metrics added.
	my %columns =
		map { $_->{name} =>
			1 } @{$db->selectall_arrayref(
				'PRAGMA table_info(samples)',
				{ Slice => { } })};
	for my $column ( 'observed_end', @fields ) {
		$db->do("ALTER TABLE samples ADD COLUMN $column REAL")
			unless $columns{$column};
		}
	$db->do('CREATE INDEX IF NOT EXISTS samples_time ON samples(step,t)');
	$db->do(
		'CREATE INDEX IF NOT EXISTS samples_open ON samples(step,end) WHERE closed=0');
	# Assign export sequence numbers only to sealed summaries.
	$db->do(
		'CREATE TABLE IF NOT EXISTS exports (seq INTEGER PRIMARY KEY AUTOINCREMENT, entity TEXT NOT NULL, step INTEGER NOT NULL, t REAL NOT NULL, UNIQUE(entity,step,t))');
	$db->do('CREATE INDEX IF NOT EXISTS exports_step ON exports(step,seq)');
	$db->do('CREATE INDEX IF NOT EXISTS exports_time ON exports(step,t)');
	# Index lifecycle and device changes by owner and time for
	# bounded chart queries.
	$db->do(
		'CREATE TABLE IF NOT EXISTS events (seq INTEGER PRIMARY KEY AUTOINCREMENT, owner TEXT NOT NULL, t REAL NOT NULL, kind TEXT NOT NULL, detail TEXT NOT NULL)');
	$db->do(
		'CREATE INDEX IF NOT EXISTS events_owner_time ON events(owner,t)');
	$db->do('CREATE INDEX IF NOT EXISTS events_time ON events(t)');
	$db->commit;
	1;
	} or do {
		my $error = $@;
		eval { $db->rollback };
		die $error;
		};
}

# summary(values, duration) calculates weighted totals, bounds and counts.
# Missing readings remain absent. Each value is a gauge or an interval rate.
# Counter sums are rate * duration.

sub summary
{
my ($values, $duration) = @_;
my %result;
for my $metric (@metrics) {
	my $value = $values->{$metric};
	# Only nonnegative numeric readings contribute valid time.
	next
		if !defined($value) || ref($value) ||
		"$value" !~ /\A-?\d+(?:\.\d+)?(?:e[+-]?\d+)?\z/i ||
		$value < 0;
	@result{map { "${metric}_$_" } qw(sum duration min max count)} =
		( $value * $duration, $duration, $value, $value, 1 );
	}
return \%result;
}

# merge(into, source, [fraction]) combines sums and durations, never averages.
# Fraction defaults to one. Smaller fractions split intervals at bucket
# boundaries while retaining the observed minimum and maximum.

sub merge
{
my ($into, $source, $fraction) = @_;
$fraction = 1 if !defined($fraction);
for my $m (@metrics) {
	# Absent metrics contribute neither a zero value nor measured duration.
	next unless defined($source->{"${m}_count"});
	$into->{"${m}_sum"} += $source->{"${m}_sum"} * $fraction;
	$into->{"${m}_duration"} += $source->{"${m}_duration"} * $fraction;
	$into->{"${m}_count"} += $source->{"${m}_count"} * $fraction;
	$into->{"${m}_min"} = defined($into->{"${m}_min"})
		? min($into->{"${m}_min"}, $source->{"${m}_min"})
		: $source->{"${m}_min"};
	$into->{"${m}_max"} = defined($into->{"${m}_max"})
		? max($into->{"${m}_max"}, $source->{"${m}_max"})
		: $source->{"${m}_max"};
	}
return $into;
}

# add_bucket(self, entity, step, time, summary, observed_end) updates a bucket.
# Step is its width in seconds. Time and observed_end are Unix timestamps.

sub add_bucket
{
my ($self, $entity, $step, $t, $summary, $observed_end) = @_;
my $db = $self->{db};
my $row =
	$db->selectrow_hashref(
		'SELECT * FROM samples WHERE entity=? AND step=? AND t=?',
		undef,
		$entity, $step, $t);
# Exported buckets are immutable. Merge only while the target bucket is open.
die "Cannot amend a completed statistics bucket\n" if $row && $row->{closed};
my $merged = merge($row || { }, $summary);
# Keep the actual covered end apart from the bucket's nominal end.
$observed_end = max($observed_end, $row->{observed_end} || 0);
$db->do('INSERT OR REPLACE INTO samples (entity,step,t,end,observed_end,'.
	join(',', @fields).') VALUES ('.
	join(',', ('?') x (5 + @fields)).')', undef, $entity, $step,
	$t, $t + $step, $observed_end, @{$merged}{@fields});
}

# record(self, rows, events, now) commits one host tick and completed summaries.
# Rows contain entity, owner, kind, label, start, end and normalized values.
# Events contain owner, t, kind and detail. All timestamps are Unix seconds.

sub record
{
my ($self, $rows, $events, $now) = @_;
die "Statistics writer required\n" unless $self->{write};
my $db = $self->{db};
$db->begin_work;
my $ok = eval {
	for my $row (@$rows) {
		my ($start, $end) = @{$row}{qw(start end)};
		# Reject reversed, oversized or future intervals before
		# storing any tick data.
		die "Invalid statistics interval\n" unless defined($start) &&
			defined($end) &&
			$end >= $start && $end - $start <= 180 &&
			$end <= $now + 1;
		my $label = $row->{label};
		utf8::decode($label) unless utf8::is_utf8($label);
		$db->do('INSERT OR REPLACE INTO entities VALUES (?,?,?,?,?)',
			undef,
			@{$row}{qw(entity owner kind)}, $label, $end);
		# A first reading establishes a baseline, not an interval.
		# Storing its zero-length row would collide with the next
		# interval's start key.
		next unless $end > $start;
		my $summary = summary($row->{values}, $end - $start);
		my $inserted =
			$db->do(
				'INSERT OR IGNORE INTO samples (entity,step,t,end,closed,'.join(',', @fields).') VALUES ('.
				join(',', ('?') x (5 + @fields)).')', undef,
				$row->{entity}, 0, $start, $end, 1,
				@{$summary}{@fields});
		# A retried raw interval must not contribute to
		# its summaries twice.
		next unless $inserted > 0 && $end > $start;
		# Split an interval across every minute bucket it overlaps.
		for (my $t = int($start / 60) * 60 ; $t < $end ; $t += 60) {
			my $fraction =
				(min($end, $t + 60) - max($start,
							  $t)) / ($end - $start);
			$self->add_bucket($row->{entity}, 60, $t,
					  merge({ }, $summary, $fraction),
					  min($end,
					      $t + 60));
			}
		}
	# Store UTF-8 event details in the same transaction as
	# this tick's samples.
	for my $event (@$events) {
		my $detail = $event->{detail};
		utf8::decode($detail) unless utf8::is_utf8($detail);
		$db->do(
			'INSERT INTO events(owner,t,kind,detail) VALUES (?,?,?,?)',
			undef,
			@{$event}{qw(owner t kind)}, $detail);
		}
	# The last raw interval has already contributed to every bucket it
	# overlaps. Seal only through its start boundary; the next tick can
	# still cross the end.
	my $cutoff = @$rows ? min(map { $_->{start} } @$rows) : $now - 180;
	for my $step ( 60, 300, 3600 ) {
		my $ready =
			$db->selectall_arrayref(
				'SELECT s.*,e.kind FROM samples s JOIN entities e ON e.id=s.entity WHERE step=? AND closed=0 AND end<=?', { Slice => { } }, $step, $cutoff);
		for my $row (@$ready) {
			my $next = $step == 60 ? 300 : $step == 300 ? 3600 : 0;
			# Device history stops at five minutes to keep
			# long-term costs bounded.
			if ($next && ($next != 3600 ||
				      $row->{kind} =~ /\A(?:host|vm)\z/)) {
				$self->add_bucket($row->{entity}, $next,
						  int($row->{t} / $next) * $next, $row,
						  $row->{end});
				}
			# Seal and enqueue the summary together so retries see a
			# stable export batch.
			$db->do(
				'UPDATE samples SET closed=1 WHERE entity=? AND step=? AND t=?', undef, @{$row}{qw(entity step t)});
			$db->do(
				'INSERT OR IGNORE INTO exports(entity,step,t) VALUES (?,?,?)', undef, @{$row}{qw(entity step t)});
			}
		}
	$db->commit;
	1;
	};
my $error = $@;
# A failed tick must leave neither partial samples nor partial export records.
eval { $db->rollback } unless $ok;
die $error unless $ok;
}

# query(self, owner, from, to, points, [entity]) returns bounded chart data. The
# controller must authorize owner before calling this method. From and to are
# Unix seconds. Omitting entity selects the owner's aggregate readings.

sub query
{
my ($self, $owner, $from, $to, $points, $entity) = @_;
# Bound both the requested time window and the number of returned chart points.
die "Invalid statistics range\n" unless defined($from) && defined($to) &&
	$from >= 0 && $to > $from && $to - $from <= 366 * 86400;
die "Invalid statistics point limit\n" unless $points >= 60 && $points <= 1200;
my $result =
	{ version => 1, from => $from, to => $to, metrics => metrics(),
	  series => [ ],
	  events => [ ], entities => [ ] };
# Without an open history store, return an empty chart response.
my $db = $self->{db} or return $result;
$result->{host_id} = $self->{meta}->{host_id};
$result->{generation} = $self->{meta}->{generation};
# Keep removed devices while they have history in this period. Device buckets
# span at most 300 seconds (raw intervals at most 180), so the primary key can
# bound each lookup without scanning all older samples. Last-seen time excludes
# removed devices whose final summary extends beyond their last reading.
$result->{entities} =
	$db->selectall_arrayref(
		'SELECT id,kind,label FROM entities e WHERE owner=? AND (id=? OR (seen>? AND EXISTS '.
		'(SELECT 1 FROM samples s WHERE s.entity=e.id AND s.step IN (0,60,300) '.
		'AND s.t>=? AND s.t<? AND COALESCE(s.observed_end,s.end)>CAST(? AS REAL)))) '.
		'ORDER BY kind,label LIMIT 257', { Slice => { } }, $owner,
		$owner,
		$from, $from - 300, $to, $from);
# Refuse oversized inventories and devices outside this owner's selected period.
die "Too many statistics devices\n" if @{$result->{entities}} > 256;
$entity ||= $owner;
return $result unless grep { $_->{id} eq $entity } @{$result->{entities}};
# Choose a stored tier near the display resolution, respecting device retention.
my $desired = ($to - $from) / $points;
my $step = $desired >= 3600
	? 3600
	: $desired >= 300 ? 300 : $desired >= 60 ? 60 : 0;
my ($kind) =
	map { $_->{kind} } grep { $_->{id} eq $entity } @{$result->{entities}};
$step = 300 if $step == 3600 && $kind !~ /\A(?:vm|host)\z/;
my ($fallback, $fallback_time);
# Compare each tier's oldest retained sample so collection gaps do not
# force coarser charts.
for my $tier ($step
	? ( $step, grep { $_ > $step } ( 60, 300, 3600 ) )
	: ( 0, 60, 300, 3600 )) {
	my $first =
		$db->selectrow_hashref(
			'SELECT * FROM samples WHERE entity=? AND step=? AND t<? ORDER BY t LIMIT 1', undef, $entity, $tier, $to);
	# Skip tiers with no retained samples before the requested end.
	next unless $first;
	my $oldest = $first->{t};
	my $duration = max(0,
			   map { $first->{"${_}_duration"} || 0 } @metrics);
	my $covered_from = $tier
		? max($oldest,
		      (
			      $first->{observed_end} // $first->{end}) - $duration)
		: $oldest;
	# Coarser buckets round their start down. Switch only for older retained
	# history: an earlier bucket, or more valid time in the same one. A
	# small tolerance avoids promoting tiers for floating-point roundoff.
	if (!defined($fallback_time) ||
	    $oldest < int($fallback_time / ($tier || 1)) * ($tier ||
							    1) ||
	    $covered_from < $fallback_time - 0.001) {
		($fallback, $fallback_time) = ( $tier,
						$covered_from );
		}
	last if $fallback_time <= $from;
	}
# Use at least the stored interval for each output bucket to bound chart size.
$step = $fallback if defined($fallback);
my $width = max($step || 1, int($desired + 0.999999));
$result->{resolution} = $step;
$result->{bucket_seconds} = $width;
$result->{entity} = $entity;
my $query =
	$db->prepare(
		'SELECT * FROM samples WHERE entity=? AND step=? AND end>? AND t<? ORDER BY t');
$query->execute($entity, $step, $from, $to);
my %buckets;
my $read = 0;
while (my $row = $query->fetchrow_hashref) {
	# Device queries can cover a year of five-minute data,
	# but not unlimited rows.
	die "Statistics query is too large\n" if ++$read > 120000;
	# An open bucket has only elapsed part of its nominal interval. Scaling
	# its duration by the full interval would understate
	# current coverage twice.
	$row->{end} = $row->{observed_end} if !$row->{closed} &&
		      defined($row->{observed_end});
	# Ignore empty intervals and split clipped values
	# across display buckets.
	next if $row->{end} <= $row->{t};
	my ($a, $b) = ( max($from, $row->{t}), min($to, $row->{end}) );
	for (my $t =
	     $from + int(
		     (
			     $a - $from) / $width) * $width ; $t < $b ;
	     $t += $width) {
		merge($buckets{$t} ||= { }, $row,
		      (min($b, $t + $width) - max($a,
						  $t)) / ($row->{end} - $row->{t}));
		}
	}
# Explicit empty buckets let uPlot break lines across missing history.
for (my $t = $from ; $t < $to ; $t += $width) {
	my $summary = $buckets{$t} || { };
	my (%values, %coverage, %peaks);
	for my $m (@metrics) {
		my $duration = $summary->{"${m}_duration"} || 0;
		$values{$m} = $duration > 0
			? $summary->{"${m}_sum"} / $duration
			: undef;
		$coverage{$m} = min(1, $duration / min($width, $to - $t));
		$peaks{$m} = $summary->{"${m}_max"};
		}
	push @{$result->{series}},
		{ t => $t, values => \%values, coverage => \%coverage, peaks =>
									       \%peaks };
	}
# Return only recent changes for this authorized owner and requested period.
$result->{events} =
	$db->selectall_arrayref(
		'SELECT t,kind,detail FROM events WHERE owner=? AND t>=? AND t<? ORDER BY t DESC LIMIT 200', { Slice => { } }, $owner, $from, $to);
return $result;
}

# export(self, step, cursor, limit) returns sealed numeric summaries. Pass undef
# or an empty cursor for the first batch. Limit is 1..1000. Sequence cursors
# make retained batches repeatable until retention removes them. Cursors include
# the DB generation and tier, and never depend on wall-clock time. Step selects
# 60-, 300- or 3600-second summaries.

sub export
{
my ($self, $step, $cursor, $limit) = @_;
die "Invalid summary resolution\n" unless $step == 60 || $step == 300 ||
	$step == 3600;
die "Invalid export limit\n" unless $limit >= 1 && $limit <= 1000;
my $db = $self->{db} or return { version => 1, rows => [ ], unavailable => 1 };
my $generation = $self->{meta}->{generation};
my $seq = 0;
# A cursor is valid only for this database generation and requested tier.
if (defined($cursor) && length($cursor)) {
	die "Invalid statistics cursor\n"
		unless $cursor =~ /\A([a-f0-9-]{36}):(60|300|3600):(\d{1,18})\z/;
	die "Statistics cursor has expired. Restart synchronization\n"
		unless $1 eq $generation && $2 == $step;
	$seq = 0 + $3;
	}
# Track retention loss separately from the next available export sequence.
my $floor =
	$db->selectrow_array('SELECT value FROM metadata WHERE name=?', undef,
			     "purged_$step") || 0;
my $rows =
	$db->selectall_arrayref(
		'SELECT x.seq,s.*,e.owner,e.kind,e.label FROM exports x JOIN samples s ON s.entity=x.entity AND s.step=x.step AND s.t=x.t JOIN entities e ON e.id=x.entity WHERE x.step=? AND x.seq>? ORDER BY x.seq LIMIT ?', { Slice => { } }, $step, $seq, $limit + 1);
my $more = @$rows > $limit ? 1 : 0;
# Read one extra row to detect another page without consuming that row.
pop @$rows if $more;
my $last = @$rows ? $rows->[-1]->{seq} : max($seq, $floor);
return { version => 1, host_id => $self->{meta}->{host_id}, generation =>
								    $generation,
	 hardware_uuid => $self->{meta}->{hardware_uuid},
	 metrics => metrics(), step => $step, rows => $rows, more => $more,
	 cursor => "$generation:$step:$last", retention_gap => $seq < $floor
		 ? 1
		 : 0,
	 available_from =>
		 $db->selectrow_array('SELECT min(t) FROM exports WHERE step=?',
				      undef, $step),
	 resolutions => [ 60, 300, 3600 ] };
}

# prune(self, now, retention, budget_bytes) expires recorded history. Retention
# maps tier seconds (0 for raw) to maximum ages in seconds. Now is Unix seconds.
# The budget applies to occupied database pages. Budget pressure expires old
# sealed rows; readers learn the export retention gap.

sub prune
{
my ($self, $now, $retention, $budget) = @_;
my $db = $self->{db};
# Apply each tier's own retention window before checking the shared disk budget.
for my $step ( 0, 60, 300, 3600 ) {
	my $cutoff = $now - $retention->{$step};
	$self->purge($step, $cutoff);
	}
$db->do('DELETE FROM events WHERE t<?', undef, $now - $retention->{3600});
$db->do(
	'DELETE FROM entities WHERE NOT EXISTS (SELECT 1 FROM samples WHERE samples.entity=entities.id) AND seen<?', undef, $now - 86400);
$db->do('PRAGMA wal_checkpoint(PASSIVE)');
$db->do('PRAGMA incremental_vacuum(256)');
my ($size) = $db->selectrow_array('PRAGMA page_size');
# Reserve space for WAL and one collection batch. SQLite also enforces a hard
# page limit, so storage pressure becomes a recording error,
# not unbounded growth.
$db->do('PRAGMA max_page_count='.int($budget * 0.8 / $size));
# Expire oldest raw data first, then fine summaries. Never remove open buckets.
for (1 .. 32) {
	my ($pages) = $db->selectrow_array('PRAGMA page_count');
	my ($free) = $db->selectrow_array('PRAGMA freelist_count');
	# Reusable free pages do not count as occupied
	# history for budget pruning.
	last if ($pages - $free) * $size < $budget * 0.7;
	my $removed = 0;
	for my $step ( 0, 60, 300, 3600 ) {
		my $cutoff =
			$db->selectrow_array(
				'SELECT t FROM samples WHERE step=? AND closed=1 ORDER BY t LIMIT 1 OFFSET 9999', undef, $step);
		# If fewer than 10,000 sealed rows remain, remove
		# the rest of that tier.
		$cutoff =
			$db->selectrow_array(
				'SELECT max(t) FROM samples WHERE step=? AND closed=1',
				undef, $step) unless defined($cutoff);
		# Skip empty tiers without treating them as progress
		# toward freeing space.
		next unless defined($cutoff);
		$self->purge($step, $cutoff + 0.001);
		$removed = 1;
		last;
		}
	# Stop when only open buckets remain, even if the
	# budget is still exceeded.
	last unless $removed;
	}
}

# purge(self, step, cutoff) records the last removed
# sequence in the same commit.

sub purge
{
my ($self, $step, $cutoff) = @_;
my $db = $self->{db};
$db->begin_work;
eval {
	my $seq =
		$db->selectrow_array(
			'SELECT max(seq) FROM exports WHERE step=? AND t<?',
			undef,
			$step, $cutoff);
	# Remember removed export sequences so clients can
	# detect a retention gap.
	if ($seq) {
		my $previous =
			$db->selectrow_array(
				'SELECT value FROM metadata WHERE name=?',
				undef,
				"purged_$step") || 0;
		$db->do('INSERT OR REPLACE INTO metadata VALUES (?,?)', undef,
			"purged_$step", max($seq, $previous));
		$db->do('DELETE FROM exports WHERE step=? AND t<?', undef,
			$step, $cutoff);
		}
	# Keep open buckets available for the next tick. Purge exports
	# and samples atomically.
	$db->do('DELETE FROM samples WHERE step=? AND t<? AND closed=1', undef,
		$step, $cutoff);
	$db->commit;
	1;
	} or do {
		my $error = $@;
		eval { $db->rollback };
		die $error;
		};
}

# DESTROY(self) releases SQLite handles at request or service shutdown.

sub DESTROY
{
my ($self) = @_;
eval { $self->{db}->disconnect } if $self->{db};
}

1;
