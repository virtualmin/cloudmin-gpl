use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use Test::More;
use File::Temp qw(tempdir);
use POSIX ();
require "$Bin/../lib/Cloudmin/Jobs.pm";
plan skip_all => 'DBI and DBD::SQLite are required'
	if (!eval { Cloudmin::Jobs::dependencies(); 1 });

# Exercise real SQLite transactions with observable Webmin lock callbacks.
my $dir = tempdir(CLEANUP => 1);
my (%locks, @audits, @nodiff);
my $jobs = Cloudmin::Jobs->new(directory => "$dir/jobs",
	# lock_file(path, [readonly], [forcefile], [nodiff])
			       # detects nested locks.
			       lock_file => sub { push(@nodiff, $_[3]);
		die 'nested lock' if ($locks{$_[0]}); $locks{$_[0]} = 1 },
	# unlock_file(path) must pair with the same lock scope.
			       unlock_file => sub { die 'unpaired unlock' if (!delete($locks{$_[0]}));
		},
			       test_lock => sub { $locks{$_[0]} ? $$ : 0 },
			       log => sub { push(@audits, [ @_ ]) });
is_deeply($jobs->list(), [ ], 'a fresh store has no jobs');
ok(!-d "$dir/jobs", 'reading an empty store creates no data');
# Submission must be durable, private and idempotent for the same owner.
my $id = 'a' x 32;
my $request = { name => 'fixture', console_password => 'private-value',
		description => "Caf\x{e9} \x{1f4bf}" };
is($jobs->submit($id, 'user', 'vm:fixture', $request)->{'state'}, 'queued',
   'submission is durable');
is((stat("$dir/jobs/jobs.sqlite"))[2] & 0777, 0600,
   'SQLite records are private');
is($jobs->get($id)->{'request'}->{'description'}, "Caf\x{e9} \x{1f4bf}",
   'UTF-8 metadata survives SQLite storage');
is($jobs->submit($id, 'user', 'vm:changed', { })->{'request'}->{'name'},
   'fixture', 'retry cannot change a request');
is(scalar(@{$jobs->list('user')}), 1, 'idempotent retry creates no duplicate');
# Expiry blocks new jobs, but existing jobs remain readable and resumable.
{
	local $jobs->{'admit'} = sub { die "License changes blocked\n" };
	is($jobs->submit($id, 'user', 'vm:fixture', $request)->{'state'},
	   'queued',
	   'accepted job survives a later license restriction');
	ok(!eval { $jobs->submit('f' x 32, 'user', 'vm:license-new', { }); 1 },
	   'new durable submission must pass admission');
	like($@, qr/License changes blocked/,
	     'admission error reaches the caller');
	ok(!$jobs->get('f' x 32), 'denied submission leaves no job');
	}

ok(!eval { $jobs->submit('b' x 32, 'user', 'vm:fixture', { }); 1 },
   'an active name cannot be reserved twice');
ok(!eval { $jobs->get($id, 'other'); 1 }, 'reads enforce ownership');
ok(!eval { $jobs->submit($id, 'other', 'vm:fixture', { }); 1 },
   'retry enforces ownership');
is_deeply($jobs->list('other'), [ ], 'list excludes other owners');
# Exceptions must roll back both SQLite state and Webmin lock ownership.
ok(!eval { $jobs->update($id,
			 sub { $_[0]->{'state'} =
		'complete'; die "interrupted\n" }); 1 },
   'a failed update propagates its error');
is($jobs->get($id)->{'state'}, 'queued', 'failed transaction rolled back');
is_deeply(\%locks, { }, 'rollback releases Webmin locks');
# Later progress updates must not erase a cancellation request.
$jobs->update($id, sub { $_[0]->{'cancel'} = 1; });
$jobs->update($id, sub { $_[0]->{'phase'} = 'disk'; });
ok($jobs->get($id)->{'cancel'}, 'progress updates preserve cancellation');
$jobs->lock('worker-'.$id,
	    sub { ok($jobs->busy($id),
		     'worker state uses Webmin test_lock'); });
ok(!$jobs->busy($id), 'finished worker is not busy');
# HTTP discard must return promptly while a disk worker owns the queue.
$jobs->lock('vm-work', sub {
	ok(!eval { $jobs->lock('vm-work', sub { die 'Should not enter' },
			       1); 1 },
	   'nonblocking disk operation refuses a busy queue');
	like($@, qr/Another disk operation is running/,
	     'busy queue has an actionable error');
	ok(!$locks{"$dir/vm-queue"}, 'queue inspection lock is released');
	});
# Terminal jobs release reservations without leaking private data to audit logs.
$jobs->update($id, sub { $_[0]->{'state'} = 'failed'; });
is(scalar(@{$jobs->list('user', 1)}), 0,
   'finished jobs leave the recovery queue');
ok($jobs->submit('b' x 32, 'user', 'vm:fixture', { }),
   'finished reservation permits a new request');
ok(!grep(!$_, @nodiff), 'binary and worker locks always use nodiff');
is(scalar(@audits), 2, 'only new submissions emit creation audits');
ok(!exists($audits[0]->[3]->{'console_password'}),
   'audit excludes provisioning secrets');

# Drafts are private to one form, owner and initial username, and expire.
$jobs->save_credential($id, 'user', 'root', 'fixture-hash');
is($jobs->credential($id, 'user', 'root'), 'fixture-hash',
   'review can retain its password hash');
ok(!$jobs->credential($id, 'other', 'root'),
   'another Webmin user cannot reuse the draft');
ok(!$jobs->credential($id, 'user', 'changed'),
   'changing the initial username needs a new password');
ok(!$jobs->credential('c' x 32, 'user', 'root'),
   'another form cannot reuse the draft');
# Expiry and owner checks must also apply when drafts are deleted or reused.
$jobs->write_data(sub { $_[0]->do('UPDATE credentials SET expires = 0'); });
ok(!$jobs->credential($id, 'user', 'root'),
   'expired draft cannot authenticate a guest');
$jobs->save_credential($id, 'user', 'root', 'fixture-hash');
$jobs->delete_credential($id, 'other');
ok($jobs->credential($id, 'user', 'root'), 'draft deletion enforces ownership');
$jobs->delete_credential($id, 'user');
ok(!$jobs->credential($id, 'user', 'root'), 'submitted draft is removed');
is(scalar(@audits), 2, 'credential writes do not log hashes');

# A logging failure cannot turn a committed submission into an API failure.
# Recovery would otherwise execute a job the caller was told did not queue.
{
	local $jobs->{'log'} = sub { die "Fixture audit failure\n" };
	my $queued = eval { $jobs->submit('d' x 32, 'user', 'vm:audit',
					  { name => 'audit' }) };
	is($@, '', 'audit failure does not reject a committed submission');
	is($queued->{'state'}, 'queued', 'the caller receives the queued job');
	like($queued->{'audit_warning'} || '', qr/submission audit log/,
	     'the returned job reports its missing audit entry');
	is($jobs->get('d' x 32)->{'audit_warning'}, $queued->{'audit_warning'},
	   'the audit warning remains available after the request');
	is_deeply($jobs->submit('d' x 32, 'user', 'vm:audit', { }), $queued,
		  'retrying the submission returns the same job and warning');
	}

# Force SQLite to spill dirty pages before killing the writer. This produces a
# real hot journal, rather than constructing one by editing SQLite's bytes.
$jobs->write_data(sub {
	my ($db) = @_;
	$db->do('CREATE TABLE spill_fixture (payload BLOB)');
	$db->do(
		'INSERT INTO spill_fixture VALUES (zeroblob(16384))') for 1 .. 32;
	});
my $writer = fork();
die "Cannot fork: $!" if (!defined($writer));
if (!$writer) {
	# A small cache forces the uncommitted changes into the database file.
	my $db = $jobs->connect(1);
	$db->do('PRAGMA cache_size = 5');
	$db->begin_work();
	$db->do('UPDATE jobs SET record = ? WHERE id = ?', undef,
		'uncommitted data', $id);
	$db->do('UPDATE spill_fixture SET payload = zeroblob(32768)');
	POSIX::_exit(0);
	}
waitpid($writer, 0);
is($? >> 8, 0, 'the interrupted writer reached the crash point');
ok(-e "$dir/jobs/jobs.sqlite-journal",
   'an interrupted writer leaves its journal behind');
open(my $journal, '<', "$dir/jobs/jobs.sqlite-journal") ||
	die "Cannot open journal: $!";
binmode($journal);
read($journal, my $magic, 8);
close($journal);
is(unpack('H*', $magic), 'd9d505f920a163d7',
   'SQLite itself synced the hot journal');
is(eval { $jobs->get($id)->{'state'} }, 'failed',
   'readers recover the original record from a hot journal');
ok(!-e "$dir/jobs/jobs.sqlite-journal", 'recovery removes the hot journal');
# Bridge transactions are checked inside the shared host lock, including errors.
{
	local $jobs->{'host_guard'} = sub {
		ok($locks{"$dir/jobs/create-host"},
		   'network guard runs after acquiring host lock');
		die "bridge confirmation pending\n";
		};
	my $ran;
	ok(!eval { $jobs->lock('create-host', sub { $ran = 1 }); 1 },
	   'pending networking blocks host mutation');
	ok(!$ran, 'blocked operation never runs');
	ok(!$locks{"$dir/jobs/create-host"},
	   'guard failure releases host lock');
	is($jobs->lock('host-network', sub { 'recovery' }), 'recovery',
	   'network recovery can still acquire its own lock');
	}

# Worker guard failures are durable rather than abandoned queued records.
{
	my $guarded = 'e' x 32;
	$jobs->submit($guarded, 'user', 'guest:guarded',
		      { uuid => 'guarded', password_hash => 'private',
			webmin_password => 'private-webmin-login' });
	local $jobs->{'host_guard'} = sub { die "Bridge requires recovery\n"; };
	ok(!$jobs->run_worker($guarded, sub { die 'must not run' }),
	   'guard failure is caught');
	my $failed = $jobs->get($guarded);
	is($failed->{'state'}, 'failed', 'guard failure has a terminal state');
	like($failed->{'error'}, qr/Bridge requires recovery/,
	     'guard error survives');
	ok(!$failed->{'cleanup_pending'},
	   'pre-write guard failure needs no recovery');
	ok(!exists($failed->{'request'}->{'password_hash'}),
	   'failed queued creation forgets credentials');
	ok(!exists($failed->{'request'}->{'webmin_password'}),
	   'pre-allocation failures forget the Webmin login');
	}
# Retained failures cannot disappear behind the recent-history limit.
{
	my $retained = 'f' x 32;
	$jobs->submit($retained, 'recover-owner', 'guest:retained',
		      { uuid => 'retained' });
	$jobs->update(
		$retained,
		sub { $_[0]->{'state'} = 'failed'; $_[0]->{'cleanup_pending'} =
			1; });
	for my $n (1 .. 55) {
		my $recent = sprintf('%032x', $n);
		$jobs->submit($recent, 'recover-owner', 'vm:recent-'.$n, { });
		$jobs->update($recent, sub { $_[0]->{'state'} = 'complete'; });
		}
	is_deeply([ map { $_->{'id'} } @{$jobs->list_pending('recover-owner')} ],
		  [ $retained ], 'all pending recovery stays visible');
	is_deeply($jobs->list_pending('another-owner'), [ ],
		  'recovery preserves owner scope');
	}

# A schedule must refuse an overlapping run instead of waiting to repeat it.
$jobs->lock('backup-schedule-test', sub {
	ok(!eval { $jobs->lock('backup-schedule-test',
			       sub { die 'must not run' },
			       1); 1 },
	   'nonblocking schedule refuses an overlapping run');
	like($@, qr/Another operation is running/,
	     'schedule reports lock contention');
	});

# Simulate another worker claiming disk work after the initial queue check.
{
	my $cancelled = '9' x 32;
	$jobs->submit($cancelled, 'user', 'vm:queue-race', { });
	my $test_lock = $jobs->{'test_lock'};
	my ($checks, $ran) = ( 0, 0 );
	local $jobs->{'test_lock'} = sub {
		if ($_[0] eq "$dir/jobs/vm-work") {
			# The lock becomes busy and cancellation
			# arrives before acquisition.
			return 0 if (++$checks == 1);
			$jobs->update($cancelled,
				      sub { $_[0]->{'cancel'} = 1; });
			return $$;
			}
		return $test_lock->(@_);
		};
	no warnings qw(redefine once);
	local *Time::HiRes::sleep =
		sub { die "Queued cancellation was ignored\n"; };
	$jobs->run_worker($cancelled, sub { $ran = 1; });
	my $job = $jobs->get($cancelled);
	ok(!$ran, 'a cancelled worker never enters disk work');
	is($job->{'state'}, 'cancelled',
	   'cancellation releases the queued reservation');
	like($job->{'error'}, qr/Virtual machine operation cancelled/,
	     'cancellation is checked during lock acquisition');
	ok(!$job->{'cleanup_pending'},
	   'a cancelled queued worker needs no recovery');
	}

done_testing();
