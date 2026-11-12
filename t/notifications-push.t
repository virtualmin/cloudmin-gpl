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
# Load delivery with isolated storage and no external requests.
$module_root_directory = "$Bin/..";
$module_var_directory = tempdir(CLEANUP => 1);
require "$module_root_directory/cloudmin-notifications-lib.pl";

# fixture(type) returns private storage and a dummy push destination.
sub fixture
{
my ($type) = @_;
my $store = Cloudmin::Notifications->new(directory => tempdir(CLEANUP => 1));
return ($store, { name => 'Push fixture', type => $type,
	address => $type eq 'pushover' ? 'u' x 30
		: 'https://push.example.invalid/gotify/',
	secret => 'a' x 30 });
}

# Reject malformed credentials and prevent reuse at another destination.
subtest 'Validate push destinations and hide credentials' => sub {
	for my $type (qw(pushover gotify)) {
		my ($store, $target) = fixture($type);
		my $id = $store->save_target($target)->{id};
		my $public = $store->configuration()->{targets}[0];
		ok($public->{has_secret} && !exists($public->{secret}),
			"$type application token stays private");
		if ($type eq 'pushover') {
			# Management listings must also hide recipient keys.
			ok($public->{has_private_address} &&
				!exists($public->{address}),
				'recipient key is hidden');
			}
		else {
			# Gotify URLs contain no authentication data.
			is($public->{address}, $target->{address},
				'Gotify server URL remains visible');
			}
		# Valid edits and switches preserve credentials.
		my %edit = ( %$target, id => $id );
		delete($edit{secret});
		$store->save_target(\%edit);
		$store->set_target_enabled($id, 0);
		is($store->target($id)->{secret}, $target->{secret},
			"$type omitted token is retained");
		for my $token (undef, '', "bad\nvalue", 'with space',
			[ 'token' ], 'токен') {
			eval { $store->save_target(
				{ %edit, secret => $token }) };
			like($@, qr/token/, "$type invalid token rejected");
			}
		eval { $store->save_target({ %edit, clear_secret => 1 }) };
		like($@, qr/token/, "$type required token cannot be cleared");
		my $other = $type eq 'pushover' ? 'v' x 30
			: 'https://other.example.invalid';
		eval { $store->save_target({ %edit, address => $other }) };
		like($@, qr/token/, "$type new address needs a token");
		# A different method must supply its own token.
		my $old = $store->save_target({ %$target, type => 'webhook',
			address => 'https://push.example.invalid' })->{id};
		eval { $store->save_target({ name => 'Changed', id => $old,
			type => 'gotify',
			address => 'https://push.example.invalid' }) };
		like($@, qr/token/, 'changed method needs its own token');
		}
	# Pushover keys have a fixed ASCII format, including mixed case.
	my ($store, $target) = fixture('pushover');
	for my $key ('a' x 29, 'a' x 31, ('a' x 29).'_',
		'https://example.invalid', [ 'key' ]) {
		eval { $store->save_target({ %$target, address => $key }) };
		ok($@, 'invalid recipient key rejected');
		eval { $store->save_target({ %$target, secret => $key }) };
		ok($@, 'invalid application token rejected');
		}
	my $key = 'Ab9' x 10;
	my $id = $store->save_target({ %$target, address => $key,
		secret => $key })->{id};
	is($store->target($id)->{address}, $key, 'key case is preserved');
	# Gotify cannot send tokens over HTTP or embed them in a URL.
	($store, $target) = fixture('gotify');
	for my $url ('http://push.example.invalid',
		'ftp://push.example.invalid',
		'https://user:pass@push.example.invalid',
		'https://push.example.invalid?token=private',
		'https://push.example.invalid/#fragment', 'https://bad host/') {
		eval { $store->save_target({ %$target, address => $url }) };
		ok($@, 'unsafe Gotify URL rejected');
		unlike($@, qr/private|user:pass/,
			'error does not echo the URL');
		}
	};

# Check real request formats, path prefixes and character limits.
subtest 'Build provider requests without interpreting message text' => sub {
	my $event = { id => 42, instance => 'fixture', severity => 'error' };
	my $message = { subject => 'я😀' x 200, body => 'я😀' x 2000 };
	my (undef, $target) = fixture('pushover');
	my $request = Cloudmin::NotificationMessages::request(
		$target, $event, $message);
	is($request->{url}, 'https://api.pushover.net/1/messages.json',
		'Pushover uses the fixed HTTPS API');
	my $payload = JSON::PP->new->utf8->decode($request->{content});
	is($payload->{token}, $target->{secret}, 'application token in JSON');
	is($payload->{user}, $target->{address}, 'recipient key in JSON');
	is($payload->{title}, substr($message->{subject}, 0, 250),
		'title limit counts characters');
	is($payload->{message}, substr($message->{body}, 0, 1024),
		'message limit preserves Unicode');
	is($payload->{priority}, 0, 'normal priority respects quiet hours');
	ok(!exists($payload->{html}) && !exists($payload->{monospace}),
		'Pushover uses plain text');
	ok(!exists($request->{headers}{Authorization}), 'no bearer header');
	# Each URL form appends exactly one message path after the base path.
	(undef, $target) = fixture('gotify');
	for my $path ('', '/', '/gotify', '/gotify/', '/push%20server/') {
		$request = Cloudmin::NotificationMessages::request(
			{ %$target,
			  address => 'https://push.example.invalid'.$path },
			$event, $message);
		my $base = $path;
		$base =~ s{/\z}{};
		is($request->{url},
			'https://push.example.invalid'.$base.'/message',
			'reverse-proxy path is preserved');
		}
	$payload = JSON::PP->new->utf8->decode($request->{content});
	is_deeply($payload, { title => $message->{subject},
		message => $message->{body}, priority => 5 },
		'Gotify receives readable JSON without formatting extras');
	is($request->{headers}{'X-Gotify-Key'}, $target->{secret},
		'Gotify authenticates with its application header');
	ok(!exists($request->{headers}{Authorization}), 'no duplicate auth');
	unlike($request->{url}.$request->{content}, qr/$target->{secret}/,
		'Gotify token stays out of the URL and body');
	};

# Reject misleading HTTP successes and exercise the normal retry queue.
subtest 'Confirm acceptance and retry without exposing credentials' => sub {
	my ($reply, @requests, %options);
	# new(class, options...) captures TLS and redirect settings.
	local *HTTP::Tiny::new = sub {
		my ($class, %input) = @_;
		%options = %input;
		return bless { }, $class;
		};
	# post(self, url, options) captures requests without opening a socket.
	local *HTTP::Tiny::post = sub {
		push @requests, [ $_[1], $_[2] ];
		return $reply;
		};
	# notification_message(event) supplies fixed text for these requests.
	local *main::notification_message = sub {
		return { subject => 'Test', body => 'Fixture' };
		};
	for my $type (qw(pushover gotify)) {
		my ($store, $target) = fixture($type);
		my $id = $store->save_target($target)->{id};
		my $field = $type eq 'pushover' ? 'status' : 'id';
		my $event = { id => 1, instance => 'fixture' };
		for my $body ('{}', 'null', '[]', '<html>login</html>',
			'{"'.$field.'":0}', '{"'.$field.'":true}',
			'{"'.$field.'":[]}', '{"'.$field.'":-1}') {
			$reply = { success => 1, status => 200,
				content => $body };
			eval { send_cloudmin_notification($target, $event) };
			like($@, qr/delivery was not accepted/,
				"$type requires a valid receipt");
			}
		$reply = { success => 0, status => 429,
			content => '{"'.$field.'":1}' };
		eval { send_cloudmin_notification($target, $event) };
		ok($@, "$type HTTP failure overrides a positive receipt");
		# Responses may echo tokens. History must omit them.
		@requests = ( );
		$reply = { success => 1, status => 200,
			content => '{"error":"'.$target->{secret}.'"}' };
		my $test = $store->test_target($id, 1000,
			\&send_cloudmin_notification);
		ok($test->{error}, "$type unreadable reply reports failure");
		my $history = $store->history(undef, 0, 100);
		is($history->{events}[0]{deliveries}[0]{state}, 'queued',
			"$type unreadable reply stays queued");
		unlike(Cloudmin::Notifications::encode($history),
			qr/$target->{secret}/, 'history omits echoed tokens');
		$reply = { success => 1, status => 200,
			content => '{"'.$field.'":1}' };
		is($store->deliver(\&send_cloudmin_notification, 1121), 1,
			"$type retries after an unreadable reply");
		$history = $store->history(undef, 0, 100);
		is($history->{events}[0]{deliveries}[0]{state},
			'sent', "$type accepted retry completes delivery");
		is_deeply($requests[0], $requests[1],
			'retry keeps event identity');
		ok($options{verify_SSL}, 'TLS certificates are checked');
		is($options{max_redirect}, 0,
			'redirects cannot forward credentials');
		}
	};

# Check permanent and temporary failures through both delivery entry points.
subtest 'Pushover stops permanent failures and keeps temporary retries' => sub {
	my ($reply, @requests);
	my $send = \&send_cloudmin_notification;
	# new(class, options...) prevents this fixture from opening sockets.
	local *HTTP::Tiny::new = sub { return bless { }, 'HTTP::Tiny'; };
	# post(self, url, options) captures attempts or throws a network error.
	local *HTTP::Tiny::post = sub {
		push @requests, [ $_[1], $_[2] ];
		die "Network failure with ".('a' x 30)."\n" unless $reply;
		return $reply;
		};
	# notification_message(event) supplies fixed text without host settings.
	local *main::notification_message = sub {
		return { subject => 'Test', body => 'Fixture' };
		};
	my $rejected = '{"status":0,"errors":["'.('a' x 30).'"]}';
	my @cases = (
		[ 400, $rejected, 1 ], [ 401, $rejected, 1 ],
		[ 403, $rejected, 1 ], [ 404, '<html>error</html>', 1 ],
		[ 429, $rejected, 1 ], [ 400, '{"status":1}', 1 ],
		[ 200, $rejected, 1 ], [ 200, '{"status":-1}', 1 ],
		[ 200, '{"status":2}', 1 ],
		[ 500, $rejected, 0 ], [ 503, $rejected, 0 ],
		[ 599, '', 0 ], [ 200, '<html>error</html>', 0 ],
		[ 200, '{}', 0 ], [ 200, '{"status":null}', 0 ],
		[ 200, '{"status":false}', 0 ],
		[ 200, '{"status":[]}', 0 ], [ 0, '', 0 ] );
	for my $immediate (0, 1) {
		for my $case (@cases) {
			my ($status, $body, $permanent) = @$case;
			my $label = "HTTP $status, immediate=$immediate";
			my ($store, $target) = fixture('pushover');
			my $id = $store->save_target($target)->{id};
			@requests = ( );
			$reply = $status ? { status => $status,
				success => $status == 200,
				content => $body } : undef;
			# Test both immediate and queued delivery.
			my $test = $store->test_target($id, 1000,
				$immediate ? $send : undef);
			$store->deliver($send, 1000)
				unless $immediate;
			my $history = $store->history();
			my $delivery = $history->{events}[0]{deliveries}[0];
			is($delivery->{state}, $permanent ? 'failed' : 'queued',
				"$label gets the correct retry state");
			is($delivery->{attempts}, 1, 'one attempt is recorded');
			unlike(Cloudmin::Notifications::encode($history),
				qr/a{30}/, 'provider text stays private');
			my $config = $store->configuration();
			is($config->{targets}[0]{last_delivery}{state},
				$delivery->{state},
				'destination shows the same result');
			# No failure may bypass the first two-minute backoff.
			is($store->deliver($send, 1119), 0,
				'no early automatic retry');
			$reply = { success => 1, status => 200,
				content => '{"status":1}' };
			if ($permanent) {
				# Manual retry is required after rejection.
				is($store->deliver($send, 2000),
					0, 'no automatic retry');
				is(scalar(@requests), 1, 'no second request');
				like($delivery->{error}, qr/before retrying/,
					'correction needed before retry');
				$store->retry($test->{id}, 2001);
				is($store->deliver($send, 2001),
					1, 'manual retry succeeds');
				}
			else {
				# Temporary failures wait for backoff.
				is($store->deliver($send, 1120),
					1, 'temporary failure retries');
				}
			is_deeply($requests[0], $requests[1],
				'retry preserves the event and request');
			is($store->history()->{events}[0]{deliveries}[0]{state},
				'sent', 'accepted retry completes delivery');
			}
		}
	# Other services keep their existing handling of rate-limit responses.
	my ($store, $target) = fixture('gotify');
	my $id = $store->save_target($target)->{id};
	$reply = { success => 0, status => 429, content => '{}' };
	$store->test_target($id, 1000, $send);
	is($store->history()->{events}[0]{deliveries}[0]{state}, 'queued',
		'Gotify rate limits still retry');
	};

done_testing();
