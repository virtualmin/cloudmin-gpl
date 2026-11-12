#!/usr/bin/perl
# check-notification-providers.pl module-root task-dir
# smtp-port https-port ca-file
# All recipients and HTTPS endpoints belong to loopback fixture servers.
use strict;
use warnings;
no warnings 'once';
use utf8;
use Test::More;
use HTTP::Tiny;
# Run only as root from a shell, with a fixture directory under /tmp.
die "Run from a root Linux test shell\n" unless $^O eq 'linux' && $< == 0 &&
	!$ENV{GATEWAY_INTERFACE};
my ($module, $dir, $smtp, $https, $ca) = @ARGV;
die "Invalid fixture arguments\n" unless $module && -d $module &&
	$dir =~ m{\A/(?:var/)?tmp/cloudmin-notifications\.[A-Za-z0-9]+/providers\z} &&
	$smtp =~ /^\d+$/ && $https =~ /^\d+$/ && -f $ca;
# Load the installed module with a private notification store.
$ENV{WEBMIN_CONFIG} = '/etc/webmin';
$ENV{WEBMIN_VAR} = '/var/webmin';
$ENV{REMOTE_USER} = 'root';
chdir($module) or die $!;
$0 = "$module/notification-fixture.pl";
require './server-manager-lib.pl';
our ($cloudmin_notifications_directory, $error_must_die);
$error_must_die = 1;
$cloudmin_notifications_directory = $dir;
# Only this fixture redirects hosted APIs to the local HTTPS receiver.
local $Cloudmin::NotificationMessages::telegram_api_base =
	"https://127.0.0.1:$https";
local $Cloudmin::NotificationMessages::pushover_api_base =
	"https://127.0.0.1:$https";
foreign_require('mailboxes');
# Set the link after module loading, which reloads Webmin's global settings.
# A hostile request host must not replace this configured link.
local $WebminCore::gconfig{webmin_email_url} = 'https://cloudmin.example.invalid:10000';
local $ENV{HTTP_HOST} = 'untrusted.example.invalid';
local %mailboxes::config = (%mailboxes::config, send_mode => '127.0.0.1',
	smtp_port => $smtp, smtp_ssl => 0, smtp_user => '', smtp_pass => '',
	webmin_from => 'cloudmin@example.invalid');
local %mailboxes::userconfig = ( );
# Trust only the fixture CA for these requests, keeping real TLS verification.
my $new = \&HTTP::Tiny::new;
no warnings 'redefine';
# new(class, [options...]) checks TLS and trusts the fixture certificate.
local *HTTP::Tiny::new = sub {
	my ($class, %options) = @_;
	ok($options{verify_SSL}, 'transport verifies certificates');
	is($options{max_redirect}, 0, 'transport rejects redirects');
	return $new->($class, %options, SSL_options => { SSL_ca_file => $ca });
	};
# Send every provider request to the local receiver, using dummy credentials.
my $store = get_notifications();
my @targets;
for my $type (qw(slack discord teams ntfy)) {
	push @targets, $store->save_target({ name => $type, type => $type,
		address => "https://127.0.0.1:$https/$type".
			($type eq 'discord' ? '?thread_id=123&wait=false' :
			 $type eq 'teams' ? '?sig=fixture-signature' : ''),
		secret => $type eq 'ntfy' ? 'fixture-bearer' : '' })->{id};
	}
# Hosted and self-hosted push methods use dummy application credentials.
push @targets, $store->save_target({ name => 'Pushover', type => 'pushover',
	address => 'u' x 30, secret => 'a' x 30 })->{id};
push @targets, $store->save_target({ name => 'Gotify', type => 'gotify',
	address => "https://127.0.0.1:$https/gotify/",
	secret => 'fixture-Gotify-token' })->{id};
# Telegram and email complete these eight delivery methods.
push @targets, $store->save_target({ name => 'Telegram', type => 'telegram',
	address => '-1001234567890', secret => '123456:fixture_Telegram-token' })->{id};
push @targets, $store->save_target({ name => 'Mail', type => 'email',
	address => 'sink@example.invalid' })->{id};
# One low-space event exercises readable units and a non-ASCII rule name.
my $now = time();
my $rule = $store->save_rule({ name => 'Свободно място', metric => 'filesystem_free',
	scope => 'host', device => '/', threshold => 10, duration => 0,
	targets => \@targets }, $now)->{id};
$store->evaluate({ $rule => [ { owner => 'host', subject => 'host/',
	label => 'Host /', value => 8.5 } ] }, $now, { });
# The first pass reaches every method. Four fail temporarily.
is($store->deliver(\&send_cloudmin_notification, $now), 8,
	'eight transports attempt the real alert');
my $event = $store->history()->{events}[0];
is(scalar(grep { $_->{state} eq 'sent' } @{$event->{deliveries}}), 4,
	'mail, Teams, Gotify and ntfy accept their first attempts');
is(scalar(grep { $_->{state} eq 'queued' } @{$event->{deliveries}}), 4,
	'temporary provider failures and rate limits stay queued');
# Retry only the providers that failed temporarily.
is($store->deliver(\&send_cloudmin_notification, $now + 121), 4,
	'only failed provider deliveries retry');
$event = $store->history()->{events}[0];
is(scalar(grep { $_->{state} eq 'sent' } @{$event->{deliveries}}), 8,
	'every transport records acceptance');
# Dummy recipient keys trigger HTTP 400, quota 429 and API status 0 responses.
for my $key (qw(b q r)) {
	my $id = $store->save_target({ name => 'Rejected Pushover '.$key,
		type => 'pushover', address => $key x 30,
		secret => 'a' x 30 })->{id};
	my $test = $store->test_target($id, $now + 200,
		\&send_cloudmin_notification);
	ok($test->{error}, 'permanent rejection reports test failure');
	my ($failed) = grep { $_->{id} == $test->{id} }
		@{$store->history()->{events}};
	is($failed->{deliveries}[0]{state}, 'failed',
		'permanent Pushover rejection stops immediately');
	is($failed->{deliveries}[0]{attempts}, 1, 'one attempt is recorded');
	}
is($store->deliver(\&send_cloudmin_notification, $now + 1000), 0,
	'permanent Pushover rejections are not retried');
# No credential may appear in listings or history.
unlike(Cloudmin::Notifications::encode($store->configuration()),
	qr/fixture-(?:signature|bearer|Gotify)|fixture_Telegram|[au]{30}/,
	'configuration hides credentials');
unlike(Cloudmin::Notifications::encode($store->history()),
	qr/fixture_Telegram|fixture-Gotify|a{30}|u{30}/,
	'history hides tokens from rejected responses');
is($event->{unit}, 'GiB', 'real event records absolute units');
is($event->{comparison}, 'le', 'real event records lower threshold');
done_testing();
