#!/usr/bin/perl
# Always-on sampling; SQLite recording can be disabled without losing live data.
use strict;
use warnings;
use FindBin qw($Bin);
BEGIN { chdir($Bin) or die "Cannot enter Cloudmin module directory: $!\n"; }
use lib "$Bin/../vendor_perl";
use Time::HiRes qw(time sleep clock_gettime CLOCK_MONOTONIC);
use Fcntl qw(:DEFAULT :flock O_NOFOLLOW);
use POSIX qw(_exit WNOHANG);
use IO::Select;
use IO::Socket::UNIX;
use Socket qw(SOCK_DGRAM);
use Sys::Virt;
use Sys::Virt::Event;
require './server-manager-lib.pl';
require './cloudmin-statistics-lib.pl';
require './lib/Cloudmin/StatsCollector.pm';
require './lib/Cloudmin/Probe.pm';
our (%config, $module_var_directory, $module_config_directory);
# Run outside request ACLs and surface Webmin failures as collector exceptions.
our $error_must_die = 1;
our $readonly_mode_cache = 0;
die "Run the statistics collector on its Linux host as root\n" unless $^O eq 'linux' && $< == 0;
umask(0077);
make_dir($module_var_directory, 0700, 1);
my $runtime = statistics_runtime_directory();
make_dir($runtime, 0700, 1);
# Hold a nonblocking process lock for the lifetime of the sole history writer.
sysopen(my $lock, "$module_var_directory/statistics.lock", O_RDWR | O_CREAT | O_NOFOLLOW, 0600)
	or die "Cannot open statistics lock: $!\n";
flock($lock, LOCK_EX | LOCK_NB) or die "Statistics collector is already running\n";
my $host_id = Cloudmin::Statistics::host_id($module_config_directory);
my $sampler = Cloudmin::StatsCollector->new(interval => 10);
# Keep inventory, event generations and slow-probe scheduling separate from
# history.
my (%vms, %dirty, %generation, %guests, %due, %failures);
my ($adapter, $connection, @subscriptions, $store, $settings, $pending, $pools);
my ($next_sample, $next_inventory, $next_database, $next_cleanup, $next_pools) = (0, 0, 0, 0, 0);
my ($worker, $request, $response, $buffer) = (undef, undef, undef, '');
my $stop = 0;
$SIG{$_} = sub { $stop = 1 } for qw(TERM INT HUP);
$SIG{PIPE} = 'IGNORE';

# Start the guest probe supervisor before creating any SQLite/libvirt handles.
# Only one bounded guest call is outstanding, independent of fleet/viewer size.
pipe(my $requests, $request) or die "Cannot create guest probe pipe\n";
pipe($response, my $responses) or die "Cannot create guest result pipe\n";
$worker = fork();
die "Cannot start guest probe supervisor\n" unless defined($worker);
# The supervisor owns only its pipes. Each guest probe gets a bounded child.
if (!$worker) {
	close($lock);
	close($request);
	close($response);
	$SIG{$_} = sub { _exit(0) } for qw(TERM INT HUP);
	select((select($responses), $| = 1)[0]);
	while (my $line = <$requests>) {
		my $task = eval { convert_from_json($line) };
		# End the worker if its request stream no longer contains a valid guest
		# task.
		last unless $task && $task->{id};
		my $result = Cloudmin::Probe::run(sub {
			# Libvirt requires a writable connection even for guest-agent reads.
			get_libvirt(1)->get_guest_resources($task->{id});
			}, 8);
		print $responses convert_to_json($result || {error => 1}, 0, 1)."\n" or last;
		}
	_exit(0);
	}
# The parent retains only the request writer and result reader.
close($requests);
close($responses);
select((select($request), $| = 1)[0]);
END {
	local $?;
	# Stop the supervisor on parent exit without blocking shutdown on it.
	if ($worker && $$ != $worker) {
		kill('TERM', $worker);
		waitpid($worker, WNOHANG);
		}
	}
Sys::Virt::Event::register_default();
Sys::Virt::Event::add_timeout(0, sub { });

# notify_watchdog() lets systemd restart a collector stuck in a native call.
sub notify_watchdog
{
# Direct runs have no watchdog socket. Systemd may use an abstract UNIX socket.
my $path = $ENV{NOTIFY_SOCKET} || return;
$path =~ s/^@/\0/;
my $socket = IO::Socket::UNIX->new(Type => SOCK_DGRAM, Peer => $path);
$socket->send("WATCHDOG=1") if $socket;
}

# collect_domain(domain) refreshes runtime device mappings without guest probes.
sub collect_domain
{
my ($domain) = @_;
my $vm = $adapter->get_domain_record($domain, 1);
my $xml = $domain->get_xml_description(0);
$vm->{disks} = [Cloudmin::Libvirt::extract_disks($xml)];
$vm->{interfaces} = [Cloudmin::Libvirt::extract_interfaces($xml)];
$vm->{runtime_id} = $domain->get_id();
# Balloon reporting is runtime-only and does not change guest memory allocation.
eval { $domain->set_memory_stats_period($settings->{interval}, 1) }
	if $vm->{active} && !$vm->{memory_stats_period};
$vms{$vm->{uuid}} = $vm;
}

# refresh_domain(id, wall, [domain]) contains a guest's inventory failure.
# Omit domain to look it up after an event or retry a failed inventory read.
sub refresh_domain
{
my ($id, $wall, $domain) = @_;
# Event-driven refreshes resolve the current domain before reading its XML.
if (!$domain) {
	$domain = eval { $connection->get_domain_by_uuid($id) };
	if (!$domain) {
		# A guest libvirt no longer finds after an event was most likely
		# deleted. The next full inventory confirms the removal, so reporting
		# an error or an outage event here would misdescribe an ordinary
		# deletion. A surviving guest keeps its rate baseline across the gap.
		delete $vms{$id};
		delete $guests{$id};
		delete $due{$id};
		delete $failures{$id};
		$generation{$id}++;
		$next_inventory = 0;
		return;
		}
	}
my $ok = eval { collect_domain($domain); 1 };
# A complete read replaces inventory without disturbing a healthy rate baseline.
return if $ok;
my $error = $@;
# Old mappings and pending agent results must not survive a failed refresh.
# Invalidate once per outage, then retry this guest on the next sampling tick.
$sampler->invalidate($id, $wall, 'unavailable', 'Guest inventory unavailable')
	if delete $vms{$id};
delete $guests{$id};
delete $due{$id};
delete $failures{$id};
$generation{$id}++;
$dirty{$id} = 1;
return "Guest $id inventory failed: ".error_message($error);
}

# connect_statistics() subscribes before inventory so device changes cannot be lost.
sub connect_statistics
{
$adapter = get_libvirt(1);
$connection = $adapter->connect();
for my $spec ([Sys::Virt::Domain::EVENT_ID_LIFECYCLE(), 'lifecycle'],
	[Sys::Virt::Domain::EVENT_ID_REBOOT(), 'reboot'],
	[Sys::Virt::Domain::EVENT_ID_DEVICE_ADDED(), 'device-added'],
	[Sys::Virt::Domain::EVENT_ID_DEVICE_REMOVED(), 'device-removed'],
	[Sys::Virt::Domain::EVENT_ID_AGENT_LIFECYCLE(), 'agent']) {
	my ($event, $kind) = @$spec;
	# event(connection, domain, ...) marks mappings dirty and rejects older
	# probe replies.
	push @subscriptions, $connection->domain_event_register_any(undef, $event, sub {
		my (undef, $domain) = @_;
		my $id = $domain->get_uuid_string();
		$dirty{$id} = 1;
		$generation{$id}++;
		delete $guests{$id};
		$due{$id} = 0;
		$sampler->invalidate($id, time(), $kind, 'Guest '.$kind.' event');
		});
	}
$next_inventory = 0;
}

my ($last_error, $last_warning) = ('', 0);
while (!$stop) {
	my $mono = clock_gettime(CLOCK_MONOTONIC);
	my $wall = time();
	notify_watchdog();
	# Reap completed slow probes without delaying counter collection.
	if (IO::Select->new($response)->can_read(0)) {
		my $bytes = sysread($response, my $chunk, 65536);
		last if $stop;
		die "Guest probe supervisor stopped\n" unless $bytes;
		$buffer .= $chunk;
		die "Guest probe reply is too large\n" if length($buffer) > 2 * 1024 * 1024;
		# Wait for a complete newline-delimited reply before decoding the probe
		# result.
		if ($buffer =~ s/\A([^\n]*)\n//) {
			my $result = eval { convert_from_json($1) } || {error => 1};
			# Only a reply to the outstanding probe may update cached guest
			# data.
			if ($pending) {
				my ($id, $version) = @$pending;
				# Ignore results collected before a guest event or removal.
				if ($vms{$id} && $version == ($generation{$id} || 0)) {
					$result->{checked_at} = $wall;
					$guests{$id} = $result;
					# Failed probes back off per guest. A success restores the
					# normal cadence.
					$failures{$id} = $result->{error} ? min_value(6, ($failures{$id} || 0) + 1) : 0;
					$due{$id} = $mono + min_value(3600, ($settings->{guest_interval} || 60) * 2 ** $failures{$id});
					}
				}
			$pending = undef;
			}
		}
	# Let systemd restart the service if the supervisor fails to enforce its
	# timeout.
	die "Guest probe supervisor timed out\n" if $pending && $mono - $pending->[2] > 15;
	# Events are cheap; all bulk sampling and writes happen on the configured tick.
	eval { Sys::Virt::Event::run_default() } if $connection;
	# Use one scheduled tick for config reload, sampling, history and live
	# publication.
	if ($mono >= $next_sample) {
		my %saved;
		if (read_file("$module_config_directory/config", \%saved)) {
			# Removing an override must restore its default, not retain the old
			# value in this long-lived process's configuration hash.
			delete @config{grep { /^statistics_/ } keys %config};
			$config{$_} = $saved{$_} for grep { /^statistics_/ } keys %saved;
			}
		$settings = statistics_settings();
		$sampler->{interval} = $settings->{interval};
		$sampler->{guest_interval} = $settings->{guest_interval};
		$next_sample = $mono + $settings->{interval};
		my ($rows, $live, $host) = ([], {}, {});
		my @errors;
		my $ok = eval {
			die "Statistics require a local libvirt connection\n" if $config{libvirt_uri} ne 'qemu:///system';
			connect_statistics() unless $connection;
			# Periodic inventory reconciles changes that arrived outside
			# Cloudmin or events.
			if ($mono >= $next_inventory) {
				# A listing failure still reconnects the shared connection.
				# Individual guest failures leave the remaining guests usable.
				my @domains = $connection->list_all_domains(0);
				%dirty = ();
				$next_inventory = $mono + 60;
				my %present;
				my $complete = 1;
				for my $domain (@domains) {
					my $id = eval { $domain->get_uuid_string() };
					if (!$id) {
						# An unidentified guest cannot prove an old one was removed.
						push @errors, 'Guest identity lookup failed: '.error_message($@);
						$complete = 0;
						$next_inventory = $mono + $settings->{interval};
						next;
						}
					$present{$id} = 1;
					my $error = refresh_domain($id, $wall, $domain);
					push @errors, $error if $error;
					}
				# Only a complete domain listing can confirm deletions and
				# discard their state.
				my %known = (%vms, %{$sampler->{signatures}});
				for my $id (grep { $complete && !$present{$_} } keys %known) {
					$sampler->invalidate($id, $wall, 'removed', 'Virtual machine removed');
					delete $vms{$id};
					delete $guests{$id};
					delete $due{$id};
					delete $failures{$id};
					# Keep an in-flight probe generation until its old reply can
					# be rejected.
					delete $generation{$id} unless $pending && $pending->[0] eq $id;
					delete $sampler->{signatures}->{$id};
					delete $sampler->{sources}->{$id};
					}
				}
			else {
				# Do not retry a failed full-inventory read twice in one tick.
				for my $id (keys %dirty) {
					delete $dirty{$id};
					my $error = refresh_domain($id, $wall);
					push @errors, $error if $error;
					}
				}
			my $stats = $adapter->get_resource_stats();
			# Timestamp the bulk read, not the start of an inventory refresh.
			# Slow XML lookups must not distort the following counter interval.
			$mono = clock_gettime(CLOCK_MONOTONIC);
			$wall = time();
			$next_sample = $mono + $settings->{interval} if $mono >= $next_sample;
			for my $id (sort keys %vms) {
				my ($samples, $value, $unknown) = $sampler->vm($vms{$id}, $stats->{$id} || {}, $guests{$id}, $mono, $wall);
				push @$rows, @$samples;
				$live->{$id} = $value;
				# Unmapped bulk entries request an XML refresh on the next tick.
				$dirty{$id} = 1 if $unknown;
				}
			1;
			};
		# A connection-wide failure drops baselines so recovery cannot bridge
		# the outage.
		if (!$ok) {
			push @errors, 'Libvirt collection failed: '.error_message($@);
			eval { $connection->domain_event_deregister_any($_) } for @subscriptions;
			@subscriptions = ();
			$connection = undef;
			eval { $adapter->disconnect() } if $adapter;
			$adapter = undef;
			$sampler->invalidate($_, $wall, 'unavailable', 'Libvirt connection interrupted') for keys %vms;
			}
		# Partial inventory must not make guest allocations look smaller. A
		# missing UUID also needs the next inventory to confirm its removal.
		my $guests_complete = $ok && !@errors && $next_inventory;
		# Storage pools change slowly and listing LVM runs commands, so they
		# follow the inventory cadence. A listing failure only drops the pools.
		if ($adapter && $mono >= $next_pools) {
			my $listed = eval {
				my @active = grep { $_->{active} } @{$adapter->list_storage_pools()};
				$pools = [];
				for my $pool (@active) {
					push @$pools, +{map { ($_ => $pool->{$_}) } qw(uuid name type target capacity allocation available fsid)};
					}
				1;
				};
			# Do not reuse pool readings after a failed inventory refresh.
			if (!$listed) {
				push @errors, 'Storage pool collection failed: '.error_message($@);
				$pools = undef;
				}
			$next_pools = $mono + 60;
			}
		# A lost libvirt connection also makes the cached pool list unavailable.
		$pools = undef unless $adapter;
		my $host_ok = eval {
			$mono = clock_gettime(CLOCK_MONOTONIC);
			$wall = time();
			# Guest totals are meaningful only when this tick read every guest.
			my ($samples, $value) = $sampler->host($host_id, $mono, $wall,
				{%$settings, guests => ($guests_complete ? $live : undef), pools => $pools});
			push @$rows, @$samples;
			$host = $value;
			push @errors, $value->{error} if $value->{error};
			1;
			};
		push @errors, 'Host collection failed: '.error_message($@) unless $host_ok;
		my $events = $sampler->events();
		# History failure is isolated from publishing the just-collected live data.
		if ($settings->{recording}) {
			my $saved = eval {
				# Retry a failed database open at most once per minute.
				if (!$store && $mono >= $next_database) {
					$store = Cloudmin::Statistics->new(directory => $module_var_directory, write => 1,
						host_id => $host_id, hardware_uuid => $host->{hardware_uuid});
					}
				# A healthy writer prunes periodically and records one
				# transaction per tick.
				if ($store) {
					# Retention maintenance runs less often than sampling to
					# bound its overhead.
					if ($mono >= $next_cleanup) {
						$store->prune($wall, $settings->{retention}, $settings->{budget});
						$next_cleanup = $mono + 60;
						}
					$store->record($rows, $events, $wall);
					}
				1;
				};
			# Close a failed writer and keep the live cache independent of
			# history recovery.
			if (!$saved) {
				$last_error = 'History recording failed: '.error_message($@);
				$store = undef;
				$next_database = $mono + 60;
				}
			# A completed write clears the previous history error.
			elsif ($store) { $last_error = ''; }
			push @errors, $last_error if $last_error;
			}
		# Disabling recording closes history while sampling and live publication
		# continue.
		else {
			$store = undef;
			$last_error = '';
			$next_database = 0;
			}
		my $error = join('; ', @errors);
		# Throttle repeated diagnostics without suppressing the current cache
		# error.
		if ($error && $mono - $last_warning > 60) {
			warn "$error\n";
			$last_warning = $mono;
			}
		# Publish host and guest values together so readers never see a partial
		# tick.
		Cloudmin::Statistics::atomic_write("$runtime/statistics-latest.json",
			convert_to_json({version => 1, host_id => $host_id, checked_at => $wall,
				interval => $settings->{interval}, recording => $settings->{recording},
				error => $error || undef, vms => $live, host => $host}, 0, 1));
		}
	# Pace the fleet's filesystem probes to one outstanding request at a time.
	last if $stop;
	# Start another probe only after the current one finishes and settings are
	# loaded.
	if (!$pending && $settings) {
		my ($id) = sort { ($due{$a} || 0) <=> ($due{$b} || 0) || $a cmp $b }
			grep { $vms{$_}->{state} =~ /\A(?:running|blocked)\z/ && ($due{$_} || 0) <= $mono } keys %vms;
		# Probe the earliest due running guest and tag its current event
		# generation.
		if ($id) {
			$pending = [$id, $generation{$id} || 0, $mono];
			print $request convert_to_json({id => $id}, 0, 1)."\n" or die "Guest probe pipe closed\n";
			}
		}
	sleep(0.25);
	}

# min_value(a,b) caps retry backoff without depending on UI math helpers.
sub min_value { return $_[0] < $_[1] ? $_[0] : $_[1]; }

exit(0);
