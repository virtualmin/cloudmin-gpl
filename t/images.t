use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use Test::More;
use File::Temp qw(tempdir);
require "$Bin/../lib/Cloudmin/Images.pm";

# These tests touch only their temporary store, not the host's virtualization.
my $dir = tempdir(CLEANUP => 1);
# Record Webmin API calls and reject accidental nested or unpaired locks.
my (%locked, @locks, @logs);
my %webmin = (
	lock_file => sub {
		my ($file, $readonly, $forcefile, $nodiff) = @_;
		push(@locks, [ 'lock', @_ ]);
		die "Lock already held\n" if ($locked{$file});
		return $locked{$file} = 1;
		},
	unlock_file => sub {
		my ($file) = @_;
		die "Lock not held\n" if (!delete($locked{$file}));
		push(@locks, [ 'unlock', $file ]);
		},
	test_lock => sub { return $locked{$_[0]} ? $$ : 0 },
	# Filesystem behavior is exercised with the real mount API on the VM.
	disk_free => sub { return 16 * 1024**3 },
	log => sub {
		die "Action logged before unlock\n" if (keys(%locked));
		push(@logs, [ @_ ]);
		},
);
my $jobs = Cloudmin::Images->new(directory => $dir, %webmin);
my $token = $jobs->form_token('test-user');
ok(eval { $jobs->check_token('test-user', $token); 1 }, 'valid form token');
ok(!eval { $jobs->check_token('other-user', $token); 1 },
	'token bound to user');
ok(!eval { $jobs->check_token('test-user', 'invalid'); 1 },
	'missing token rejected');
my $request = { source => 'local', format => 'qcow2', slug => 'test',
	name => 'Test', pool => 'pool', pool_name => 'default' };
my $job = $jobs->create('test-user', $token, $request);
is($job->{'state'}, 'queued', 'new job is queued');
my $repeat = $jobs->create('test-user', $token, $request);
is($repeat->{'id'}, $job->{'id'}, 'double submission returns the same job');
is(scalar(@{$jobs->list()}), 1,
	'double submission does not create another job');
# A retry cannot reuse a completed or running import for different form data.
for my $field (qw(name format pool)) {
	ok(!eval { $jobs->create('test-user', $token,
		{ %$request, $field => 'changed' }); 1 }, "changed $field is rejected");
	like($@, qr/already submitted different image settings/,
		'changed input has an explicit idempotency error');
	}
# An idempotent POST must return immediately while the worker holds the lock.
$locked{"$dir/$job->{id}.json"} = 1;
is($jobs->create('test-user', $token, $request)->{'id'}, $job->{'id'},
	'duplicate submission reads an active job without taking its lock');
delete($locked{"$dir/$job->{id}.json"});
is(scalar(@{$jobs->list(undef, 1)}), 1, 'queued imports count as active jobs');
is_deeply([ map { $_->{'id'} } @{$jobs->list(undef, 1)} ], [ $job->{'id'} ],
	'active listing contains the queued import counted by the overview');
is_deeply($jobs->list('other-user', 1), [],
	'active filtering retains owner filtering');
ok(!eval { $jobs->get($job->{'id'}, 'other-user'); 1 },
	'private job reads check owner');
ok(!eval { $jobs->get('../invalid'); 1 },
	'job ID validated before filesystem access');

# Webmin's JSON writer must retain non-ASCII text and private file permissions.
my $unicode = $jobs->create('test-user', $jobs->form_token('test-user'),
	{ %$request, name => "Caf\x{e9} \x{1f4bf}" });
is($jobs->get($unicode->{'id'})->{'name'}, "Caf\x{e9} \x{1f4bf}",
	'UTF-8 job metadata survives a write and read');
is((stat("$dir/$unicode->{id}.json"))[2] & 0777, 0600,
	'new job metadata is private');
is((stat("$dir/form-key"))[2] & 0777, 0600, 'signing key remains private');
$jobs->remove($unicode->{'id'});

# Vendor checksum dialects must match the exact requested asset filename.
my $digest = 'a'x64;
is(Cloudmin::Images::checksum("$digest  image.qcow2\n", 'image.qcow2',
	'sha256'),
	$digest, 'GNU checksum');
is(Cloudmin::Images::checksum("SHA256 (image.qcow2) = $digest\n", 'image.qcow2',
	'sha256'),
	$digest, 'BSD checksum');
is(Cloudmin::Images::checksum(('b'x128)." *image.qcow2\n", 'image.qcow2',
	'sha512'),
	'b'x128, 'SHA-512 checksum');
ok(!eval { Cloudmin::Images::checksum("$digest  different.qcow2\n",
	'image.qcow2', 'sha256'); 1 },
	'checksum for a different file rejected');

# A sidecar must contain exactly one digest of the declared algorithm.
is(Cloudmin::Images::checksum(('B'x128)."\n", 'alpine.qcow2', 'sha512'),
	'b'x128, 'Alpine bare SHA-512 sidecar');
is(Cloudmin::Images::checksum("$digest\r\n", 'image.qcow2', 'sha256'),
	$digest, 'bare SHA-256 sidecar');
for my $manifest ("$digest\n$digest\n", "$digest junk", 'b'x128) {
	ok(!eval { Cloudmin::Images::checksum($manifest, 'image.qcow2',
		'sha256'); 1 },
		'ambiguous or wrong-length sidecar rejected');
	}
is(Cloudmin::Images::validate_url('https://images.example.test/disk.qcow2'),
	'https://images.example.test/disk.qcow2', 'HTTPS URL accepted');
is(Cloudmin::Images::validate_url('HTTPS://images.example.test/disk.qcow2'),
	'https://images.example.test/disk.qcow2',
	'HTTPS scheme is normalized for Webmin');
for my $url ('file:///disk.qcow2', 'http://images.example.test/disk',
	'https://user:pass@example.test/disk') {
	ok(!eval { Cloudmin::Images::validate_url($url); 1 },
		'non-HTTPS or credential URL rejected');
	}
# Listing old tombstones is read-only and keeps idempotent request records
# intact.
my $tombstone = $jobs->get($unicode->{'id'});
$tombstone->{'updated'} = time() - 90000;
WebminCore::write_file_contents("$dir/$unicode->{id}.json",
	WebminCore::convert_to_json($tombstone));
$jobs->list();
ok(-f "$dir/$unicode->{id}.json",
	'an inventory read does not prune old records');

# Binary copies retain all bytes, including zeros and non-ASCII data.
my $upload = $jobs->create('test-user', $jobs->form_token('test-user'),
	{ %$request, source => 'upload' });
is(scalar(@{$jobs->list(undef, 1)}), 1, 'unstarted browser uploads are not active jobs');
is_deeply([ map { $_->{'id'} } @{$jobs->list(undef, 1)} ], [ $job->{'id'} ],
	'active listing excludes uploads that have not started');
my $bytes = "\0binary\r\nimage\xff";
open(my $input, '<', \$bytes) || die $!;
$jobs->transfer($upload, $input, length($bytes), 'uploading');
is(-s "$dir/$upload->{id}.part", length($bytes),
	'binary image is streamed exactly');
is($jobs->get($upload->{'id'})->{'state'}, 'uploading',
	'upload progress is durable');
# An interrupted upload retains its phase for the progress page's error line.
my $broken_upload = $jobs->create('test-user', $jobs->form_token('test-user'),
	{ %$request, source => 'upload' });
my $short_body = 'partial';
open(my $short_input, '<', \$short_body) || die $!;
{
no warnings qw(redefine once);
# The real destination lookup is covered by the native import fixture.
local *Cloudmin::Images::import_pool = sub { bless({}, 'ImagePoolSpace') };
local *ImagePoolSpace::get_info = sub { return {available => 16 * 1024**3}; };
ok(!eval { $jobs->receive($broken_upload->{'id'}, 'test-user', $short_input,
	100); 1 },
	'short upload fails without starting an import');
}
is($jobs->get($broken_upload->{'id'})->{'failure_state'}, 'uploading',
	'failed upload preserves its phase');
close($short_input);
# Batch selections get distinct jobs while retaining duplicate-submit safety.
my $batch_token = $jobs->form_token('test-user');
my $first = $jobs->create('test-user', $batch_token, $request, 'debian-13');
my $second = $jobs->create('test-user', $batch_token, $request, 'ubuntu-24.04');
isnt($first->{'id'}, $second->{'id'}, 'batch members have separate job IDs');
is($jobs->create('test-user', $batch_token, $request, 'debian-13')->{'id'},
	$first->{'id'}, 'batch resubmission returns original member');
ok($jobs->remove($first->{'id'}),
	'queued import can be cancelled without libvirt');
is($jobs->get($first->{'id'})->{'state'}, 'deleted',
	'cancellation leaves an idempotent tombstone');
ok($jobs->remove($first->{'id'}), 'worker cleanup polling remains idempotent');
ok(!grep({ $_->{'id'} eq $first->{'id'} } @{$jobs->list()}),
	'deleted jobs are absent from manager');
ok(!eval { $jobs->checkpoint($first); 1 }, 'workers honor cancellation marker');
my $orphan = "$dir/$second->{id}.part.webmintmp.1234.0";
open(my $partial, '>', $orphan) || die $!;
print($partial 'partial fixture');
close($partial);
$jobs->cleanup_staging($second->{'id'});
ok(!-e $orphan, 'deletion cleans this job\'s interrupted Webmin tempfile');
ok(-e "$dir/$upload->{id}.part",
	'cleanup preserves another job\'s staging data');

# Libvirt serializes references consistently; check file and volume forms.
ok(Cloudmin::Images::xml_uses_volume('<source file="/pool/image.qcow2"/>',
	'/pool/image.qcow2', 'default', 'image.qcow2'),
	'attached disk is protected');
ok(Cloudmin::Images::xml_uses_volume("<source pool='default' volume='image.qcow2'/>",
	'/pool/image.qcow2', 'default', 'image.qcow2'),
	'pool-volume disk is protected');
ok(Cloudmin::Images::xml_uses_volume('<backingStore><path>/pool/a&amp;b</path></backingStore>',
	'/pool/a&b', 'default', 'a&b'),
	'escaped backing-store paths are protected');
ok(!Cloudmin::Images::xml_uses_volume('<source file="/pool/other.qcow2"/>',
	'/pool/image.qcow2', 'default', 'image.qcow2'),
	'unrelated volumes do not prevent deletion');

# Private keys and binary staging files must never be captured for diffs.
ok(!grep({ $_->[0] eq 'lock' && $_->[1] =~ /(?:form-key|\.part)$/ && !$_->[4] }
	@locks),
	'keys and image data are always locked with nodiff');
ok(grep({ $_->[0] eq 'lock' && $_->[1] =~ /\.json$/ && !$_->[4] } @locks),
	'small job metadata remains available for Webmin diffs');
is(scalar(keys(%locked)), 0,
	'success, duplicate submission and upload failure release every lock');
is(scalar(grep { $_->[0] eq 'create' && $_->[2] eq $job->{'id'} } @logs), 1,
	'duplicate submission does not log another creation');
ok(grep({ $_->[0] eq 'upload' && $_->[3]->{'state'} eq 'failed' &&
	$_->[3]->{'error'} =~ /interrupted/ } @logs),
	'failed upload is logged after unlocking');

# Busy operations return promptly, leaving the running worker's lock intact.
my $busy = $jobs->create('test-user', $jobs->form_token('test-user'),
	{ %$request, source => 'upload' });
my $busy_path = "$dir/$busy->{id}.json";
$locked{$busy_path} = 1;
is($jobs->run($busy->{'id'}), undef, 'duplicate worker skips a locked job');
open(my $busy_input, '<', \$bytes) || die $!;
ok(!eval { $jobs->receive($busy->{'id'}, 'test-user', $busy_input,
	length($bytes)); 1 },
	'concurrent upload is rejected');
like($@, qr/already running/, 'busy upload reports contention');
is($jobs->remove($busy->{'id'}), 0, 'deletion waits for worker cleanup');
ok(-e "$dir/$busy->{id}.cancel", 'busy deletion still requests cancellation');
ok($locked{$busy_path},
	'busy operations do not release another worker\'s lock');
delete($locked{$busy_path});
ok($jobs->remove($busy->{'id'}),
	'deletion completes once the worker releases its lock');

# Errors and skipped jobs must release both locks without masking the cause.
my $before = scalar(@logs);
is($jobs->run($busy->{'id'}), undef, 'completed job is not imported again');
is(scalar(@logs), $before, 'skipped worker does not log an import');
ok(!eval { $jobs->with_job_lock($second->{'id'}, 'delete',
	sub { die "Storage unavailable\n" }); 1 },
	'operation failure propagates');
is($@, "Storage unavailable\n", 'unlock preserves the original failure');
is(scalar(keys(%locked)), 0,
	'operation failure releases metadata and binary locks');
is_deeply([ map { $_->[0].' '.($_->[1] =~ /\.(\w+)$/)[0] } @locks[-2, -1] ],
	[ 'unlock part', 'unlock json' ],
	'nested locks are released in reverse order');

# A failed Webmin lock must not permit writes or unlock a lock it did not take.
{
	local $jobs->{'lock_file'} = sub { return 0 };
	my $called = 0;
	ok(!eval { $jobs->with_lock("$dir/unavailable", 1, sub { $called++; });
		1 },
		'lock acquisition failure propagates');
	is($called, 0, 'operation is not called without a lock');
	}

# Unit checks keep resource queries and subprocesses off the workstation.
{
	local $jobs->{'disk_free'} = sub { return 300 * 1024**2 };
	is($jobs->staging_limit(), 44 * 1024**2,
		'staging reserve is subtracted from available bytes');
	local $jobs->{'disk_free'} = sub { return undef };
	ok(!eval { $jobs->staging_limit(); 1 },
		'unavailable filesystem space blocks staging');
	}
# Pool reservations and removal share the host lock without locking downloads.
{
	my @pool_calls;
	local $jobs->{'pool_lock'} = sub {
		my ($pool, $callback, $creating) = @_;
		push(@pool_calls, [$pool, $creating]);
		return $callback->();
		};
	my $token = $jobs->form_token('test-user');
	my $record = $jobs->create('test-user', $token, $request);
	$jobs->create('test-user', $token, $request);
	is_deeply(\@pool_calls, [['pool', 1]], 'new reservation takes pool lock; replay remains nonblocking');
	$jobs->remove($record->{'id'});
	is_deeply($pool_calls[-1], ['pool', 0], 'deletion shares pool lifecycle lock');
	local $jobs->{'pool_lock'} = sub { die "Pool stopped\n"; };
	my $before = @{$jobs->list()};
	ok(!eval { $jobs->create('test-user', $jobs->form_token('test-user'), $request); 1 }, 'inactive pool recheck prevents reservation');
	is(scalar(@{$jobs->list()}), $before, 'failed pool reservation writes no job');
}
# Deleted imports outlive form retries, but do not accumulate indefinitely.
my $expired = 'd'x32;
Cloudmin::Images::write_private_file($jobs->path($expired, 'json'),
	WebminCore::convert_to_json({ id => $expired, state => 'deleted',
		owner => 'test-user', updated => time()-172801 }));
$jobs->cancel($expired);
$jobs->prune_deleted();
ok(!-e $jobs->path($expired, 'json') && !-e $jobs->path($expired, 'cancel'),
	'expired tombstone and cancellation marker are pruned together');
ok(-f $jobs->path($job->{'id'}, 'json'), 'current submission remains available for retries');
# ISO imports retain a media suffix even though libvirt stores raw bytes.
my $iso = $jobs->create('test-user', $jobs->form_token('test-user'),
    { %$request, format => 'iso' });
like($iso->{'volume'}, qr/\.iso\z/, 'ISO import gets an ISO volume name');
is($iso->{'format'}, 'iso', 'ISO job retains its declared media type');
done_testing();
