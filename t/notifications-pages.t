use strict;
use warnings;
use Encode ();
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use Test::More;
use WebminCore;
use File::Temp qw(tempdir);
no warnings qw(redefine once);
our (%text, %config, $module_root_directory, $module_var_directory,
     $remote_user);
# Load the page helpers with a private data directory.
$module_root_directory = "$Bin/..";
$module_var_directory = tempdir(CLEANUP => 1);
$remote_user = 'root';
require "$module_root_directory/cloudmin-config-lib.pl";
require "$module_root_directory/cloudmin-notifications-lib.pl";
require "$module_root_directory/cloudmin-notification-pages.pl";
# Load Webmin and module English strings for labels in rendered pages.
for my $path ("$CloudminTest::webmin_root/lang/en",
	      "$module_root_directory/lang/en") {
	open(my $lang, '<', $path) or die $!;
	while (<$lang>) { chomp; $text{$1} = $2 if /^([^=]+)=(.*)$/; }
	close($lang);
	}

# require_access(grant, [id]) permits rendering without a live user session.
sub require_access { }
# can_access(grant) allows management controls in the default fixture.
sub can_access { return 1; }
# is_readonly_mode() permits writes until a test overrides it.
sub is_readonly_mode { return 0; }
# get_api_machines(input) supplies an empty inventory without libvirt.
sub get_api_machines { return [ ]; }
# get_image_jobs() returns a token provider without opening job storage.
sub get_image_jobs { return bless { }, 'PageToken'; }
# PageToken::form_token(self, user) supplies a predictable signed-form value.
sub PageToken::form_token { return 'fixture-token'; }
# Empty inventories need useful setup links without duplicate headings.
my $store = get_notifications();
my $empty = show_notifications('history');
like($empty, qr/ui_empty/, 'empty inventory uses shared empty states');
unlike($empty, qr/ui_columns_heads/, 'empty inventory has no table headings');
# An empty history offers no setup actions. An empty rule list links to
# the rule editor.
my $history_empty = show_notification_history(
	{ events => [ ], states => [ ] }, { }, 'fixture-token', 0);
unlike($history_empty, qr/notification_(?:form|save).cgi/,
	'empty history does not duplicate setup actions');
my $rules_empty = show_notification_list('rule',
	{ rules => [ ], targets => [ ] }, 'fixture-token', { });
like($rules_empty, qr/notification_form.cgi\?kind=rule/,
	'empty rules open the rule editor directly');
unlike($rules_empty, qr/notifications.cgi\?tab=targets/,
	'rule creation has no prerequisite destination page');
unlike(show_notification_list('rule',
	{ rules => [ ], targets => [ ] }, '', { }), qr/ui_action/,
	'read-only rules do not offer setup actions');
# First-rule setup includes its destination directly.
my $rule_form = show_notification_form('rule');
like($rule_form, qr/save_notification_rule/,
	'first rule opens its actual form');
like($rule_form, qr/name="metric"/, 'first rule has a condition selector');
like($rule_form, qr/name="target_name"/, 'first rule names its destination');
like($rule_form, qr/name="email_address"/, 'first rule accepts an email');
unlike($rule_form, qr/value="saved"/, 'no empty saved-destination choice');
unlike($rule_form, qr/name="clear_secret"/,
	'new destinations have no saved token to remove');
# Lists escape stored markup and omit saved credentials.
my $saved_secret = q{private-token"<>&'};
my $id = $store->save_target({ name => '<script>bad</script>',
	type => 'webhook', address => 'https://example.invalid/hook',
	secret => $saved_secret })->{id};
like(show_notification_list('rule', $store->configuration(),
	'fixture-token', { }), qr/notification_form.cgi\?kind=rule/,
	'saved destinations keep the same direct rule action');
# Every tab must escape the saved name and link to separate editors.
my $rule = $store->save_rule({ name => 'Pressure', metric => 'cpu',
	scope => 'host', targets => [ $id ] }, time())->{id};
for my $tab (qw(history rules targets)) {
	my $html = show_notifications($tab);
	like($html, qr/name="notification_tabs"[^>]*value="notifications_$tab"/,
		"$tab is selected in the native tab widget");
	unlike($html, qr/<script>bad|private-token/,
		"$tab escapes names and omits secrets");
	unlike($html, qr/value="save_notification_(?:target|rule)"/,
		"$tab has no embedded create or edit form");
	like($html, qr/notification_form.cgi\?kind=target&object=$id/,
		"$tab links to a separate editor");
	like($html, qr/notification_action_progressive.cgi/,
		"$tab submits row actions to their progress handler");
	}
{
	# get_api_machines(input) models an inventory failure
	# during history rendering.
	local *main::get_api_machines = sub { die "Libvirt unavailable\n" };
	like(show_notifications('history'), qr/notification-history/,
		'history remains readable when inventory is unavailable');
	}
# The missed-check warning allows three check intervals, or three minutes.
for my $case ([ 300, 400, 0 ], [ 300, 1000, 1 ], [ 60, 400, 1 ],
	      [ 10, 100, 0 ]) {
	my ($interval, $age, $warns) = @$case;
	local $config{notifications_interval} = $interval;
	$store->metadata('worker',
		{ checked_at => time() - $age, error => '' });
	my $shown = show_notifications('history') =~ /have not run recently/;
	ok($warns ? $shown : !$shown,
		"$interval-second checks last run $age seconds ago ".
		($warns ? 'warn' : 'do not warn'));
	}
# Clear the fixture's worker status for the remaining page checks.
$store->metadata('worker', undef);
# Rules use the same per-record layout and signed actions as destinations.
my $list = show_notification_list('rule', $store->configuration(),
	'fixture-token', { host => 'Host' });
like($list, qr/notification-records notification-rules/, 'rules use aligned rows');
unlike($list, qr/ui_checked_columns|select_all|select_invert|ui_card/,
	'rules have no bulk selection or card wrappers');
like($list, qr/>1 rule</, 'rule count is shown');
like($list, qr/>Add rule</, 'rule creation uses the compact toolbar action');
like($list, qr/id="notification-rule-$rule"/, 'each rule has its own row');
# Signed forms isolate state changes from record deletion.
my @rule_forms = $list =~ m{(<form\b.*?</form>)}sg;
is(scalar(@rule_forms), 2, 'rule state and deletion have separate forms');
for my $form (@rule_forms) {
	like($form, qr/name="token"[^>]*value="fixture-token"/,
		'rule action carries its signed token');
	like($form, qr/name="object"[^>]*value="$rule"/,
		'rule action applies only to its own record');
	}
like($list, qr/set_notification_rule_enabled/, 'rule switch saves only state');
like($list, qr/ui_svg_icon_trash/, 'rule deletion has its icon');
# Destination rows expose usage and real delivery state with per-row actions.
my $disabled = $store->save_target({ name => 'Disabled email', type => 'email',
	address => 'disabled@example.invalid', enabled => 0 })->{id};
my $rows = show_notification_list('target', $store->configuration(),
	'fixture-token', { });
like($rows, qr/notification-destinations/, 'destinations use aligned rows');
unlike($rows, qr/ui_checked_columns|select_all|select_invert|ui_card/,
	'destination rows have no bulk selection or card wrappers');
like($rows, qr/Used by.*Last delivery/s, 'rows show usage and delivery headings');
like($rows, qr/notifications.cgi\?tab=rules&target=$id/, 'usage links filter rules');
like($rows, qr/>1 rule</, 'usage includes the referencing rule');
like($rows, qr/Not used yet/, 'unused destinations are clear');
like($rows, qr/No recent deliveries/, 'no receipts is distinct from a failure');
# Each destination carries only its own ID and token.
my @forms = $rows =~ m{(<form\b.*?</form>)}sg;
is(scalar(@forms), 4, 'each destination has separate state and action forms');
for my $target ($id, $disabled) {
	my @own = grep { /name="object"[^>]*value="$target"/ } @forms;
	my ($form) = grep { /notification_action_progressive.cgi/ } @own;
	my ($toggle) = grep { /notification_save.cgi/ } @own;
	# The action form carries the token, a test button and a delete button.
	like($form, qr/name="token"[^>]*value="fixture-token"/,
		'row carries its own signed token');
	unlike($form, qr/ui_dropdown/, 'row actions need no menu');
	like($form, qr/<button\b[^>]*name="send"/, 'row offers Send test directly');
	like($form, qr/<button\b[^>]*name="delete"/, 'row offers Delete directly');
	like($rows, qr/notification_form.cgi\?kind=target&object=$target/,
		'destination name links to the editor');
	like($toggle, qr/set_notification_target_enabled/,
		'switch submits only a state change');
	like($toggle, qr/ui_toggle_primary/, 'enabled uses the native blue toggle');
	is(scalar(() = $form =~ /name="object"/g), 1,
		'row acts on exactly one destination');
	if ($target eq $disabled) {
		# Disabled destinations cannot send a foreground test.
		like($form, qr/<button\b(?=[^>]*name="send")(?=[^>]*disabled)/,
			'disabled destination cannot send a test');
		}
	else {
		# Enabled destinations retain the same direct test action.
		unlike($form, qr/<button\b(?=[^>]*name="send")(?=[^>]*disabled)/,
			'enabled destination can send a test');
		}
	}
# Read-only lists keep information but omit every mutation form.
for my $kind (qw(rule target)) {
	my $readonly = show_notification_list($kind, $store->configuration(),
		'', { });
	unlike($readonly,
		qr/ui_checked_columns|notification_(?:save|action_progressive|form).cgi/,
		"$kind is read-only without a mutation token");
	}
like($rows, qr/https:\/\/example.invalid\/hook/,
	'row shows the destination address');
# Usage links filter Rules without exposing unescaped destination names.
my $filtered = show_notifications('rules', undef, $id);
like($filtered, qr/Rules using &lt;script&gt;bad&lt;\/script&gt;/,
	'usage filter identifies its destination safely');
like($filtered, qr/Show all rules/, 'filtered rules can return to all rules');
my $unused = show_notifications('rules', undef, $disabled);
unlike($unused, qr/id="notification-rule-[a-f0-9]{32}"/,
	'usage filter excludes unrelated rules');
# Delivery labels distinguish retries from successful attempts.
like(notification_delivery_status({ state => 'queued', error => '<bad>' }),
	qr/Failed, retry pending.*&lt;bad&gt;/s,
	'failed attempts awaiting retry show a safe error');
like(notification_delivery_status({ state => 'sent', at => 1700000000 }),
	qr/Accepted by destination/, 'server acceptance is distinct from waiting');
# DateTime-enabled themes wrap dates, but chips accept only plain labels.
for my $wrapped (0, 1) {
	# make_date(seconds) models both plain and theme-wrapped dates.
	local *main::make_date = sub {
		return $wrapped
			? "<span data-filesize-bytes='$_[0]'>11/11/2026 01:35</span>"
			: '11/11/2026 01:35';
		};
	for my $state (qw(sent failed queued)) {
		# Pending retries have an error from their previous attempt.
		my $status = notification_delivery_status({ state => $state,
			at => 1794357300, error => $state eq 'sent' ? '' : '<remote error>' });
		like($status, qr/ · 11\/11\/2026 01:35/,
			"$state keeps the date with wrapping=$wrapped");
		unlike($status, qr/&lt;span|data-filesize-bytes/,
			"$state omits date markup with wrapping=$wrapped");
		like($status, qr/&lt;remote error&gt;/,
			'plain dates do not disable delivery-error escaping')
			unless $state eq 'sent';
		}
	}
# The history card has no title because its tab already names it.
unlike($history_empty, qr/ui_card_title/,
	'history does not repeat its tab title');
# Authorized destination editors show safely escaped saved tokens.
my $html = show_notification_form('target', $id);
like($html, qr/&lt;script&gt;/, 'target editor escapes saved name');
my $escaped_secret = html_escape($saved_secret);
like($html, qr/<input[^>]*type='text'[^>]*name="secret"[^>]*value="\Q$escaped_secret\E"/,
	'saved token is visible and escaped in the destination editor');
unlike(show_notification_form('target'), qr/private-token/,
	'new destination editor does not load saved tokens');
# The editor is a standalone signed form without the list tabs.
like($html, qr/value="save_notification_target"/, 'target form saves targets');
like($html, qr/value="fixture-token"/, 'editor carries a signed token');
unlike($html, qr/notification_tabs/, 'editor has no inventory tabs');
like(show_notification_form('target'), qr/Create<\//,
	'new editor offers Create');
like(show_notification_form('rule', $rule), qr/<select[^>]*name="targets"[^>]*multiple/,
	'rule editor uses a native destination multiselect');
# Existing rules can reuse a saved target or create another inline.
my $edit = show_notification_form('rule', $rule);
unlike($edit, qr/private-token/, 'rule editor does not load destination tokens');
like($edit, qr/value="saved"[^>]*selected/,
	'existing rule uses saved destinations');
like($edit, qr/New email destination/, 'existing rule can add an email');
like($edit, qr/New webhook destination/, 'existing rule can add a webhook');
unlike($html, qr/name="clear_secret"/, 'saved webhook has no remove-token checkbox');
unlike(show_notification_form('target'), qr/name="clear_secret"/,
	'new destination has no remove-token option');
# Telegram tokens appear only in the authorized destination editor.
my $telegram_id = $store->save_target({ name => 'Telegram fixture',
	type => 'telegram', address => '-1001234567890',
	secret => '123456:fixture_Page-token' })->{id};
my $telegram_form = show_notification_form('target', $telegram_id);
like($telegram_form, qr/name="telegram_token"[^>]*value="123456:fixture_Page-token"/,
	'authorized editor shows the saved bot token');
like($telegram_form, qr/name="telegram_chat"[^>]*value="-1001234567890"/,
	'editor keeps the signed chat ID');
like($telegram_form, qr/name="secret"[^>]*value=""/,
	'generic bearer field does not inherit a bot token');
# The destination list and the rule editor never show the token.
unlike(show_notifications('targets'), qr/fixture_Page-token/,
	'destination list never contains the bot token');
like($rule_form, qr/New Telegram destination/, 'rule editor offers Telegram');
# Push editors expose credentials only after management access checks.
for my $type (qw(pushover gotify)) {
	my $address = $type eq 'pushover' ? 'u' x 30
		: 'https://push.example.invalid/gotify';
	my $id = $store->save_target({ name => $type, type => $type,
		address => $address, secret => 'a' x 30 })->{id};
	my $form = show_notification_form('target', $id);
	like($form, qr/name="${type}_token"[^>]*value="a{30}"/,
		"$type editor loads its application token");
	my $field = $type eq 'pushover' ? 'pushover_user' : 'gotify_url';
	like($form, qr/name="$field"[^>]*value="\Q$address\E"/,
		"$type editor loads its recipient or server");
	my $list = show_notification_destinations(
		$store->configuration(), 'token');
	unlike($list, qr/a{30}|u{30}/,
		'destination list hides push credentials');
	}

# Every editor help link must resolve to a topic with the same field title.
# Collect topics from both creation and editing, including conditional fields.
my %help;
for my $form ($rule_form, $edit, $html, show_notification_form('target')) {
	while ($form =~ m{<a\b[^>]*href="[^"]*/help\.cgi/[^/"\s]*/(notifications_\w+)"[^>]*>([^<]+)</a>}g) {
		my ($topic, $label) = ($1, $2);
		$help{$topic} = $label;
		}
	}
# These are all the field help topics the editors must link to.
my @topics = map { 'notifications_'.$_ } qw(
	name severity rule_enabled condition scope device threshold comparison duration
	send_to targets destination_name email_address webhook_url secret recovery
	telegram_chat telegram_token
	pushover_user pushover_token gotify_url gotify_token
	cooldown repeat target_enabled type);
is_deeply([ sort keys %help ], [ sort @topics ],
	'every rule and destination setting has field help');
# Each help file's header must equal its field label.
for my $topic (@topics) {
	my $path = "$module_root_directory/help/$topic.html";
	open(my $file, '<', $path) or die "Cannot read $path: $!";
	local $/;
	my $content = <$file>;
	close($file);
	my ($title) = $content =~ m{<header>(.*?)</header>};
	is($title, $help{$topic}, "$topic title matches its field label");
	unlike($title, qr/[()]/, "$topic title has no parenthetical hints");
	like($content, qr/<p>.+<\/p>\s*<footer>\s*\z/s,
		"$topic has complete help markup");
	}
{
	# require_access(grant) models a host viewer with no management grant.
	# Host viewers without management rights cannot read saved tokens.
	local *main::require_access = sub {
		die "Management access required\n" if $_[0] eq 'manage';
		};
	eval { show_notification_form('target', $id) };
	like($@, qr/Management access required/,
		'host viewers cannot open destination editors');
	}
# Invalid edit requests must fail rather than open a new record.
for my $kind (qw(target rule invalid)) {
	eval { show_notification_form($kind, 'a' x 32) };
	like($@, qr/Invalid notification form|Notification not found/,
		"$kind editor rejects unknown records or kinds");
	}
{
	# is_readonly_mode() hides mutation links and
	# rejects direct editor access.
	local *main::is_readonly_mode = sub { 1 };
	unlike(show_notifications('targets'),
		qr/notification_(?:save|form).cgi/,
		'read-only inventory has no mutation controls');
	eval { show_notification_form('target', $id) };
	like($@, qr/read-only/, 'read-only users cannot open the editor');
	}
{
	# Guest rendering must not load settings or host inventory.
	# require_access(grant, [id]) rejects any attempt to read host data.
	local *main::require_access = sub {
		die "Host data read\n" if $_[0] eq 'host';
		};
	# get_api_machines(input) fails if a guest view reads host inventory.
	local *main::get_api_machines = sub { die "Inventory read\n" };
	my $guest = show_notifications('history',
		'11111111-2222-3333-4444-555555555555');
	like($guest, qr/ui_empty/, 'guest page needs no host grants');
	unlike($guest, qr/notification_tabs|notification_form.cgi|Delivery/,
		'guest page has no host navigation or delivery column');
	eval { show_notification_form('target') };
	like($@, qr/Host data read/, 'guests cannot open target editors');
	}
# Populated history keeps retries with their event and escapes delivery errors.
my $data = { states => [ ], events => [ {
	id => 1, created => time(), name => '<b>Pressure</b>', label => 'Host',
	phase => 'firing', severity => 'warning', deliveries => [ {
		target => $id, state => 'failed',
		error => '<script>error</script>',
	} ],
} ] };
my $history = show_notification_history($data, $store->configuration(),
	'fixture-token', 0);
like($history, qr/value="retry_notification"/, 'failed delivery offers retry');
unlike($history, qr/<script>error|<b>Pressure/,
	'history escapes remote values');
# The guest view drops delivery details and retry controls.
$history = show_notification_history($data, { }, '', 1);
unlike($history, qr/Delivery|retry_notification|script&gt;error/,
	'guest history omits delivery details and retries');
# Paused checks show the cause, with a generic fallback when none is saved.
for my $case (
	[ planned_stop => 'Alerts paused for planned stop' ],
	[ planned_restart => 'Alerts paused during reboot grace period' ],
	[ active_job => 'Alerts paused while a guest job is in progress' ],
	[ unavailable => 'Waiting for fresh status data' ],
	[ undef, 'Alert checks paused' ],
) {
	# Render one paused condition with this case's reason.
	my $state = { status => 'paused', label => 'Guest', name => 'Stopped',
		rule => 'fixture' };
	$state->{pause_reason} = $case->[0] if defined($case->[0]);
	my $html = show_notification_history(
		{ states => [ $state ], events => [ ] }, { }, '', 1);
	like($html, qr/\Q$case->[1]\E/, 'paused check explains its cause');
	unlike($html, qr/Unknown or temporarily suppressed/,
		'paused check has no ambiguous status label');
	}

# The monitor shows selected names and retains guests missing from inventory.
{
	my $first = '11111111-1111-4111-8111-111111111111';
	my $second = '22222222-2222-4222-8222-222222222222';
	# get_api_machines(input) supplies one escaped name
	# and omits the other UUID.
	local *main::get_api_machines = sub {
		return [ { id => $first, name => '<guest-one>' } ];
		};
	my $multi = $store->save_rule({ name => 'Selected guests',
		metric => 'guest_down', scope => [ $first, $second ],
		targets => [ $id ] }, time())->{id};
	# The editor keeps both guests selected, including the missing one.
	my $form = show_notification_form('rule', $multi);
	like($form, qr/<select[^>]*name="scope"[^>]*multiple/,
		'monitor uses a native guest multiselect');
	like($form, qr/value="selected"[^>]*selected/,
		'selected guests mode reopens with the rule');
	like($form, qr/\Q$first\E[^>]*selected/,
		'known selected guest stays selected');
	like($form, qr/\Q$second\E[^>]*selected/,
		'missing selected guest stays selected');
	like($form, qr/&lt;guest-one&gt;/, 'guest labels are escaped');
	# The rule list shows names from the supplied scope labels.
	my $list = show_notification_list('rule', $store->configuration(), '',
		{ $first => '<guest-one>', $second => 'guest-two' });
	like($list, qr/&lt;guest-one&gt;, guest-two/,
		'rule list shows every selected guest name');
	# A scope holding one guest UUID must reopen as a one-guest selection.
	my $single = $store->save_rule({ name => 'Single guest',
		metric => 'guest_down', scope => $first,
		targets => [ $id ] }, time())->{id};
	like(show_notification_form('rule', $single),
		qr/value="selected"[^>]*selected/,
		'existing single-guest rules open as selected guests');
}
# Check escaping without changing stored text.
subtest 'Unicode in notification pages' => sub {
	use utf8;
	local $module_var_directory = tempdir(CLEANUP => 1);
	my $store = get_notifications();
	my $name = 'Größe М Ã© 😀 <ops>';
	my $target = $store->save_target({ name => $name, type => 'email',
		address => 'sink@example.invalid' })->{id};
	my $rule = $store->save_rule({ name => $name, metric => 'cpu',
		duration => 0, targets => [ $target ] }, 1000)->{id};
	$store->evaluate({ $rule => [ { owner => 'host', subject => 'host/',
		label => $name, value => 95, running => 1 } ] }, 1001, { });
	# Each page must hold the name as escaped UTF-8 bytes.
	my $escaped = html_escape(Encode::encode('UTF-8', $name));
	for my $html (show_notifications('history'),
		show_notification_form('target', $target),
		show_notification_form('rule', $rule)) {
		like($html, qr/\Q$escaped\E/, 'page contains escaped UTF-8 name');
		ok(!utf8::is_utf8($html), 'page stays byte HTML for Webmin');
		}
	is($store->target($target)->{name}, $name, 'rendering does not alter storage');
	};

done_testing();
