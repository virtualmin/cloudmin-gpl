use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use WebminCore;
use Test::More;
use File::Temp qw(tempdir);
use HTTP::Tiny;
no warnings qw(redefine once);
our ($module_root_directory, $module_var_directory);
# Load the delivery code with a private data directory.
$module_root_directory = "$Bin/..";
$module_var_directory = tempdir(CLEANUP => 1);
require "$module_root_directory/cloudmin-notifications-lib.pl";

# fixture() returns private storage and a destination with a dummy bot token.
sub fixture
{
my $store = Cloudmin::Notifications->new(directory => tempdir(CLEANUP => 1));
my $target = { name => 'Telegram fixture', type => 'telegram',
	address => '-1001234567890', secret => '123456:fixture_Token-abc' };
return ($store, $target);
}

# Check accepted inputs, token edits and public responses.
subtest 'Validate chat IDs and tokens without exposing them' => sub {
	my ($store, $target) = fixture();
	# Accept numeric IDs and usernames without changing their saved form.
	for my $chat ('123456789', '-1001234567890', '@news', '@Cloudmin_ops',
		'@'.('a' x 32), '4503599627370495', '-4503599627370495') {
		my $saved = $store->save_target({ %$target, address => $chat });
		is($store->target($saved->{id})->{address}, $chat, 'valid chat ID retained');
		}
	# Reject malformed IDs, unsupported names and numbers outside the limit.
	for my $chat ('0', '-0', '01', '+123', '1.5', '1e3', '@abc',
		'@'.('a' x 33), '@has.dot', '@with-hyphen', '@имя', ' 123',
		'https://t.me/example', '4503599627370496', '-4503599627370496',
		('9' x 200), [ '123' ]) {
		eval { $store->save_target({ %$target, address => $chat }) };
		ok($@, 'invalid chat ID rejected');
		}
	# Invalid tokens must fail without repeating their contents in errors.
	for my $token (undef, '', '123', 'abc:token', '123:', '123:with/slash',
		'123:with?query', '123:with#fragment', '123:with%escape',
		'123:with space', "123:with\nnewline", ' 123:token',
		'123:token ', '123:токен', [ '123:token' ]) {
		eval { $store->save_target({ %$target, secret => $token }) };
		like($@, qr/token/, 'invalid or missing bot token rejected');
		unlike($@, qr/with|токен/, 'validation does not quote token content');
		}
	# Omission preserves a token only when the chat address stays the same.
	my $id = $store->save_target($target)->{id};
	my %edit = ( %$target, id => $id );
	delete($edit{secret});
	$store->save_target(\%edit);
	is($store->target($id)->{secret}, $target->{secret},
		'omitted token retained for unchanged chat');
	eval { $store->save_target({ %edit, address => '123' }) };
	like($@, qr/token/, 'changed chat needs a supplied token');
	eval { $store->save_target({ %edit, clear_secret => 1 }) };
	like($@, qr/token/, 'required token cannot be cleared');
	is($store->target($id)->{secret}, $target->{secret},
		'rejected edits preserve the saved token');
	# Public configuration exposes the chat ID and token presence only.
	my ($public) = grep { $_->{id} eq $id } @{$store->configuration()->{targets}};
	is($public->{address}, $target->{address}, 'chat ID remains visible');
	like(Cloudmin::Notifications::encode($public),
		qr/"address":"-1001234567890"/, 'configuration keeps the address a string');
	ok($public->{has_secret} && !exists($public->{secret}), 'token stays private');
	unlike(Cloudmin::Notifications::encode($store->configuration()),
		qr/fixture_Token/, 'configuration contains no bot token');
	};

# Check Telegram request fields and Unicode length limits.
subtest 'Build plain-text Bot API requests' => sub {
	my (undef, $target) = fixture();
	my $event = { id => 42, instance => 'fixture' };
	my $message = { subject => 'Guest <b>name</b>', body => '*plain* & _text_' };
	my $request = Cloudmin::NotificationMessages::request($target, $event, $message);
	is($request->{url}, 'https://api.telegram.org/bot'.$target->{secret}.'/sendMessage',
		'production uses fixed HTTPS Bot API URL');
	ok(!exists($request->{headers}{Authorization}), 'no bearer header');
	is($request->{headers}{'Content-Type'}, 'application/json', 'JSON content type');
	like($request->{content}, qr/"chat_id":-1001234567890[,}]/,
		'large negative chat ID is an exact JSON number');
	# Names and message text must remain literal, with markup disabled.
	my $payload = JSON::PP->new->utf8->decode($request->{content});
	is($payload->{text}, "Guest <b>name</b>\n\n*plain* & _text_", 'text remains literal');
	ok(!exists($payload->{parse_mode}), 'markup parsing stays disabled');
	ok($payload->{link_preview_options}{is_disabled}, 'link previews disabled');
	unlike($request->{content}, qr/fixture_Token/, 'body contains no token');
	$request = Cloudmin::NotificationMessages::request(
		{ %$target, address => '@Cloudmin_ops' }, $event, $message);
	is(JSON::PP->new->utf8->decode($request->{content})->{chat_id}, '@Cloudmin_ops',
		'public chat username remains a string');
	# Mixed Unicode includes supplementary characters
	# as well as UTF-8 letters.
	$message = { subject => 'Alert', body => "я😀" x 3000 };
	$request = Cloudmin::NotificationMessages::request($target, $event, $message);
	$payload = JSON::PP->new->utf8->decode($request->{content});
	is(length($payload->{text}), 4096, 'limit counts characters, not UTF-8 bytes');
	is($payload->{text}, substr("Alert\n\n".$message->{body}, 0, 4096),
		'truncation preserves Unicode characters');
	local $Cloudmin::NotificationMessages::telegram_api_base = 'https://127.0.0.1:8443';
	$request = Cloudmin::NotificationMessages::request($target, $event, $message);
	like($request->{url}, qr{\Ahttps://127\.0\.0\.1:8443/bot},
		'fixture override cannot require an external request');
	};

# Check replies and retries without contacting Telegram.
subtest 'Acceptance, retry and safe transport failures' => sub {
	my ($store, $target) = fixture();
	my $id = $store->save_target($target)->{id};
	my @requests;
	my $reply;
	# Replace networking entirely: this test must never contact Telegram.
	my %http_options;
	# new(class, [options...]) records client settings
	# without opening a socket.
	local *HTTP::Tiny::new = sub {
		my ($class, %options) = @_;
		%http_options = %options;
		return bless { }, $class;
		};
	# post(self, url, options) captures the request and
	# returns the chosen reply.
	local *HTTP::Tiny::post = sub { push @requests, [ $_[1], $_[2] ]; return $reply };
	# notification_message(event) supplies fixed text
	# without Webmin settings.
	local *main::notification_message = sub { +{ subject => 'Test', body => 'Fixture' } };
	# Only a JSON boolean true confirms acceptance after HTTP success.
	for my $body ('{"ok":false}', '{}', 'null', '[]', '<html>error</html>',
		'{"ok":"true"}', '{"ok":1}') {
		$reply = { success => 1, status => 200, content => $body };
		eval { send_cloudmin_notification($target, { id => 1, instance => 'fixture' }) };
		like($@, qr/Telegram delivery was not accepted/, 'HTTP success alone is insufficient');
		}
	$reply = { success => 0, status => 429, content => '{"ok":true}' };
	eval { send_cloudmin_notification($target, { id => 1, instance => 'fixture' }) };
	ok($@, 'HTTP failure cannot claim success through its body');
	# A rejected send stays queued and must not expose response credentials.
	@requests = ( );
	$reply = { success => 1, status => 200,
		content => '{"ok":false,"description":"123456:fixture_Token-abc"}' };
	my $test = $store->test_target($id, 1000, \&send_cloudmin_notification);
	ok($test->{error}, 'rejected test send reports failure');
	my $history = $store->history(undef, 0, 100);
	is($history->{events}[0]{deliveries}[0]{state}, 'queued', 'rejection stays queued');
	unlike(Cloudmin::Notifications::encode($history), qr/fixture_Token/,
		'failure history omits response credentials');
	# A later accepted reply completes the same delivery.
	$reply = { success => 1, status => 200, content => '{"ok":true,"result":{}}' };
	is($store->deliver(\&send_cloudmin_notification, 1121), 1, 'rejected message retries');
	is($store->history(undef, 0, 100)->{events}[0]{deliveries}[0]{state}, 'sent',
		'positive Bot API acknowledgment records success');
	is_deeply($requests[0], $requests[1], 'retry preserves request and event identity');
	# A successful response can echo all 4096 characters as Unicode escapes.
	my $echo = JSON::PP->new->ascii->encode({ ok => JSON::PP::true(),
		result => { text => "😀" x 4096 } });
	cmp_ok($http_options{max_size}, '>=', length($echo),
		'response limit allows a full Unicode message');
	# post(self, url, options) throws an error containing the private URL.
	# The caller must receive a safe error without that URL.
	local *HTTP::Tiny::post = sub { die "Network failure for $_[1]\n" };
	eval { send_cloudmin_notification($target, { id => 1, instance => 'fixture' }) };
	like($@, qr/Webhook delivery was not accepted/, 'transport error is fixed text');
	unlike($@, qr/fixture_Token|api\.telegram/, 'transport exception hides token and URL');
	};

done_testing();
