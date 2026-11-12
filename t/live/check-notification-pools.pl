#!/usr/bin/perl
# check-notification-pools.pl(module-root, task-directory) tests pool alerts
# against the running collector using temporary directory and missing-VG pools.
use strict;
use warnings;
no warnings 'once';
use Test::More;
use File::Path qw(make_path remove_tree);
use Time::HiRes ();

# Run only as root from a shell, with a fixture directory under /tmp.
die "Run on an authorized Linux host as root\n"
	unless $^O eq 'linux' && $< == 0 && !$ENV{GATEWAY_INTERFACE};
my ($module, $directory) = @ARGV;
die "Invalid fixture arguments\n" unless $module && -d $module &&
	$directory =~ m{\A/(?:var/)?tmp/cloudmin-notifications\.[A-Za-z0-9]+\z};
# Load the installed module. The collector must be running.
$ENV{WEBMIN_CONFIG} = '/etc/webmin';
$ENV{WEBMIN_VAR} = '/var/webmin';
$ENV{REMOTE_USER} = 'root';
chdir($module) or die $!;
$0 = "$module/api.pl";
require './server-manager-lib.pl';
require './cloudmin-statistics-lib.pl';
our ($error_must_die);
$error_must_die = 1;
die "Enable statistics before running this fixture\n" unless statistics_enabled();
# Use a private store and one rule that watches only the fixture pool.
my $name = 'notification-pool-'.substr(Cloudmin::Notifications::id(), 0, 12);
my $fixture = "$directory/$name";
make_path("$fixture/files");
my $store = Cloudmin::Notifications->new(directory => "$fixture/store");
my $target = $store->save_target({ name => 'Fixture only', type => 'email',
	address => 'sink@example.invalid' })->{id};
my $rule = $store->save_rule({ name => 'Fixture pool state',
	metric => 'pool_inactive', scope => 'host', device => $name,
	duration => 0, cooldown => 0, targets => [ $target ] }, time())->{id};
my ($pool, $missing_pool);

# sample(active, [pool_name]) waits up to 100 seconds for the pool's 0/1 state.
# pool_name defaults to the directory pool created by this test. Only the
# private store evaluates the snapshot; no messages are delivered.
sub sample
{
my ($active, $pool_name) = @_;
$pool_name ||= $name;
my $deadline = time() + 100;
while (time() < $deadline) {
	my $snapshot = statistics_latest();
	my ($found) = grep { $_->{name} eq $pool_name }
		@{$snapshot->{host}->{pool_states} || [ ]};
	if (!$snapshot->{stale} && $found && defined($found->{active}) &&
		$found->{active} == $active) {
		# A real inventory reading drives the
		# same signals as the worker.
		my $now = Time::HiRes::time();
		my $rules = $store->configuration()->{rules};
		$store->evaluate(Cloudmin::NotificationSignals::observations(
			$rules, $snapshot, $now, { }), $now, { });
		return $snapshot;
		}
	sleep(1);
	}
die "Collector did not report fixture pool state $active\n";
}

my $ok = eval {
	# Define an empty pool without touching any existing storage or volumes.
	$pool = get_libvirt(1)->connect()->define_storage_pool(
		"<pool type='dir'><name>$name</name><target>".
		"<path>$fixture/files</path></target></pool>");
	my $snapshot = sample(0);
	my $events = $store->history(undef, 0, 100)->{events};
	is_deeply([ map { $_->{phase} } @$events ], [ 'firing' ],
		'real inactive pool produces one alert');
	ok(!grep({ $_->{name} eq $name } @{$snapshot->{host}->{pools} || [ ]}),
		'inactive pool stays out of usage totals');

	# Starting this pool should produce a recovery on
	# its next inventory read.
	$pool->create();
	$snapshot = sample(1);
	$events = $store->history(undef, 0, 100)->{events};
	is_deeply([ map { $_->{phase} } @$events ], [ 'firing', 'resolved' ],
		'real pool activation produces one recovery');

	# Check that new host conditions use real
	# collector field names and units.
	my @metrics = qw(load_1 load_5 load_15 network_receive network_transmit
		disk_read disk_write memory_free pool_free);
	my @rules = map { +{ id => $_, metric => $_, scope => 'host',
		enabled => 1, device => $_ eq 'pool_free' ? $name : '' } } @metrics;
	my $observations = Cloudmin::NotificationSignals::observations(
		\@rules, $snapshot, Time::HiRes::time(), { });
	for my $metric (@metrics) {
		ok(@{$observations->{$metric} || [ ]} &&
			defined($observations->{$metric}->[0]->{value}),
			"real collector supplies $metric");
		}
	# Register an absent VG without creating or changing any LVM storage.
	my $missing_name = $name.'-missing';
	my $lvm = Cloudmin::LVM->new();
	die "Fixture VG already exists\n" if $lvm->inventory()->{$missing_name};
	$missing_pool = get_libvirt(1)->connect()->define_storage_pool(
		"<pool type='logical'><name>$missing_name</name><source>".
		"<name>$missing_name</name></source><target>".
		"<path>/dev/$missing_name</path></target></pool>");
	# A second rule watches only the missing volume group's pool.
	$store->save_rule({ name => 'Missing VG', metric => 'pool_inactive',
		scope => 'host', device => $missing_name, duration => 0, cooldown => 0,
		targets => [ $target ] }, time());
	sample(0, $missing_name);
	$events = $store->history()->{events};
	is($events->[-1]{name}, 'Missing VG', 'collector evaluates the absent VG');
	is($events->[-1]{phase}, 'firing', 'absent VG produces a real pool alert');
	1;
	};
my $error = $@;
# Remove only fixture definitions. No VG was created. A failure here must
# not skip the directory pool cleanup below.
my $missing_cleaned = !$missing_pool || eval { $missing_pool->undefine(); 1 };
my $missing_error = $@;
# Keep files if undefining the directory pool fails.
if ($pool) {
	my $cleaned = eval {
		$pool->destroy() if $pool->is_active();
		$pool->undefine();
		1;
		};
	die "Cannot remove fixture pool $name: $@\n" unless $cleaned;
	}
# Remove the private store and files, then report any cleanup failure.
remove_tree($fixture);
die "Cannot remove fixture pool $name-missing: $missing_error\n"
	unless $missing_cleaned;
die $error unless $ok;
done_testing();
