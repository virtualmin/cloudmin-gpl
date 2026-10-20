use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib", "$Bin/../lib";
use CloudminTest;
use Test::More;
use WebminCore;
use Cloudmin::Jobs;
# Match the page builders' path so Perl loads the shared module only once.
BEGIN { require "$Bin/../lib/Cloudmin/Libvirt.pm"; }
our (%text, %in, $root_directory);
$root_directory = $CloudminTest::webmin_root;
open(my $lang, '<', "$Bin/../lang/en") or die $!;
while (<$lang>) { chomp; $text{$1} = $2 if (/^([^=]+)=(.*)$/); }
{
	no warnings 'redefine';
	local *WebminCore::init_config = sub { };
	require "$Bin/../log_parser.pl";
	}
require "$Bin/../cloudmin-pages.pl";

# Check each action emitted by the VM service, including old connection entries.
my %vm = (create => 'Queued creation of', complete => 'Created',
	failed => 'Failed to create',
	clone => 'Submitted cloning for', clone_complete => 'Cloned',
	clone_failed => 'Failed to clone', clone_cancelled => 'Cancelled cloning',
	software_complete => 'Completed software setup for',
	software_failed => 'Failed software setup for',
	software_cancelled => 'Cancelled software setup for',
	cancelled => 'Cancelled creation of', start => 'Started',
	shutdown => 'Requested shutdown of',
	reboot => 'Requested reboot of',
	force_off => 'Forced power off for',
	console => 'Opened graphical console for',
	terminal => 'Opened SSH terminal for');
foreach my $action (sort keys %vm) {
	is(parse_webmin_log('root', '', $action, 'vm', 'uuid',
		{ name => 'guest<one>' }),
		"$vm{$action} virtual machine <tt>guest&lt;one&gt;</tt>",
		"$action has a readable escaped description");
	}
foreach my $enabled (0, 1) {
	like(parse_webmin_log('root', '', 'autostart', 'vm', 'uuid',
		{name => 'guest', enabled => $enabled}),
		$enabled ? qr/^Enabled start at boot/
		: qr/^Disabled start at boot/,
		'boot policy records the desired value');
	}
like(parse_webmin_log('root', '', 'console', 'vm', 'old-uuid', {}),
	qr/<tt>old-uuid<\/tt>/,
	'old entries do not require a live guest lookup');

# Storage logs retain names and distinguish enabling boot from disabling it.
for my $action (qw(create start stop)) {
	like(parse_webmin_log('root', '', $action, 'pool', 'uuid', {name => 'extra<one>'}),
		qr/storage pool <tt>extra&lt;one&gt;<\/tt>/, 'pool action retains escaped display name');
	}
foreach my $enabled (0, 1) {
	like(parse_webmin_log('root', '', 'autostart', 'pool', 'uuid', {name => 'extra', enabled => $enabled}),
		$enabled ? qr/^Enabled start at boot for storage pool/ : qr/^Disabled start at boot for storage pool/,
		'pool boot policy records target value');
	}

# Image outcomes distinguish completion, failures and cancellation.
is(parse_webmin_log('root', '', 'delete', 'volume', '/old/path', {name => 'disk<one>'}),
	'Deleted storage volume <tt>disk&lt;one&gt;</tt>', 'volume deletion has a readable escaped audit record');
# Compact audit summaries share UI labels; expanded
# details retain the exact file.
my $generated_volume = 'cloudmin-alma10-system-'.('a'x32).'.qcow2';
like(parse_webmin_log('root', '', 'delete', 'volume', '/pool/'.$generated_volume,
	{name => $generated_volume}), qr/Deleted storage volume <tt>alma10 - System disk \([a-f0-9]{8}\)<\/tt>/,
	'volume audit summaries use the same friendly name as storage');
like(parse_webmin_log('root', '', 'delete', 'volume', '/pool/'.$generated_volume,
	{name => $generated_volume}, 1), qr{\Q/pool/$generated_volume\E},
	'expanded audit details retain the exact deleted file');

for my $case (
	['create', 'queued', '', 'Queued import of'],
	['upload', 'queued', '', 'Uploaded'],
	['import', 'ready', '', 'Imported'],
	['delete', 'deleted', '', 'Deleted'],
	['upload', 'failed', 'error', 'Failed to upload'],
	['import', 'failed', 'error', 'Failed to import'],
	['delete', 'ready', 'in use', 'Failed to delete'],
	['import', 'deleted', 'cancelled', 'Cancelled import of'],
	['upload', 'deleted', '', 'Cancelled upload of'],
) {
	like(parse_webmin_log('root', '', $case->[0], 'image', 'job',
		{name => 'AlmaLinux 10', state => $case->[1],
		 error => $case->[2]}), qr/^\Q$case->[3]\E /,
		'image action describes its actual outcome');
	}
my $long = parse_webmin_log('root', '', 'import', 'image', '<job>',
	{name => 'image', state => 'failed', error => '<script>bad</script>'},
	1);
like($long,
	qr/Reference: <tt>&lt;job&gt;<\/tt>.*Error: &lt;script&gt;bad&lt;\/script&gt;/,
	'action details escape both identifiers and errors');
for my $action (qw(create modify enable disable delete)) {
	my $description = parse_webmin_log('root', '', $action, 'catalogue',
		'old:key',
		{names => "First <image> (ARM64)\0Second (x86-64)"});
	like($description,
		qr/<tt>First &lt;image&gt; \(ARM64\)<\/tt>, <tt>Second \(x86-64\)<\/tt>/,
		'catalogue action retains escaped display names');
	}
is(parse_webmin_log('', '', '<new>', 'other', '<object>', {}),
	'&lt;new&gt; other &lt;object&gt;',
	'unknown actions retain a safe fallback');

ok(!defined(parse_webmin_log('', '', '_config_', '-', '-', {})),
	"module configuration retains Webmin's standard description");

# Audit arguments contain identity and outcome, never provisioning credentials.
my @audit;
my $store = bless {log => sub { @audit = @_ }}, 'Cloudmin::Jobs';
$store->audit('complete', {id => 'job', owner => 'alice', state => 'complete',
	request => {name => 'guest', uuid => 'uuid', password_hash => 'secret',
	ssh_keys => 'private'}, resources => {key => 'secret'}});
is_deeply($audit[3],
	{name => 'guest', uuid => 'uuid', owner => 'alice',
	 state => 'complete'},
	'creation log retains only identity and outcome');

# Libvirt details use Webmin's native command queue and its logging setting.
{
	no warnings 'once';
	local %WebminCore::gconfig = (logfiles => 1);
	local @main::locked_file_diff;
	Cloudmin::Libvirt::log_call('Sys::Virt::Domain::shutdown',
		{ uuid => 'fixture-uuid' });
	is(scalar(@main::locked_file_diff), 1, 'API call enters Webmin additional log');
	is($main::locked_file_diff[0]->{'type'}, 'exec', 'uses supported command record');
	like($main::locked_file_diff[0]->{'data'},
		qr/libvirt API: Sys::Virt::Domain::shutdown\n.*fixture-uuid/s,
		'command details identify the actual API and guest');
	$WebminCore::gconfig{'logfiles'} = 0;
	Cloudmin::Libvirt::log_call('Sys::Virt::Domain::create', { uuid => 'other' });
	is(scalar(@main::locked_file_diff), 1, 'disabled Webmin detail logging is respected');
	}

# The real lifecycle adapter records calls without substituting shell commands.
{
	package AuditDomain;
	# create/shutdown/reboot/set_autostart model successful libvirt operations.
	# create(self, [flags]) models a successful start for audit capture.
	sub create { return 1; }
	# shutdown(self, [flags]) models an accepted shutdown request.
	sub shutdown { return 1; }
	# reboot(self, [flags]) models an accepted reboot request.
	sub reboot { return 1; }
	# set_autostart(self, enabled) models a saved boot-policy change.
	sub set_autostart { return 1; }
	}
{
	no warnings 'redefine';
	my @details;
	local *Cloudmin::Libvirt::additional_log = sub { push(@details, [@_]); };
	local *Cloudmin::Libvirt::find_domain = sub { bless {}, 'AuditDomain' };
	my $adapter = Cloudmin::Libvirt->new();
	$adapter->start_domain('uuid');
	$adapter->shutdown_domain('uuid');
	$adapter->reboot_domain('uuid');
	$adapter->set_domain_autostart('uuid', 1);
	is(scalar(@details), 4, 'each lifecycle call supplies operation details');
	for my $method (qw(create shutdown reboot set_autostart)) {
		my $entry = shift(@details);
		like($entry->[2], qr/\Alibvirt API: Sys::Virt::Domain::\Q$method\E\n/,
			"$method records its actual binding method");
		unlike($entry->[2], qr/virsh|token|password/, 'details omit shell surrogates and credentials');
		}
	}

# Menu links reuse Webmin search and do not grant access to its module.
my $vm = {uuid => 'uuid', name => 'guest & <one>', state => 'running'};
my @menu = get_menu_items([$vm], 'uuid', 0, 1, 1);
my @logs = grep { ($_->{'link'} || '') =~ m{^/webminlog/} } @menu;
is(scalar(@logs), 2, 'menu has guest and host action logs');
like($logs[0]->{'link'}, qr/mall=0&module=server-manager/,
	'search is restricted to Cloudmin');
like($logs[0]->{'link'}, qr/nmod=server-manager/,
	'external log page retains Cloudmin navigation');
like($logs[0]->{'link'}, qr/desc=guest%20%26%20%3cone%3e/i,
	'guest description filter is URL encoded');
like($logs[0]->{'link'},
	qr/search_sub_title=guest%20%26amp%3b%20%26lt%3bone%26gt%3b/i,
	'custom subtitle is HTML escaped before URL encoding');
unlike($logs[1]->{'link'}, qr/[?&]desc=/,
	'global log includes all Cloudmin actions');
@menu = get_menu_items([$vm], 'uuid', 0, 1, 0);
ok(!grep({ ($_->{'link'} || '') =~ m{^/webminlog/} } @menu),
	'no log links without module access');

# The shared empty state retains a compact link to completed action history.
my $empty_jobs = show_jobs_status({ jobs => [], log_url => get_action_log_url() });
like($empty_jobs, qr/\bui_empty\b/, 'idle jobs use the shared empty state');
like($empty_jobs, qr/webminlog\/search\.cgi/, 'idle jobs link to completed action history');
like($empty_jobs, qr/\bui_action_small\b/, 'the history link uses a compact button');
done_testing();
