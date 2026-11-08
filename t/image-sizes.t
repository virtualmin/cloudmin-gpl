use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";
use CloudminTest;
use File::Temp qw(tempdir);
use Test::More;
use WebminCore qw(convert_to_json);
use Cloudmin::ImageSizes;

my $directory = tempdir(CLEANUP => 1).'/sizes';
my ($now, $calls, $locked, $fail) = ( 100000, 0, 0, 0 );
my $answer = 321 * 1024**2;
my $sizes = Cloudmin::ImageSizes->new(directory => $directory,
				      now => sub { $now },
				      probe => sub { $calls++; die "Offline\n" if $fail; return $answer; },
				      test_lock => sub { $locked },
				      lock_file => sub { die "Already locked\n" if $locked; $locked = 1 },
				      unlock_file => sub { $locked = 0 },
);
my $entry = { url => 'https://images.example.test/latest.qcow2',
	      download_size_bytes => 300 * 1024**2 };
is($sizes->get($entry)->{'bytes'}, 300 * 1024**2,
   'packaged estimate is available before any request');
ok(!-d $directory, 'reading an estimate creates no cache or network request');
is($calls, 0, 'ordinary page rendering never probes publishers');
is($sizes->refresh($entry)->{'bytes'}, $answer,
   'server observation replaces the packaged estimate');
ok(!$locked, 'successful refresh releases the lock');
is($sizes->refresh($entry)->{'bytes'}, $answer,
   'fresh observations are reused');
is($calls, 1, 'fresh cache avoids a second request');
like(convert_to_json($sizes->get($entry)), qr/"bytes"\s*:\s*336592896\b/,
     'cached byte counts remain JSON numbers after validation');

# Latest URLs change; refresh after a day and retain good data during outages.
$now += 86401;
$answer += 1024;
is($sizes->refresh($entry)->{'bytes'}, $answer,
   'expired observation is refreshed');
$now += 86401;
$fail = 1;
is($sizes->refresh($entry)->{'bytes'}, $answer,
   'offline publisher retains the last known estimate');
my $failed_calls = $calls;
$now += 3599;
$sizes->refresh($entry);
is($calls, $failed_calls, 'failed lookups wait an hour before retrying');
$now += 2;
$sizes->refresh($entry);
is($calls, $failed_calls + 1, 'failed lookup becomes eligible for retry');
ok(!$locked, 'failed probes release the lock');

# URLs isolate architectures and invalidate estimates when
# custom sources change.
my $other = { url => 'https://images.example.test/amd64.qcow2' };
ok(!defined($sizes->get($other)->{'bytes'}),
   'another asset does not inherit a size');
$fail = 0;
$answer = undef;
ok(!defined($sizes->refresh($other)->{'bytes'}),
   'missing server length remains unknown, not zero');
$locked = 1;
$now += 86401;
my $before_busy = $calls;
is($sizes->refresh($entry)->{'bytes'}, 321 * 1024**2 + 1024,
   'busy refresh returns the existing estimate');
is($calls, $before_busy, 'concurrent refresh does not start another probe');
$locked = 0;
for my $bad ( 0, -1, '1e9', '123x', '9007199254740992', [ ], { } ) {
	ok(!Cloudmin::ImageSizes::valid_bytes($bad),
	   'unsafe byte count is rejected');
	}
done_testing();
