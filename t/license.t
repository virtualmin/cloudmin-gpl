use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use Test::More;
use File::Temp qw(tempdir);
use WebminCore qw(convert_to_json convert_from_json);
require "$Bin/../lib/Cloudmin/License.pm";

# fixture([reply]) isolates credentials, the clock and server responses.
# reply defaults to a valid Cloudmin response. Returns the service, clock,
# response, request count and directory; the middle three are mutable references.
sub fixture
{
my ($reply) = @_;
my $dir = tempdir(CLEANUP => 1);
my $now = Cloudmin::License::expiry('2026-10-01') - 86400;
my $response = $reply || 'OK 2026-12-31 100 1 1 0 N product=cloudmin';
my $calls = 0;
my $service = Cloudmin::License->new(directory => "$dir/state", file => "$dir/license",
    host => 'host-one', now => sub { $now }, request => sub {
        $calls++;
        die "Network failure containing secret-fixture-key\n" if ($response eq 'offline');
        return $response;
    });
return ($service, \$now, \$response, \$calls, $dir);
}

# The current API includes host counts and special host allowances.
my $current = Cloudmin::License::parse("OK 2026-12-31 100 1 4 1 H 98765 product=cloudmin\n");
is($current->{'vm_limit'}, 100, 'machine allowance is retained');
is($current->{'max_hosts'}, 6, 'special allowance extends the base host limit');
is($current->{'used_hosts'}, 4, 'reported host use is retained');
is($current->{'auto_renew'}, 1, 'automatic renewal is retained');
is($current->{'subscription'}, '98765', 'optional subscription is parsed');
for my $allowance ([N => 1], [D => 2], [T => 3], [Q => 4], [P => 5], [H => 6], [Y => 0]) {
    is(Cloudmin::License::parse("OK 2026-12-31 0 1 9 0 $allowance->[0] product=cloudmin")->{'max_hosts'},
        $allowance->[1], "$allowance->[0] host allowance is decoded");
}
is(Cloudmin::License::parse('OK 2026-12-31 0 10 1 0 D product=cloudmin')->{'max_hosts'}, 10,
    'special allowance never reduces the base limit');
is(Cloudmin::License::parse("ERR Invalid host or serial number\n")->{'state'}, 'invalid', 'invalid key is distinct from outage');
for my $code ('OK', 'EXP') {
    is(Cloudmin::License::parse("$code 2026-12-31 10 1 1 0 N product=virtualmin")->{'state'},
        'invalid', 'Virtualmin licenses cannot validate Cloudmin');
    is(Cloudmin::License::parse("$code 2026-12-31 10 1 1 0 N")->{'state'},
        'unavailable', 'an old server without product checks cannot validate');
}
for my $response ('', 'OK 2026-02-30 10 1 1 0 N product=cloudmin', 'OK 2026-12-31 10 garbage product=cloudmin', '<html>error</html>',
    "HTTP/1.1 200 OK\n", 'ERR database unavailable', 'OK 2026-12-31 10 product=cloudmin',
    'OK 2026-12-31 10 1 1 product=cloudmin', 'OK 2026-12-31 10 1 1 0 Z product=cloudmin') {
    is(Cloudmin::License::parse($response)->{'state'}, 'unavailable', 'malformed or incomplete responses never validate');
}

# A fresh host becomes licensed only after the replacement has been validated.
my ($s, $now, $reply, $calls, $dir) = fixture();
is($s->status()->{'state'}, 'missing', 'missing credentials block a fresh Pro host');
ok(!$s->status()->{'allowed'}, 'no implicit trial from missing state');
$s->change('12345', 'secret-fixture-key');
is($s->status()->{'state'}, 'valid', 'validated credentials enable changes');
is($$calls, 1, 'change validates once');
# Product checks invalidate even a correctly sealed cache from the old protocol.
my $saved = $s->load($s->credentials());
my $old = { %$saved, binding => Digest::SHA::sha256_hex(join("\0",
    'license/client-v1', 'host-one', '12345', 'secret-fixture-key')) };
$s->save($old);
ok(!$s->status()->{'allowed'}, 'old unscoped approval is not reused');
$s->save($saved);
# Existing license files may allow other readers, but not other writers.
is((stat("$dir/license"))[2] & 0777, 0600, 'credentials are private');
is((stat("$dir/state/status"))[2] & 0777, 0600, 'cached status is private');
chmod(0644, "$dir/license") or die $!;
ok($s->status()->{'allowed'}, 'existing readable credential files remain usable');
chmod(0666, "$dir/license") or die $!;
ok(!eval { $s->status(); 1 }, 'other users cannot supply writable credentials');
chmod(0600, "$dir/license") or die $!;
unlike(convert_to_json($s->status()), qr/secret-fixture-key/, 'public status never contains the key');
# Reads use cached approval until the daily refresh becomes due.
$s->status(1);
is($$calls, 1, 'fresh status does not call the server again');
$$now += 86400;
$s->status(1);
is($$calls, 2, 'daily refresh checks the server');

# Expiry grace starts when the licensed UTC date ends, even if checked later.
$$reply = 'EXP 2026-10-02 100 1 1 0 N product=cloudmin';
$$now = Cloudmin::License::expiry('2026-10-02');
my $expired = $s->status(1, 1);
is($expired->{'state'}, 'expired', 'expiry is reported');
is($expired->{'days_left'}, 7, 'expiry allows exactly seven days');
ok($expired->{'allowed'}, 'expiry grace allows new changes');
$$now += 7*86400-1;
ok($s->status()->{'allowed'}, 'last second of expiry grace is available');
$$now++;
ok(!$s->status()->{'allowed'}, 'expiry grace ends at the boundary without a recheck');
# An outage cannot revive expired terms, but a verified renewal can.
$$reply = 'offline';
ok(!$s->status(1, 1)->{'allowed'}, 'outage cannot clear an expired license');
unlike(convert_to_json($s->status()), qr/secret-fixture-key/, 'transport exceptions are not exposed');
$$reply = 'OK 2027-12-31 100 1 1 0 N product=cloudmin';
ok($s->status(1, 1)->{'allowed'}, 'renewal restores changes');

# Migration checks retain the first local observation across repeated checks.
$$reply = 'OK 2027-12-31 100 1 2 0 N product=cloudmin';
my $migration = $s->status(1, 1);
is($migration->{'days_left'}, 21, 'host overuse allows 21 days');
is($migration->{'state'}, 'overused', 'host overuse is visible');
my $deadline = $migration->{'deadline'};
$$now += 86400;
is($s->status(1, 1)->{'deadline'}, $deadline, 'recheck does not restart migration grace');
$$now = $deadline;
ok(!$s->status(1, 1)->{'allowed'}, 'migration grace ends exactly at 21 days');
# Reduced use or a larger allowance ends the migration warning.
$$reply = 'OK 2027-12-31 100 1 1 0 N product=cloudmin';
ok($s->status(1, 1)->{'allowed'}, 'finishing migration restores access');
$$reply = 'OK 2027-12-31 100 1 2 0 D product=cloudmin';
is($s->status(1, 1)->{'state'}, 'valid', 'two-host allowance permits two hosts');
$$reply = 'OK 2027-12-31 100 1 100 0 Y product=cloudmin';
is($s->status(1, 1)->{'state'}, 'valid', 'unlimited host allowance does not start migration grace');

# A network outage uses the last verified result, never the last failed check.
$$reply = 'OK 2027-12-31 100 1 1 0 N product=cloudmin';
$s->status(1, 1);
my $verified = $$now;
$$reply = 'offline';
$$now += 86400;
ok($s->status(1, 1)->{'allowed'}, 'temporary outage keeps a verified license working');
$$now = $verified+21*86400;
ok(!$s->status(1, 1)->{'allowed'}, 'repeated failed checks cannot extend offline use');
$$reply = 'OK 2027-12-31 100 1 1 0 N product=cloudmin';
ok($s->status(1, 1)->{'allowed'}, 'successful verification restores access');

# An OK response during server-side grace does not postpone the expiry date.
$$reply = 'OK 2026-10-02 100 1 1 0 N product=cloudmin';
$$now = Cloudmin::License::expiry('2026-10-02') + 7*86400;
ok(!$s->status(1, 1)->{'allowed'}, 'OK after expiry cannot extend seven-day grace');
$$reply = 'OK 2027-12-31 100 1 1 0 N product=cloudmin';
$s->status(1, 1);

# Failed validation must leave saved credentials unchanged.
my $before = Cloudmin::License::read_private("$dir/license");
$$reply = 'ERR Invalid host or serial number';
ok(!eval { $s->change('54321', 'different-fixture-key'); 1 }, 'invalid replacement is rejected');
is($@, "The license could not be validated\n", 'validation failure is one phrase without a final period');
is(Cloudmin::License::read_private("$dir/license"), $before, 'failed change preserves credentials');
ok(!$s->status(1, 1)->{'allowed'}, 'invalid current license blocks changes');
$$reply = 'OK 2027-12-31 100 1 1 0 N product=cloudmin';
$s->status(1, 1);

# Cached results cannot be copied to a different host or edited to extend time.
my $other = Cloudmin::License->new(%$s, host => 'host-two');
ok(!$other->status()->{'allowed'}, 'copied cache is not valid for another host');
my $cache = Cloudmin::License::read_private("$dir/state/status");
my $envelope = convert_from_json($cache);
$envelope->{'data'} =~ s/2027/2037/g;
Cloudmin::License::write_private("$dir/state/status", convert_to_json($envelope));
ok(!$s->status()->{'allowed'}, 'edited cache does not validate');
$$reply = 'offline';
ok(!$s->status(1, 1)->{'allowed'}, 'edited cache plus outage does not get a trial');
Cloudmin::License::write_private("$dir/state/status", $cache);
# Future cached timestamps and server expiry both expose a rolled-back clock.
$$now -= 3600;
is($s->status()->{'state'}, 'clock', 'clock rollback cannot extend a verified cache');
ok(!$s->status()->{'allowed'}, 'clock rollback requires a fresh check');
$$reply = 'EXP 2037-12-31 100 1 1 0 N product=cloudmin';
is($s->status(1, 1)->{'state'}, 'clock', 'server expiry exposes a seriously incorrect host clock');
ok(!$s->status()->{'allowed'}, 'a fresh check cannot grant years of expiry grace');


# Credentials and state cannot be redirected through a symlink.
unlink("$dir/license");
symlink("$dir/state/status", "$dir/license") or die $!;
ok(!eval { $s->status(); 1 }, 'symlinked credential file is refused');

# A different product is a rejection, not an outage with offline grace.
my ($product_service, undef, $product_reply, undef, $product_dir) = fixture();
$product_service->change('12345', 'secret-fixture-key');
my $product_credentials = Cloudmin::License::read_private("$product_dir/license");
$$product_reply = 'OK 2099-12-31 100 1 1 0 N product=virtualmin';
ok(!eval { $product_service->change('54321', 'different-fixture-key'); 1 },
    'a Virtualmin response cannot save replacement credentials');
is(Cloudmin::License::read_private("$product_dir/license"), $product_credentials,
    'wrong-product replacement leaves the current credentials intact');
ok(!$product_service->status(1, 1)->{'allowed'},
    'wrong product on recheck immediately invalidates an earlier approval');

# Deregistration stops local use without contacting the license server.
{
    my ($service, $clock, $response, $requests, $folder) = fixture();
    $service->change('12345', 'secret-fixture-key');
    $$response = 'OK 2026-12-31 100 1 2 0 N product=cloudmin';
    my $deadline = $service->status(1, 1)->{'deadline'};
    $$clock += 86400;
    my $before = $$requests;
    my $result = $service->deregister();
    # Removal clears the public serial and saved key without a network call.
    is($result->{'state'}, 'missing', 'deregistered host needs a license');
    ok(!$result->{'allowed'}, 'deregistration blocks new changes immediately');
    is($result->{'serial'}, '', 'public result has no old serial');
    is($$requests, $before, 'deregistration works offline');
    is_deeply($service->credentials(), {serial => '', key => ''}, 'saved credentials are cleared');
    is((stat("$folder/license"))[2] & 0777, 0600, 'cleared license remains private');
    is($service->status(1, 1)->{'state'}, 'missing', 'forced checks cannot reuse the old key');
    is($$requests, $before, 'daily checks stop contacting the server without a key');
    # Repeated removal and reactivation must not restart migration grace.
    is($service->deregister()->{'state'}, 'missing', 'repeated deregistration is harmless');
    is($service->change('12345', 'secret-fixture-key')->{'deadline'}, $deadline,
        'adding the same license cannot restart host-overuse grace');

}

# A repository failure leaves the previous credentials and usable cache intact.
{
    my ($service) = fixture();
    $service->change('12345', 'secret-fixture-key');
    $service->{'replace'} = sub { die "Fixture repository failure\n" };
    ok(!eval { $service->deregister(); 1 }, 'repository failure is reported');
    is($service->status()->{'state'}, 'valid', 'failed deregistration keeps the license usable');
}
done_testing();
