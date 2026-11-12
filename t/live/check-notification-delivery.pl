#!/usr/bin/perl
# check-notification-delivery.pl module-root fixture-dir smtp-port webhook-port
# Uses private notification state and loopback sinks, never real recipients.
use strict;
use warnings;
no warnings 'once';
use Test::More;
use File::Path qw(make_path);
use JSON::PP ();
# Run only as root from a shell, with a fixture directory under /tmp.
die "Run from a root Linux test shell\n" unless $^O eq 'linux' && $< == 0 &&
	!$ENV{GATEWAY_INTERFACE};
my ($module, $dir, $smtp, $http) = @ARGV;
die "Invalid fixture arguments\n" unless $module && -d $module &&
	$dir =~ m{\A/(?:var/)?tmp/cloudmin-notifications\.[A-Za-z0-9]+/delivery\z} &&
	$smtp =~ /^\d+$/ && $http =~ /^\d+$/;
# Load the installed transport code with private notification and metric paths.
$ENV{WEBMIN_CONFIG} = '/etc/webmin';
$ENV{WEBMIN_VAR} = '/var/webmin';
$ENV{REMOTE_USER} = 'root';
chdir($module) or die $!;
$0 = "$module/notification-fixture.pl";
require './server-manager-lib.pl';
our ($cloudmin_notifications_directory, $cloudmin_statistics_runtime,
     $module_var_directory, %config, $error_must_die);
# Webmin errors must throw, so a failed send is caught and recorded.
$error_must_die = 1;
$cloudmin_notifications_directory = "$dir/store";
$cloudmin_statistics_runtime = "$dir/runtime";
make_path($cloudmin_statistics_runtime, { mode => 0700 });
foreign_require('mailboxes');
# Localized mail configuration cannot affect any other Webmin process.
local %mailboxes::config = (%mailboxes::config, send_mode => '127.0.0.1',
	smtp_port => $smtp, smtp_ssl => 0, smtp_user => '', smtp_pass => '',
	webmin_from => 'cloudmin@example.invalid');
local %mailboxes::userconfig = ( );
# Only loopback SMTP and HTTP sinks receive fixture events.
my $store = get_notifications();
my $email = $store->save_target({ name => 'Fixture email', type => 'email',
	address => 'sink@example.invalid' })->{id};
my $hook = $store->save_target({ name => 'Fixture hook', type => 'webhook',
	address => "http://127.0.0.1:$http/events" })->{id};
my $bad = $store->save_target({ name => 'Fail once', type => 'webhook',
	address => "http://127.0.0.1:$http/retry" })->{id};
# One failing HTTP endpoint must not prevent SMTP or the healthy webhook.
my $now = time();
my $first = $store->test_target($email, $now)->{id};
my $second = $store->test_target($hook, $now)->{id};
my $third = $store->test_target($bad, $now)->{id};
is($store->deliver(\&send_cloudmin_notification, $now), 3,
	'real mail and HTTP transports attempted independently');
my $events = $store->history(undef, 0, 100)->{events};
is($events->[0]->{deliveries}->[0]->{state}, 'sent',
	'Webmin mail transport accepted fixture email');
is($events->[1]->{deliveries}->[0]->{state}, 'sent', 'webhook accepted JSON');
is($events->[2]->{deliveries}->[0]->{state}, 'queued', 'HTTP 503 is retryable');
# Reopening storage preserves the failed receipt and its event identity.
$store = get_notifications();
is($store->deliver(\&send_cloudmin_notification, $now + 121), 1,
	'reopened store retries only failed destination');
is($store->history(undef, $third - 1, 1)->{events}->[0]->{deliveries}->[0]->{state},
	'sent', 'retry accepted with original event ID');

# The worker reads isolated samples and sends alerts and recoveries.
require './cloudmin-statistics-lib.pl';
my $rule = $store->save_rule({ name => 'Fixture pressure', metric => 'cpu',
	scope => 'host', threshold => 90, duration => 0, recovery => 1,
	targets => [ $hook ] }, $now)->{id};
# Publish a fresh high-CPU sample for the worker to read.
my $stamp = Time::HiRes::time();
Cloudmin::Statistics::atomic_write(
	"$cloudmin_statistics_runtime/statistics-latest.json",
	Cloudmin::Notifications::encode({ version => 1, checked_at => $stamp,
		interval => 10, host => { values => { cpu => 95 } }, vms => { } }));
local $config{statistics_enabled} = 1;
run_cloudmin_notifications();
my $firing = $store->history(undef, $third, 100)->{events};
is($firing->[0]->{phase}, 'firing', 'unattended worker evaluates collector cache');
is($firing->[0]->{deliveries}->[0]->{state}, 'sent', 'worker delivers its alert');
# Turning collection off pauses checks while queued messages still deliver.
local $config{statistics_enabled} = 0;
run_cloudmin_notifications();
is($store->history(undef, 0, 100)->{states}->[0]->{status}, 'paused',
	'disabled collection pauses existing incident');
my $offtest = $store->test_target($hook, time())->{id};
run_cloudmin_notifications();
is($store->history(undef, $offtest - 1, 1)->{events}->[0]->{deliveries}->[0]->{state},
	'sent', 'queued delivery continues with statistics disabled');
# A later fresh healthy sample resolves the original active incident.
$config{statistics_enabled} = 1;
sleep(1);
Cloudmin::Statistics::atomic_write(
	"$cloudmin_statistics_runtime/statistics-latest.json",
	Cloudmin::Notifications::encode({ version => 1, checked_at => Time::HiRes::time(),
		interval => 10, host => { values => { cpu => 30 } }, vms => { } }));
run_cloudmin_notifications();
is($store->history(undef, 0, 100)->{events}->[-1]->{phase}, 'resolved',
	'fresh healthy reading sends recovery');
ok(!$store->metadata('worker')->{error}, 'worker completed without errors');
done_testing();
