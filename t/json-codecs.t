use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use lib "$Bin/lib", "$Bin/../lib";
use CloudminTest;
use WebminCore qw(convert_to_json convert_from_json);
use Cloudmin::Notifications;
use Cloudmin::NotificationMessages;
use Test::More;
use File::Temp qw(tempdir);
use Encode qw(encode is_utf8);

# Root scalar metadata must survive Webmin's default for empty encoder input.
for my $case ([ undef, 'null' ], [ 0, '0' ], [ '', '""' ],
	     [ '0', '"0"' ], [ 'instance', '"instance"' ]) {
	my ($value, $json) = @$case;
	is(Cloudmin::Notifications::encode($value), $json,
	   "scalar metadata keeps $json");
	is(Cloudmin::Notifications::decode($json), $value,
	   "scalar metadata reads $json");
	}

# Sorted keys and UTF-8 bytes keep stored rules and request bodies stable.
my $value = { z => [ "é東京😀", 0, undef ], a => { b => 1 } };
my $json = encode('UTF-8', '{"a":{"b":1},"z":["é東京😀",0,null]}');
is(Cloudmin::Notifications::encode($value), $json,
   'canonical JSON preserves Unicode as UTF-8 bytes');
ok(!is_utf8(Cloudmin::Notifications::encode($value)),
   'encoded records can be written to raw filehandles');
is_deeply(Cloudmin::Notifications::decode($json), $value,
	  'existing UTF-8 records remain readable');
is_deeply(Cloudmin::Notifications::decode(
	'{"a":{"b":1},"z":["\u00e9\u6771\u4eac\ud83d\ude00",0,null]}'),
	$value, 'escaped Unicode remains readable');

# Both backends must distinguish JSON booleans from strings and other objects.
for my $case ([ 'true', 1 ], [ 'false', 0 ]) {
	my ($text, $expected) = @$case;
	my $boolean = convert_from_json($text);
	ok(Cloudmin::Notifications::is_boolean($boolean),
	   "$text uses a recognized JSON boolean");
	is(Cloudmin::Notifications::flag($boolean, 1), $expected,
	   "$text has the correct enabled value");
	is(Cloudmin::Notifications::encode($boolean), $text,
	   "$text stays a JSON boolean when saved");
	}
for my $other (0, 1, 'true', 'false', [ ], { }, \1) {
	ok(!Cloudmin::Notifications::is_boolean($other),
	   'only decoded JSON booleans acknowledge provider success');
	}
is(convert_to_json({ on => \1, off => \0 }, 0, 1, 1),
   '{"off":false,"on":true}', 'provider flags remain JSON booleans');
eval { Cloudmin::Notifications::decode('{"broken":'); };
ok($@, 'invalid JSON is rejected');

# Header formatting must not turn a numeric event ID into a JSON string in XS.
my $event = { version => 1, instance => 'fixture', id => 42 };
my $request = Cloudmin::NotificationMessages::request(
	{ type => 'webhook', address => 'https://example.invalid/events' },
	$event, { });
is($request->{content}, '{"id":42,"instance":"fixture","version":1}',
   'webhook ID keeps the numeric type returned by the API');
is($request->{headers}->{'Idempotency-Key'}, 'cloudmin-fixture-42',
   'webhook retry key still includes the event ID');
is(Cloudmin::Notifications::encode($event), $request->{content},
   'request formatting preserves the input event types');

# Reopening the database must preserve scalar metadata and old encoded values.
my $directory = tempdir(CLEANUP => 1);
my $store = Cloudmin::Notifications->new(directory => $directory);
$store->metadata('zero', 0);
$store->metadata('empty', '');
$store->metadata('null', undef);
$store->metadata('false', convert_from_json('false'));
$store->transaction(sub {
	$_[0]->do('INSERT INTO metadata VALUES (?, ?)', undef, 'legacy', $json);
	});
$store = Cloudmin::Notifications->new(directory => $directory);
is($store->metadata('zero'), 0, 'zero metadata survives reopening');
is($store->metadata('empty'), '', 'empty metadata survives reopening');
is($store->metadata('null'), undef, 'null metadata survives reopening');
is(Cloudmin::Notifications::encode($store->metadata('false')), 'false',
   'false metadata survives reopening');
is_deeply($store->metadata('legacy'), $value,
	  'existing JSON records survive reopening');
done_testing();
