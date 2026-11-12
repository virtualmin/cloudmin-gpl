#!/usr/bin/perl
# check-notification-silences.pl module-root fixture-directory webhook-port
# Exercise the installed worker and transport using private notification data.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
no warnings 'once';
# Run only as root on Linux, never from a web request.
die "Run on a Linux debug host as root\n"
	unless $^O eq 'linux' && $< == 0 && !$ENV{GATEWAY_INTERFACE};
# Accept only a data directory inside this run's task directory.
my ($module, $directory, $port) = @ARGV;
die "Invalid fixture arguments\n" unless $module && -d $module &&
	$directory =~ m{\A/tmp/cloudmin-silences\.[A-Za-z0-9]+/data\z} &&
	$port =~ /\A\d+\z/;
# Load the installed module as root, with errors thrown and a private store.
$ENV{WEBMIN_CONFIG} = '/etc/webmin';
$ENV{WEBMIN_VAR} = '/var/webmin';
$ENV{REMOTE_USER} = 'root';
chdir($module) or die $!;
$0 = "$module/api.pl";
require './server-manager-lib.pl';
require './cloudmin-notifications-lib.pl';
our ($cloudmin_notifications_directory, $error_must_die);
$error_must_die = 1;
$cloudmin_notifications_directory = $directory;
# Mute everything, then add a root filesystem rule that always matches. Its
# webhook goes to the loopback receiver.
my $store = get_notifications();
my $target = $store->save_target({ name => 'Silence fixture', type => 'webhook',
	address => "http://127.0.0.1:$port/events" })->{id};
$store->mute('all', 1, time());
my $rule = $store->save_rule({ name => 'Live filesystem', metric => 'filesystem_free',
	scope => 'host', device => '/', threshold => 999999, duration => 0, cooldown => 0,
	targets => [ $target ] }, time())->{id};
# A real filesystem reading must detect the condition without sending it.
run_cloudmin_notifications();
ok(!$store->metadata('worker')->{error}, 'installed worker completed');
my $history = $store->history();
is($history->{events}[0]{silenced}, 'all', 'live reading recorded during global mute');
is($history->{events}[0]{deliveries}[0]{state}, 'muted', 'live worker withheld delivery');
ok($history->{states}[0]{active}, 'real filesystem condition remains active');
# Manual unmute resumes current alerts without resetting the incident.
$store->mute('all', 0, time());
run_cloudmin_notifications();
$history = $store->history();
is(scalar(@{$history->{events}}), 2, 'current problem fires after unmute');
is($history->{events}[-1]{deliveries}[0]{state}, 'sent', 'fresh alert reached loopback HTTP');
# Switch to an isolated guest fixture and use the actual delivery adapter.
$store->remove('rule', $rule);
my $guest = '11111111-1111-4111-8111-111111111111';
$rule = $store->save_rule({ name => 'Guest mute fixture', metric => 'cpu',
	scope => $guest, duration => 0, cooldown => 0, targets => [ $target ] }, time())->{id};
# A guest mute stops a new guest alert from reaching the transport.
my $time = time();
$store->mute($guest, 1, $time);
my $reading = { $rule => [ { owner => $guest, subject => $guest,
	label => 'Fixture guest', value => 99, running => 1 } ] };
$store->evaluate($reading, $time, { });
is($store->deliver(\&send_cloudmin_notification, $time), 0, 'guest mute prevents transport');
# The mute still holds after reopening the store a day later.
$store = Cloudmin::Notifications->new(directory => $directory);
$store->evaluate($reading, $time + 86400, { });
is($store->deliver(\&send_cloudmin_notification, $time + 86400), 0,
	'mute persists after reopening and a day passing');
# Unmuting sends one fresh alert through the real HTTP transport.
$store->mute($guest, 0, $time + 86401);
$store->evaluate($reading, $time + 86401, { });
is($store->deliver(\&send_cloudmin_notification, $time + 86401), 1,
	'manual unmute sends one fresh alert');
is($store->history()->{events}[-1]{deliveries}[0]{state}, 'sent',
	'guest alert was accepted by HTTP sink');
done_testing();
