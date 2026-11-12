#!/usr/bin/perl
# check-notification-lifecycle.pl module-root fixture-dir webhook-port
# Uses one diskless guest and private rules. Existing guests remain untouched.
use strict;
use warnings;
no warnings 'once';
use Test::More;
use POSIX qw(uname);

# Run only as root from a shell, with a fixture directory under /tmp.
die "Run on an authorized Linux host as root\n"
	unless $^O eq 'linux' && $< == 0 && !$ENV{GATEWAY_INTERFACE};
my ($module, $directory, $port) = @ARGV;
die "Invalid fixture arguments\n" unless $module && -d $module &&
	$directory =~ m{\A/(?:var/)?tmp/cloudmin-notifications\.[A-Za-z0-9]+/lifecycle\z} &&
	$port =~ /^\d+$/;
# Load the installed module with a private notification store.
$ENV{WEBMIN_CONFIG} = '/etc/webmin';
$ENV{WEBMIN_VAR} = '/var/webmin';
$ENV{REMOTE_USER} = 'root';
chdir($module) or die $!;
$0 = "$module/api.pl";
require './server-manager-lib.pl';
require './cloudmin-statistics-lib.pl';
our ($cloudmin_notifications_directory, $error_must_die);
$error_must_die = 1;
$cloudmin_notifications_directory = $directory;
die "Enable statistics before running this fixture\n" unless statistics_enabled();
# The fixture guest has a unique name and alerts the loopback webhook.
my $name = 'cloudmin-notifications-'.substr(Cloudmin::Notifications::id(), 0, 12);
my $arch = (uname())[4];
die "This diskless fixture requires x86_64 or aarch64\n"
	unless $arch eq 'x86_64' || $arch eq 'aarch64';
my ($domain, $uuid);
my $store = get_notifications();
my $target = $store->save_target({ name => 'Lifecycle fixture', type => 'webhook',
	address => "http://127.0.0.1:$port/events" })->{id};

# sample(state, [agent]) waits up to 90 seconds for a fresh fixture reading.
# agent defaults to false; true also requires a completed availability probe. A
# matching reading runs one worker tick against the private notification store.
sub sample
{
my ($state, $agent) = @_;
my $deadline = time() + 90;
while (time() < $deadline) {
	my $snapshot = statistics_latest();
	my $live = $snapshot->{vms}->{$uuid} || { };
	if (!$snapshot->{stale} && ($live->{state} || '') eq $state &&
		($snapshot->{checked_at} || 0) > ($store->metadata('sample') || 0) &&
		(!$agent || defined($live->{agent_available}))) {
		# The collector must observe this state after the
		# last evaluated sample.
		run_cloudmin_notifications();
		die "Worker failed\n" if $store->metadata('worker')->{error};
		return;
		}
	sleep(1);
	}
die "Collector did not report fixture state $state\n";
}

# phases(rule) reads only this fixture's rule history.
sub phases
{
my ($rule) = @_;
return [ map { $_->{phase} } grep { $_->{rule} eq $rule }
	@{$store->history(undef, 0, 100)->{events}} ];
}

my $ok = eval {
	# No disks, network, autostart or guest agent. CPU use is capped at 10%.
	# ARM guests need native CPUs and UEFI, with enough memory for firmware.
	my $memory = $arch eq 'aarch64' ? 256 : 64;
	my $boot = $arch eq 'aarch64'
		? "<cpu mode='host-passthrough'/><os firmware='efi'>".
		  "<type arch='aarch64' machine='virt'>hvm</type></os>".
		  "<features><acpi/></features>"
		: "<os><type arch='x86_64'>hvm</type></os>";
	my $xml = "<domain type='kvm'><name>$name</name>".
		"<memory unit='MiB'>$memory</memory><vcpu>1</vcpu>".
		"<cputune><period>100000</period><quota>10000</quota></cputune>".
		$boot.
		"<devices><memballoon model='none'/></devices></domain>";
	# Define the guest without starting it, then read its UUID.
	$domain = get_libvirt(1)->connect()->define_domain($xml);
	$uuid = $domain->get_uuid_string();
	# Separate power and agent rules distinguish a running
	# guest without an agent.
	my $down = $store->save_rule({ name => 'Fixture power',
		metric => 'guest_down', scope => $uuid, duration => 0, cooldown => 0,
		targets => [ $target ] }, time())->{id};
	my $agent = $store->save_rule({ name => 'Fixture agent',
		metric => 'guest_agent', scope => $uuid, duration => 0,
		targets => [ $target ] }, time())->{id};
	$domain->create();
	sample('running', 1);
	is_deeply(phases($down), [ ], 'running fixture does not alert');
	is_deeply(phases($agent), [ 'firing' ],
		'real failed guest-agent probe alerts');
	# Exercise the signed Cloudmin power API,
	# including its suppression hook.
	call_vm_api(1, 'force_off', { id => $uuid, confirm => 1,
		token => get_image_jobs()->form_token('root') });
	sample('shutoff');
	is_deeply(phases($down), [ ], 'planned API power-off stays quiet');
	$domain->create();
	sample('running');
	# A direct libvirt stop is outside Cloudmin's planned operation path.
	$domain->destroy();
	sample('shutoff');
	is_deeply(phases($down), [ 'firing' ], 'unexpected stop sends an alert');
	# Restarting after an unplanned stop should produce one recovery.
	$domain->create();
	sample('running');
	is_deeply(phases($down), [ 'firing', 'resolved' ],
		'live restart sends one recovery');
	my $events = $store->history(undef, 0, 100)->{events};
	ok(!grep({ $_->{deliveries}->[0]->{state} ne 'sent' } @$events),
		'lifecycle events reach the loopback webhook');
	1;
	};
my $error = $@;
# Remove this fixture's guest and firmware variables even after a failed test.
if ($domain) {
	eval { $domain->destroy() if $domain->is_active() };
	$error .= "Cannot stop fixture guest $name: $@\n" if $@;
	# Attempt both cleanup steps and retain either failure
	# with the test error.
	eval { $domain->undefine($arch eq 'aarch64'
		? Sys::Virt::Domain::UNDEFINE_NVRAM() : 0) };
	$error .= "Cannot remove fixture guest $name: $@\n" if $@;
	}
die $error if !$ok || length($error);
done_testing();
