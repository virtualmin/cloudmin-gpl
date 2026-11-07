use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use Test::More;
use File::Temp qw(tempdir);
use WebminCore;
our ($module_root_directory, $module_var_directory, $module_config_directory, $root_directory,
	$cloudmin_statistics_runtime, %config, %text, %access);
# Keep module state, cache and history inside the isolated fixture directory.
$module_root_directory = "$Bin/..";
$root_directory = $CloudminTest::webmin_root;
$module_var_directory = tempdir(CLEANUP => 1);
$module_config_directory = $module_var_directory;
$cloudmin_statistics_runtime = $module_var_directory;
require "$module_root_directory/cloudmin-config-lib.pl";
require "$module_root_directory/cloudmin-statistics-lib.pl";
open(my $lang, '<', "$module_root_directory/lang/en") or die $!;
while (<$lang>) {
	chomp;
	$text{$1} = $2 if /^([^=]+)=(.*)$/;
	}
close($lang);
# Seed a host and two guests to detect cross-owner leaks through either source.
my $host = Cloudmin::Statistics::host_id($module_config_directory);
my $vm = '11111111-1111-4111-8111-111111111111';
my $other = '22222222-2222-4222-8222-222222222222';
my $now = time();
my $store = Cloudmin::Statistics->new(directory => $module_var_directory, host_id => $host, write => 1);
for my $id ($host, $vm, $other) {
	$store->record([{entity => $id, owner => $id, kind => $id eq $host ? 'host' : 'vm', label => $id,
		start => $now - 10, end => $now, values => {cpu => 42}}], [], $now);
	}
# The live cache deliberately contains a private value from the foreign guest.
Cloudmin::Statistics::atomic_write("$module_var_directory/statistics-latest.json", convert_to_json({version => 1,
	host_id => $host, checked_at => $now, interval => 10, vms => {$vm => {resources => {cpu_percent => 42}}, $other => {secret => 'hidden'}}, host => {values => {cpu => 5}}}, 0, 1));
my @authorized;
{
	no warnings qw(redefine once);
	# require_access(kind,id) records the scope and denies host/foreign VM reads.
	local *main::require_access = sub {
		push @authorized, [@_];
		die "Permission denied\n" unless $_[0] eq 'view' && $_[1] eq $vm;
		};
	my $result = call_statistics_api('statistics', {id => $vm, from => $now - 3600, to => $now});
	is_deeply($authorized[-1], ['view', $vm], 'exact VM checked before query');
	is($result->{live}->{resources}->{cpu_percent}, 42, 'authorized latest values returned');
	unlike(convert_to_json($result), qr/$other|hidden/, 'other VM and latest cache data excluded');
	is_deeply(call_statistics_api('statistics', {id => $vm, entity => $other})->{series}, [], 'device selector cannot escape scope');
	# An omitted ID means host access and must not bypass the guest-only grant.
	for my $input ({id => $other}, {id => 'host'}, {}) {
		eval { call_statistics_api('statistics', $input) };
		like($@, qr/Permission denied/, 'unauthorized scope rejected');
		}
	# Export remains host-only even when its input names an allowed guest.
	eval { call_statistics_api('statistics_export', {id => $vm}) };
	like($@, qr/Permission denied/, 'VM ID cannot bypass export host permission');
	# Broken history must not be opened at all for a forbidden request.
	local *Cloudmin::Statistics::new = sub { die "Database was opened\n" };
	eval { call_statistics_api('statistics', {id => $other}) };
	like($@, qr/Permission denied/, 'ACL precedes database access');
	}
{
	no warnings qw(redefine once);
	# An authorized host reader still cannot bypass query validation.
	local *main::require_access = sub { push @authorized, [@_] };
	my $result = call_statistics_api('statistics', {id => 'host'});
	is($result->{entity}, $host, 'host query uses persisted identity');
	eval { call_statistics_api('statistics', {points => 99999}) };
	like($@, qr/points/, 'API enforces point limit');
	eval { call_statistics_api('statistics', {from => []}) };
	like($@, qr/from/, 'API rejects structured timestamps');
	eval { call_statistics_api('statistics_export', {cursor => []}) };
	like($@, qr/cursor/, 'API rejects structured cursor');
	# Disabling history changes recording status without hiding current
	# readings.
	local $config{statistics_recording} = 0;
	$result = call_statistics_api('statistics', {id => $vm});
	is($result->{recording}, 0, 'recording can be disabled');
	is($result->{live}->{resources}->{cpu_percent}, 42, 'recording off retains live values');
	}

# Saved history remains readable while collection and current values are off.
{
	no warnings qw(redefine once);
	# require_access(grant, [id]) allows this collection-state check.
	local *main::require_access = sub { };
	local $config{statistics_enabled} = 0;
	local $config{statistics_recording} = 1;
	my $result = call_statistics_api('statistics', {id => $vm});
	is($result->{collector}->{enabled}, 0, 'API identifies disabled collection');
	is($result->{collector}->{available}, 0, 'disabled collection is not live');
	ok(!$result->{live}, 'disabled collection does not expose an old live cache');
	is($result->{recording}, 0, 'disabled collection does not claim to record');
	ok($result->{history_available} && @{$result->{series}}, 'disabling preserves stored history');
	}

# Real UI helpers emit valid containers without private values in HTML.
my $html = show_statistics($vm);
like($html, qr/class="[^"]*\bcloudmin-statistics\b/, 'chart panel rendered');
like($html, qr/class="[^"]*\bui_page\b/, 'page uses the shared widget tokens');
like($html, qr/statistics\.js/, 'Cloudmin helper included');
like($html, qr/class="[^"]*\bui_segmented\b[^"]*"[^>]*>.*?name="statistics_range"/s, 'period segments use the shared control');
# Custom ranges retain native date and time inputs for theme-independent use.
like($html, qr/<input\b(?=[^>]*name="statistics_range")(?=[^>]*value="custom")/, 'custom period available');
like($html, qr/<input\b(?=[^>]*name="statistics_from_date")(?=[^>]*type=["']date["'])/, 'custom range start has a date field');
like($html, qr/<input\b(?=[^>]*name="statistics_to_time")(?=[^>]*type=["']time["'])(?=[^>]*step=["']900["'])/,
	'custom range end has a quarter-hour time field');
like($html, qr/statistics_device/, 'device chooser present');
like($html, qr/data-chart="(?:cpu|memory|disk|network)"/, 'chart slots rendered');
like($html, qr/cloudmin-statistics-filesystems/, 'guest page lists filesystems');
unlike($html, qr/statistics-latest\.json|metrics\.sqlite/, 'private cache and paths absent from markup');
# Host pools and guest filesystems belong to their respective pages only.
my $host_html = show_statistics('host');
like($host_html, qr/cloudmin-statistics-host/, 'host layout marked');
like($host_html, qr/cloudmin-statistics-pools/, 'host page lists storage pools in place of guest filesystems');
unlike($html, qr/cloudmin-statistics-pools/, 'guest page has no storage pool card');

# The collector publishes fractional seconds. Flooring the reader's clock would
# briefly mark every new sample as future data during its first second.
{
	no warnings qw(redefine once);
	local *Time::HiRes::time = sub { 1000.75 };
	Cloudmin::Statistics::atomic_write("$module_var_directory/statistics-latest.json", convert_to_json({
		version => 1, checked_at => 1000.5, interval => 10, vms => {}, host => {}}, 0, 1));
	ok(!statistics_latest()->{stale}, 'fresh fractional timestamp is not classified as future data');
	}

# Service output is tested as text without touching workstation services.
{
	no warnings qw(redefine once);
	# get_system_hostname() keeps template defaults from querying this host.
	local *WebminCore::get_system_hostname = sub { 'host.example.test' };
	my $unit = statistics_unit('/etc/web min', '/var/webmin', '/usr/share/webmin', '/usr/share/webmin/server-manager', '/usr/bin/perl');
	like($unit, qr/WatchdogSec=90/, 'native hangs have a service watchdog');
	like($unit, qr/Environment="WEBMIN_CONFIG=\/etc\/web min"/, 'paths are quoted');
	like($unit, qr/KillMode=control-group/, 'stopping collector also stops guest workers');
	like($unit, qr/^RuntimeDirectoryMode=0700$/m, 'live cache stays private');
	like($unit, qr/^UMask=0077$/m, 'collector files stay private');
	unlike($unit, qr/\$\{[A-Z_]+\}/, 'all service placeholders are filled');
	# Literal systemd specifiers and quotes must survive path substitution.
	my $quoted = statistics_unit('/etc/web%min', '/var/web"min', '/usr/share/webmin', '/srv/cloud%min', '/usr/bin/perl');
	like($quoted, qr/Environment="WEBMIN_CONFIG=\/etc\/web%%min"/, 'environment paths escape systemd specifiers');
	like($quoted, qr/Environment="WEBMIN_VAR=\/var\/web\\"min"/, 'environment paths escape quotes');
	like($quoted, qr{ExecStart="/usr/bin/perl" "/srv/cloud%%min/statistics-collector\.pl"},
		'command paths escape systemd specifiers');
	# A path must not inject another service directive.
	eval { statistics_unit("/etc/a\nExecStart=bad", 'a', 'b', 'c', 'd') };
	like($@, qr/Invalid service path/, 'service path cannot inject directives');
	}
done_testing();
