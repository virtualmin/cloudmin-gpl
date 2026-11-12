use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use Test::More;
use File::Temp qw(tempdir);
use WebminCore;
no warnings qw(redefine once);
our ($module_root_directory, $module_var_directory, $remote_user);
# Load the API with a private data directory.
$module_root_directory = "$Bin/..";
$module_var_directory = tempdir(CLEANUP => 1);
$remote_user = 'fixture';
require "$module_root_directory/cloudmin-notifications-lib.pl";
my $vm = '11111111-1111-4111-8111-111111111111';
my ($host, $manage, $readonly, $checked) = ( 0, 0, 0, 0 );

# require_access(grant, [id]) models an assigned guest viewer or administrator.
sub require_access
{
my ($grant, $id) = @_;
die "Denied\n" unless $grant eq 'view' && $id eq $vm ||
	$grant eq 'host' && $host || $grant eq 'manage' && $manage;
}

# is_readonly_mode() supplies the fixture's global write restriction.
sub is_readonly_mode { return $readonly; }

# get_image_jobs() checks signatures without creating any host job state.
sub get_image_jobs { return bless { }, 'TokenFixture'; }

# TokenFixture::check_token(self, user, token) accepts one fixture signature.
sub TokenFixture::check_token
{
$checked++;
die "Invalid token\n" unless ($_[2] || '') eq 'valid';
}

# ensure_notification_schedule([interval]) is declared first, so the stub
# below can replace the loaded scheduler helper.
sub ensure_notification_schedule;
{
no warnings 'redefine';
# ensure_notification_schedule([interval]) avoids workstation cron changes.
*ensure_notification_schedule = sub { };
}

# webmin_log(action, type, id, fields) checks that
# submitted fields stay private.
sub webmin_log
{
is_deeply($_[3], { }, 'audit contains no submitted fields');
}
# Guests cannot inspect host configuration or invoke management actions.
for my $action (qw(notification_config save_notification_target
	test_notification_target delete_notification_rule mute_notifications
	unmute_notifications)) {
	eval { call_notification_api($action, { }) };
	like($@, qr/Denied/, "$action requires host access");
	}
ok(!-d "$module_var_directory/notifications", 'denied calls never open storage');
is_deeply(call_notification_api('notifications', { id => $vm })->{events}, [ ],
	'assigned guest can read empty history');
for my $id ('*', '../host', [ ], '22222222-2222-4222-8222-222222222222') {
	eval { call_notification_api('notifications', { id => $id }) };
	ok($@, 'invalid or unassigned guest rejected');
	}
# Host read access, write access and a valid token are separate requirements.
$host = 1;
my $request = { token => 'valid', target => { name => 'Fixture', type => 'email',
	address => 'ops@example.invalid' } };
eval { call_notification_api('save_notification_target', $request) };
like($@, qr/Denied/, 'host read grant alone cannot edit');
$manage = 1;
$readonly = 1;
eval { call_notification_api('save_notification_target', $request) };
like($@, qr/read-only/, 'read-only mode blocks writes');
$readonly = 0;
eval { call_notification_api('save_notification_target', { %$request, token => '' }) };
like($@, qr/Invalid token/, 'write requires a valid signed token');
# A signed test request queues delivery without using a real transport.
my $saved = call_notification_api('save_notification_target', $request);
ok($saved->{id}, 'authorized target saved');
my $test = call_notification_api('test_notification_target',
	{ token => 'valid', object => $saved->{id} });
ok($test->{id}, 'test action queues without network delivery');
$host = 0;
is_deeply(call_notification_api('notifications', { id => $vm })->{events}, [ ],
	'guest cannot read host test events');
is($checked, 3, 'every permitted mutation verifies its token');
# Combined saves require the same grants and signature as separate writes.
my $combined = { token => 'valid',
	rule => { name => 'Combined', metric => 'cpu', enabled => 0 },
	target => { name => 'Combined email', type => 'email',
		address => 'combined@example.invalid' } };
eval { call_notification_api('save_notification_rule', $combined) };
like($@, qr/Denied/, 'guest cannot create a rule and destination together');
# Missing management access, read-only mode and a bad token each block
# the combined save.
$host = 1;
$manage = 0;
eval { call_notification_api('save_notification_rule', $combined) };
like($@, qr/Denied/, 'combined save requires management access');
$manage = 1;
$readonly = 1;
eval { call_notification_api('save_notification_rule', $combined) };
like($@, qr/read-only/, 'combined save respects read-only mode');
$readonly = 0;
eval { call_notification_api('save_notification_rule',
	{ %$combined, token => '' }) };
like($@, qr/Invalid token/, 'combined save requires a signature');
# Failed combined validation must roll back the inline destination too.
my $before = get_notifications()->configuration();
eval { call_notification_api('save_notification_rule',
	{ %$combined, rule => { %{$combined->{rule}}, threshold => 101 } }) };
ok($@, 'invalid combined rule fails');
is_deeply(get_notifications()->configuration(), $before,
	'API failure leaves no new destination');
# A valid combined request connects its two committed records.
my $new = call_notification_api('save_notification_rule', $combined);
my $cfg = call_notification_api('notification_config', { });
my ($rule) = grep { $_->{id} eq $new->{id} } @{$cfg->{rules}};
my ($dest) = grep { $_->{name} eq 'Combined email' } @{$cfg->{targets}};
is_deeply($rule->{targets}, [ $dest->{id} ],
	'authorized combined request saves and connects both records');
# Mute actions need host access, management, a writable session and a token.
for my $action (qw(mute_notifications unmute_notifications)) {
	my $input = { id => $vm, token => 'valid' };
	$host = 0; $manage = 1; $readonly = 0;
	eval { call_notification_api($action, $input) };
	like($@, qr/Denied/, "$action denies guest managers");
	$host = 1; $manage = 0;
	eval { call_notification_api($action, $input) };
	like($@, qr/Denied/, "$action requires management");
	$manage = 1; $readonly = 1;
	eval { call_notification_api($action, $input) };
	like($@, qr/read-only/, "$action rejects read-only sessions");
	$readonly = 0;
	eval { call_notification_api($action, { %$input, token => 'bad' }) };
	like($@, qr/Invalid token/, "$action requires a signed token");
	}
# A host manager mutes each scope, and an assigned guest viewer sees it.
for my $scope ($vm, 'all') {
	my $mute = call_notification_api('mute_notifications',
		{ id => $scope, token => 'valid' });
	is($mute->{muted}, 1, 'host manager can mute the selected scope');
	$host = 0;
	my $data = call_notification_api('notifications', { id => $vm });
	ok($scope eq 'all' ? $data->{all_muted} : $data->{muted},
		'assigned guest viewer sees applicable mute status');
	$host = 1;
	call_notification_api('unmute_notifications', { id => $scope, token => 'valid' });
	$data = call_notification_api('notifications', { id => $vm });
	ok(!$data->{muted} && !$data->{all_muted}, 'unmute clears active status');
	}
# A missing or malformed scope fails instead of muting everything.
for my $scope (undef, '', 'host', '*', [ ], '../all') {
	eval { call_notification_api('mute_notifications', { id => $scope, token => 'valid' }) };
	ok($@, 'invalid scope never defaults to muting everything');
	}
done_testing();
