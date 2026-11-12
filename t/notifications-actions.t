use strict;
use warnings;
use utf8;
use Encode ();
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use Test::More;
use File::Temp qw(tempdir);
use WebminCore;
no warnings qw(redefine once);
our (%in, %text, $module_root_directory, $module_var_directory, $remote_user);
# Load the action handlers with a private data directory.
$module_root_directory = "$Bin/..";
$module_var_directory = tempdir(CLEANUP => 1);
$remote_user = 'fixture';
require "$module_root_directory/cloudmin-notifications-lib.pl";
require "$module_root_directory/cloudmin-print.pl";
# Load English strings so page titles and messages can be checked.
open(my $lang, '<', "$module_root_directory/lang/en") or die $!;
while (<$lang>) { chomp; $text{$1} = $2 if /^([^=]+)=(.*)$/; }
close($lang);
# The stubs below read these permission switches and fill these logs.
my ($host, $manage, $readonly) = ( 1, 1, 0 );
my (@sent, @audit);

# require_access(grant) models host and management permissions separately.
sub require_access
{
die "Denied\n" unless $_[0] eq 'host' ? $host : $manage;
}

# is_readonly_mode() supplies the session's current write restriction.
sub is_readonly_mode { return $readonly; }

# get_image_jobs() supplies a token verifier without opening the job database.
sub get_image_jobs { return bless { }, 'ActionToken'; }

# ActionToken::check_token(self, user, token) validates the signed fixture form.
sub ActionToken::check_token
{
die "Invalid token\n" unless ($_[2] || '') eq 'fixture-token';
}

# ReadParse() leaves the injected form input unchanged.
sub ReadParse { }
# error(message) makes CGI rejection catchable by the fixture.
sub error { die $_[0]; }
# error_message(error) returns fixture exceptions without live page setup.
sub error_message { return "$_[0]"; }
# redirect(url) captures a successful save without ending the fixture.
sub redirect { print "REDIRECT: $_[0]\n"; }
# ui_print_header(subtitle, title, [other_args...]) marks a confirmation page.
sub ui_print_header { print "HEADER: $_[1]\n"; }
# ui_print_unbuffered_header(subtitle, title, [other_args...])
# marks progress output.
sub ui_print_unbuffered_header { print "PROGRESS: $_[1]\n"; }
# ui_print_footer(url, [other_args...]) captures the
# destination of the return link.
sub ui_print_footer { print "RETURN: $_[0]\n"; }
# ensure_notification_schedule([interval]) prevents workstation cron changes.
*main::ensure_notification_schedule = sub { };
# webmin_log(action, [other_args...]) records only the
# action for audit assertions.
sub webmin_log { push @audit, $_[0]; }

# send_cloudmin_notification(target, event) captures attempts without sending.
# The Broken destination throws to exercise redaction and batch continuation.
*main::send_cloudmin_notification = sub {
push @sent, $_[0]->{id};
die "Transport leaked private-token\n" if $_[0]->{name} eq 'Broken';
};

# render(input, [method], [script]) captures the real CGI
# against an isolated store.
# method defaults to POST and script to the progressive action CGI. input may
# override the valid fixture token.
sub render
{
my ($input, $method, $script) = @_;
$script ||= 'notification_action_progressive.cgi';
# Supply the form input and request method the CGI expects.
local %in = ( token => 'fixture-token', %$input );
local $ENV{REQUEST_METHOD} = $method || 'POST';
local $ENV{CONTENT_LENGTH} = 0;
local $INC{'./server-manager-lib.pl'} = 1;
# Capture what the CGI prints.
my $html = '';
open(my $output, '>', \$html) or die $!;
{
	local *STDOUT = $output;
	do "$module_root_directory/$script";
	die $@ if $@;
	}
close($output);
return $html;
}

# One referenced destination and two unused ones exercise partial deletion.
my $store = get_notifications();
my @targets = map { $store->save_target({ name => $_, type => 'email',
	address => 'fixture@example.invalid' })->{id} }
	('<Ops>', 'Broken', 'Spare');
my $rule = $store->save_rule({ name => 'Rule', metric => 'cpu',
	targets => [ $targets[0] ], enabled => 0 }, time())->{id};
my $selection = { kind => 'target', object => join(',', @targets),
	delete => 1 };

# Invalid requests cannot delete records or send messages.
for my $case (
	[ { %$selection }, 'GET', qr/Use POST/ ],
	[ { %$selection, token => '' }, 'POST', qr/Invalid token/ ],
	[ { %$selection, object => '' }, 'POST', qr/Select one or more/ ],
	[ { %$selection, object => '../invalid' },
	  'POST', qr/Invalid.*selection/ ],
	[ { %$selection, object => 'a' x 32 },
	  'POST', qr/Notification not found/ ],
	[ { %$selection, send => 1 },
	  'POST', qr/Invalid.*action/ ],
	[ { kind => 'rule', object => $rule, send => 1 },
	  'POST', qr/Invalid.*action/ ],
) {
	eval { render($case->[0], $case->[1]) };
	like($@, $case->[2], 'invalid batch rejected before work');
	}
# Each permission must independently block the action before any mutation.
for my $permission (\$host, \$manage, \$readonly) {
	$$permission = !$$permission;
	eval { render($selection) };
	like($@, qr/Denied|read-only/,
		'bulk action respects session permissions');
	$$permission = !$$permission;
	}
is_deeply(\@sent, [ ], 'rejected selections send nothing');
is_deeply(\@audit, [ ], 'rejected selections change nothing');

# Confirmation names selected records and leaves them untouched.
my $html = render($selection);
like($html, qr/&lt;Ops&gt;/, 'confirmation escapes selected names');
unlike($html, qr/PROGRESS/, 'unconfirmed deletion does not start');
is(scalar(@{$store->configuration()->{targets}}), 3,
	'confirmation preserves all records');

# A destination row confirms only its own record with singular wording.
$html = render({ kind => 'target', object => $targets[2], delete => 1 });
like($html, qr/HEADER: Delete Notification Destination\n/,
	'row deletion uses a singular title');
like($html, qr/Delete this notification destination\?/,
	'row confirmation names one destination');
unlike($html, qr/Delete Selected|&lt;Ops&gt;|Broken/,
	'row confirmation contains no bulk selection or unrelated names');

# A failed deletion does not stop the remaining selected records.
$html = render({ %$selection, confirm => 1,
	object => join("\0", $targets[0], $targets[2], $targets[2]) });
like($html, qr/PROGRESS: Delete Notification Destinations/,
	'confirmed deletion opens progress');
like($html, qr/\.\. failed : remove this destination from its rules first/,
	'referenced destination reports its error');
like($html, qr/\.\. done/, 'unreferenced destination is removed');
is(scalar(() = $html =~ /data-first-print/g), 2,
	'duplicate selections are processed once');
is(scalar(@{$store->configuration()->{targets}}), 2,
	'only the removable destination is deleted');

# Test sends display actual acceptance or a safe per-destination failure.
$html = render({ kind => 'target', object => join(',', @targets[1, 0]),
	send => 1 });
like($html, qr/PROGRESS: Send Test Notifications/, 'test opens progress');
like($html, qr/\.\. failed : delivery failed/, 'transport failure is visible');
like($html, qr/\.\. done/, 'later target still receives its test');
unlike($html, qr/private-token|<Ops>/,
	'progress hides secrets and escapes names');
is_deeply(\@sent, [ @targets[1, 0] ], 'only selected targets are contacted');
like($html, qr/RETURN: notifications.cgi\?tab=targets/, 'return keeps its tab');

# Rule deletion confirms only its row and retains its history and destinations.
$html = render({ kind => 'rule', object => $rule, delete => 1 });
like($html, qr/HEADER: Delete Notification Rule\n/, 'rule has a singular title');
like($html, qr/Delete this notification rule\?/, 'rule confirmation is singular');
$html = render({ kind => 'rule', object => $rule, delete => 1, confirm => 1 });
like($html, qr/\.\. done/, 'rule deletion reports completion');
is_deeply($store->configuration()->{rules}, [ ], 'selected rule is removed');
is(scalar(@{$store->configuration()->{targets}}), 2, 'destinations remain');
is(scalar(@{$store->history(undef, 0, 100)->{events}}), 2, 'history remains');
# A test sent from one row names a single destination.
$html = render({ kind => 'target', object => $targets[0], send => 1 });
like($html, qr/PROGRESS: Send Test Notification\n/,
	'row test uses a singular progress title');
is(scalar(() = $html =~ /data-first-print/g), 1,
	'row test attempts only its own destination');
# Both inline switches share the API token and permission checks.
for my $kind (qw(target rule)) {
	# Switching state must enforce the same
	# grants as editing the full record.
	for my $permission (\$host, \$manage, \$readonly) {
		$$permission = !$$permission;
		eval { call_notification_api('set_notification_'.$kind.'_enabled', {
			object => $targets[0], enabled => 0, token => 'fixture-token' }) };
		like($@, qr/Denied|read-only/, "$kind switch enforces permissions");
		$$permission = !$$permission;
		}
	eval { call_notification_api('set_notification_'.$kind.'_enabled', {
		object => $targets[0], enabled => 0, token => 'bad' }) };
	like($@, qr/Invalid token/, "$kind switch rejects an unsigned request");
	}
# A valid rule switch reaches the real store and writes an audit entry.
my $switch_rule = $store->save_rule({ name => 'Switch', metric => 'memory',
	targets => [ $targets[0] ] }, time())->{id};
call_notification_api('set_notification_rule_enabled', {
	object => $switch_rule, enabled => 0, token => 'fixture-token' });
ok(!$store->configuration()->{rules}[0]{enabled}, 'authorized rule switch saves');
is($audit[-1], 'set_notification_rule_enabled', 'rule switch is audited');

# Check batch limits before any work starts.
subtest 'Bulk actions accept at most 100 unique destinations' => sub {
	local $module_var_directory = tempdir(CLEANUP => 1);
	my $store = get_notifications();
	my @ids = map {
		$store->save_target({ name => "Batch $_", type => 'email',
			address => "ops$_\@example.invalid" })->{id}
		} 1..101;
	my $sent = scalar(@sent);
	my $audited = scalar(@audit);
	# Oversized requests must stop before confirmation or any side effects.
	for my $action ({ send => 1 }, { delete => 1 },
			{ delete => 1, confirm => 1 }) {
		eval { render({ kind => 'target', object => join(',', @ids),
			%$action }) };
		like($@, qr/Select at most 100 items/, '101 items are rejected');
		}
	is(scalar(@sent), $sent, 'oversized selection sends nothing');
	is(scalar(@audit), $audited, 'oversized selection changes nothing');
	is(scalar(@{$store->configuration()->{targets}}), 101,
		'oversized selection preserves all destinations');
	# Repeating an ID does not use another place in the batch.
	my $selection = { kind => 'target', delete => 1,
		object => join(',', @ids[0..99], $ids[0]) };
	my $html = render({ kind => 'target', send => 1,
		object => $selection->{object} });
	is_deeply([ @sent[$sent..$#sent] ], [ @ids[0..99] ],
		'100 unique destinations each receive one test');
	$html = render($selection);
	unlike($html, qr/PROGRESS/, '100 deletions still need confirmation');
	is(scalar(@{$store->configuration()->{targets}}), 101,
		'confirmation leaves every destination intact');
	# A missing record within the limit must reject the whole request first.
	eval { render({ %$selection, confirm => 1,
		object => join(',', @ids[0..98], 'f' x 32) }) };
	like($@, qr/Notification not found/, 'every selected record is validated');
	is(scalar(@{$store->configuration()->{targets}}), 101,
		'invalid selection deletes nothing');
	$html = render({ %$selection, confirm => 1 });
	is(scalar(() = $html =~ /data-first-print/g), 100,
		'confirmed selection processes each unique destination once');
	is_deeply([ map { $_->{id} } @{$store->configuration()->{targets}} ],
		[ $ids[100] ], 'unselected destination remains');
	};

# Check text through form saves and API reads.
subtest 'Unicode form and API round trips' => sub {
	local $module_var_directory = tempdir(CLEANUP => 1);
	my $store = get_notifications();
	my $name = 'Größe М Ã© 😀 <ops>';
	my $bytes = Encode::encode('UTF-8', $name);
	my $html = render({ action => 'save_notification_rule', name => $bytes,
		delivery => 'email', target_name => $bytes, enabled => 0,
		email_address => 'sink@example.invalid', metric => 'filesystem',
		device => Encode::encode('UTF-8', '/Größe') },
		'POST', 'notification_save.cgi');
	like($html, qr/REDIRECT/, 'form save completes');
	# The API returns the decoded name, device and inline destination.
	my $cfg = call_notification_api('notification_config', { });
	is($cfg->{rules}[0]{name}, $name, 'form rule is decoded in the API');
	is($cfg->{rules}[0]{device}, '/Größe', 'form mount path is decoded');
	is($cfg->{targets}[0]{name}, $name, 'inline destination is decoded');
	# Pages encode the saved name again and escape it.
	my $id = $cfg->{targets}[0]{id};
	$html = render({ kind => 'target', object => $id, delete => 1 });
	my $escaped = html_escape($bytes);
	like($html, qr/\Q$escaped\E/,
		'confirmation encodes and escapes the saved name');
	# Editing the same name repeatedly must not add another encoding layer.
	for (1..2) {
		render({ action => 'save_notification_target', object => $id,
			name => $bytes, type => 'email', enabled => 0,
			email_address => 'sink@example.invalid' },
			'POST', 'notification_save.cgi');
		is($store->target($id)->{name}, $name, 'standalone edit preserves text');
		}
	# Reject invalid UTF-8 without changing the saved record.
	eval { render({ action => 'save_notification_target', object => $id,
		name => "bad\xff", type => 'email' },
		'POST', 'notification_save.cgi') };
	like($@, qr/Invalid UTF-8/, 'malformed form bytes are rejected');
	is($store->target($id)->{name}, $name, 'rejection preserves the name');
	};

# Both forms must map dedicated push fields without accepting hidden inputs.
subtest 'Save standalone and inline push destinations' => sub {
	local $module_var_directory = tempdir(CLEANUP => 1);
	my $store = get_notifications();
	for my $type (qw(pushover gotify)) {
		my $address = $type eq 'pushover' ? 'u' x 30
			: 'https://push.example.invalid/gotify';
		my $field = $type eq 'pushover'
			? 'pushover_user' : 'gotify_url';
		my %fields = ( $field => $address, $type.'_token' => 'a' x 30,
			webhook_url => 'https://wrong.invalid',
			secret => 'wrong' );
		my $html = render({ action => 'save_notification_target',
			name => $type, type => $type, enabled => 0, %fields },
			'POST', 'notification_save.cgi');
		like($html, qr/REDIRECT/, "$type standalone save completes");
		my ($saved) = grep { $_->{name} eq $type }
			@{$store->configuration()->{targets}};
		my $target = $store->target($saved->{id});
		is($target->{address}, $address, 'selected address wins');
		is($target->{secret}, 'a' x 30,
			'selected application token wins');
		# Editing uses the same fields and preserves the original ID.
		render({ action => 'save_notification_target',
			object => $saved->{id},
			name => $type, type => $type, %fields,
			$type.'_token' => 'b' x 30 },
			'POST', 'notification_save.cgi');
		is($store->target($saved->{id})->{secret}, 'b' x 30,
			'application token can be replaced');
		$html = render({ action => 'save_notification_rule',
			name => $type,
			delivery => $type, target_name => $type.' inline',
			metric => 'cpu', scope_mode => 'host',
			enabled => 0, %fields },
			'POST', 'notification_save.cgi');
		like($html, qr/REDIRECT/, "$type inline save completes");
		my ($rule) = grep { $_->{name} eq $type }
			@{$store->configuration()->{rules}};
		$target = $store->target($rule->{targets}[0]);
		is($target->{address}, $address, 'inline address is mapped');
		is($target->{secret}, 'a' x 30,
			'inline application token is mapped');
		# Early form errors must not dump provider credentials.
		local *main::error = sub {
			ok(!exists($in{pushover_user}) &&
				!exists($in{$type.'_token'}),
				'error form omits credentials');
			die $_[0];
			};
		eval { render({ action => 'save_notification_rule',
			delivery => 'invalid', %fields },
			'POST', 'notification_save.cgi') };
		like($@, qr/Invalid notification/, 'invalid form is rejected');
		}
	};

# Both mute scopes use the same signed POST handler and return to their page.
$host = $manage = 1;
$readonly = 0;
my $vm = '11111111-1111-4111-8111-111111111111';
for my $scope ($vm, 'all') {
	for my $action (qw(mute_notifications unmute_notifications)) {
		my %form = ( action => $action, token => 'fixture-token', id => $scope );
		my $output = eval { render(\%form, 'GET', 'notification_save.cgi') };
		like($@, qr/Use POST/, "$action rejects GET");
		$output = eval { render(\%form, 'POST', 'notification_save.cgi') };
		is($@, '', "$action accepts signed POST");
		my $return = 'notifications.cgi'.($scope eq 'all' ? '' : '?id='.urlize($scope));
		like($output, qr/REDIRECT: \Q$return\E\n/,
			"$action returns to the selected scope");
		}
	}
done_testing();
