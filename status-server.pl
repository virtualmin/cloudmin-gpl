#!/usr/bin/perl
# One host collector serves authenticated Cloudmin subscribers in every theme.
use strict;
use warnings;
no warnings 'once';
use FindBin qw($Bin);
use lib "$Bin/../vendor_perl";
use Net::WebSocket::Server;
use IO::Socket::INET;
use MIME::Base64 ();
use POSIX qw(WNOHANG);
use Fcntl qw(:flock);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);
use Sys::Virt;
use Sys::Virt::Event;
require './server-manager-lib.pl';
require './cloudmin-status-lib.pl';
require './cloudmin-statistics-lib.pl';
require './lib/Cloudmin/Status.pm';
require './lib/Cloudmin/Probe.pm';
our ($module_name, $module_var_directory, $remote_user, %config,
     $cloudmin_status_protocol);
our $error_must_die = 1;
# This dedicated process owns shared status files and its proxy route, including
# END cleanup. Viewer permissions are checked separately by authorized().
$main::readonly_mode_cache = 0;
my ($port) = @ARGV;
# Only the CGI-selected loopback port may be bound by this collector.
die "Invalid status port\n"
	if (!defined($port) || $port !~ /^\d{1,5}$/ || $port < 1 ||
	    $port > 65535);
my $listener = IO::Socket::INET->new(Listen => 16, LocalAddr => '127.0.0.1',
				     LocalPort => $port, Proto => 'tcp',
				     ReuseAddr => 1) ||
	       die "Cannot listen for status\n";
my $file = "$module_var_directory/status-server.json";
my $child = fork();
die "Cannot start status backend\n" if (!defined($child));
if ($child) {
	# Publish the already-bound listener before releasing
	# the CGI startup lock.
	write_file_contents($file,
			    convert_to_json({ port => 0 + $port, pid => $child,
					      uri => $config{'libvirt_uri'},
					      protocol => $cloudmin_status_protocol }, 0, 1));
	chmod(0600, $file);
	exit(0);
	}
untie(*STDIN);
open(STDIN, '<', '/dev/null') || die "Cannot detach status input\n";
my ($worker, $request, $response, $pending, $probe_started);
my $owner = $$;

END
{
# The probe child and startup parent must not clean up the collector's route.
if ($owner && $$ == $owner) {
	# Remove the route promptly even if a native probe ignores termination.
	kill('TERM', $worker) if ($worker);
	waitpid($worker, WNOHANG) if ($worker);
	my $state =
		eval { convert_from_json(read_file_contents($file)) } ||
		{ };
	# An older backend must not remove its replacement's registration.
	if (($state->{'pid'} || 0) == $$) {
		unlink($file);
		eval { remove_miniserv_websocket($port, $module_name);
			};
		}
	}
}
# signal(name) exits through END so the route and probe worker are released.
$SIG{$_} = sub { exit(0); } for qw(TERM INT HUP);
$SIG{'PIPE'} = 'IGNORE';

# A single worker performs bounded guest probes without blocking event delivery.
# Fork before opening libvirt, so the worker never inherits an event connection.
pipe(my $read_requests, $request) || die "Cannot create health input\n";
pipe($response, my $write_responses) || die "Cannot create health output\n";
$worker = fork();
die "Cannot start health worker\n" if (!defined($worker));
if (!$worker) {
	# Keep only the probe pipes; this child never accepts
	# browser connections.
	close($listener); close($request); close($response);
	select(( select($write_responses), $| = 1 )[0]);
	while (my $line = <$read_requests>) {
		my $task = convert_from_json($line);
		# The shared cache contains capabilities, not a viewer's grants.
		# The supervisor stays outside libvirt, even when a native call
		# hangs. Probe connection health in a child with a timeout.
		# Resource collection runs separately in
		# cloudmin-statistics.service.
		my $result = Cloudmin::Probe::run(sub {
			get_server_health($task->{'id'}) }, 8);
		$result ||= { error => 1 };
		delete($result->{'labels'});
		print $write_responses convert_to_json($result, 0, 1)."\n";
		}
	exit(0);
	}
close($read_requests); close($write_responses);
select(( select($request), $| = 1 )[0]);

my $cache = Cloudmin::Status->new();
my (%clients, %dirty, %generation, @events, $adapter, $connection, $fault);
my ($retry_at, $idle_since, $last_auth, $last_heartbeat,
    $jobs_signature) = ( 0,
			 time(), 0, 0, 'initial' );
my (%job_counts, $image_count, $job_error, $jobs_checked);
my $buffer = '';
my $sample_at = 0;
Sys::Virt::Event::register_default();
# A zero timer makes each event-loop iteration nonblocking. The WebSocket loop
# controls the wakeup interval; this does not issue periodic libvirt queries.
# timeout(timer) is a no-op wakeup; the WebSocket tick owns scheduling.
Sys::Virt::Event::add_timeout(0, sub { });

# authorized(session) checks live login and module grants, including revocation.
sub authorized
{
return session_access($_[0]);
}

# authorize_client(client) refreshes identity, VM scope and action grants.
# Returns false when the login or module access is no longer valid.
sub authorize_client
{
my ($client) = @_;
my $access = authorized($client->{'session'});
# Expired or revoked logins cannot keep their previously cached grants.
return 0 if (!$access);
$client->{'user'} = $access->{'user'};
# Compare sorted JSON so ACL key order alone cannot trigger a page reload.
my $signature = convert_to_json({ %{$access->{'policy'}} }, 0, 0, 1);
if (defined($client->{'acl_signature'}) &&
    $client->{'acl_signature'} ne $signature) {
	# Reload both controls and inventory when a session's permissions
	# change. Keep the socket open long enough to
	# deliver this queued notice.
	$client->send_utf8('{"type":"access_changed"}');
	}
if (my $sub = $clients{$client}) {
	# Apply the new scope even when the browser ignores the reload notice.
	$sub->{'policy'} = $access->{'policy'};
	delete($sub->{'revision'});
	}
$client->{'acl_signature'} = $signature;
$client->{'policy'} = $access->{'policy'};
return 1;
}

# collect_domain(domain) refreshes one changed VM without guest-agent requests.
sub collect_domain
{
my ($domain) = @_;
my $record = $adapter->get_domain_record($domain, 1);
my $id = $record->{'uuid'};
# Preserve addresses until a lifecycle event or a targeted probe replaces them.
$record->{'addresses'} = $record->{'active'}
	? ($cache->{'vms'}->{$id}->{'addresses'} ||
	   $adapter->get_domain_addresses($domain, $record, 1))
	: [ ];
$cache->record($record);
}

# connect_libvirt() Subscribes before reading the inventory so startup
# changes are retained.
sub connect_libvirt
{
$adapter = get_libvirt(1);
$connection = $adapter->connect();
for my $event ( Sys::Virt::Domain::EVENT_ID_LIFECYCLE(),
		Sys::Virt::Domain::EVENT_ID_REBOOT(),
		Sys::Virt::Domain::EVENT_ID_AGENT_LIFECYCLE(),
		Sys::Virt::Domain::EVENT_ID_DEVICE_ADDED(),
		Sys::Virt::Domain::EVENT_ID_DEVICE_REMOVED() ) {
	# domain_event(connection, domain, ...) invalidates
	# data from older probes.
	push(@events,
	     $connection->domain_event_register_any(undef, $event,
						    sub {
				my (undef, $domain) = @_;
				my $id = $domain->get_uuid_string();
				$dirty{$id} = 1;
				$generation{$id}++;
				$cache->invalidate($id);
				# Boot, stop and agent changes can invalidate
				# old DHCP or agent addresses.
				delete($cache->{'vms'}->{$id}->{'addresses'})
					if ($cache->{'vms'}->{$id});
				}));
	}
my %present;
# Reconcile the inventory with cached guests after startup or reconnection.
foreach my $domain ($connection->list_all_domains(0)) {
	$present{$domain->get_uuid_string()} = 1;
	collect_domain($domain);
	}
$cache->remove($_) for grep { !$present{$_} } keys %{$cache->{'vms'}};
delete($_->{'known'}) for values %clients;
$fault = undef;
}

# refresh_jobs(now) recounts jobs when either store changes. Image jobs are
# shared; VM job totals are kept separately for each owner.
sub refresh_jobs
{
my ($now) = @_;
my $images = get_image_jobs();
my $vms = get_vm_jobs();
# Image records are atomically replaced JSON files, which change their parent
# directory. VM jobs use one SQLite database.
my $signature = join(':',
		     map { my @s = Time::HiRes::stat($_);
		join(',', map { $_ // 0 } @s[1, 7, 9, 10]) }
		     ( $images->{'directory'},
		       $vms->{'directory'}.'/jobs.sqlite' ));
# Recheck within five seconds: filesystem timestamps can miss quick writes, and
# a worker can die without saving. Failed reads use the same retry limit.
return if ($signature eq $jobs_signature &&
	   defined($jobs_checked) && $now - $jobs_checked < 5);
$jobs_signature = $signature;
$jobs_checked = $now;
%job_counts = (); $image_count = 0; $job_error = 0;
my $ok = eval {
	$image_count = scalar(@{$images->list(undef, 1)});
	$job_counts{$_->{'owner'}}++ for @{$vms->list_pending()};
	1;
	};
# An unreadable store makes the count unavailable, not zero.
$job_error = 1 if (!$ok);
}

my $server = Net::WebSocket::Server->new(
	listen => $listener, tick_period => 0.5, silence_max => 30,
	# on_connect(server, client) installs bounded framing
	# and session callbacks.
	on_connect => sub {
		my ($server, $client) = @_;
		# Queue complete frames, including pings, so slow peers
		# cannot corrupt data.
		bless($client, 'Cloudmin::StatusConnection');
		$client->socket()->blocking(0);
		$client->max_recv_size(4096);
		$client->max_send_size(4 * 1024 * 1024);
		$client->{'deadline'} = time() + 10;
		$client->on(
			# handshake(client, handshake) checks the session
			# supplied by miniserv.
			handshake => sub {
				my (undef, $handshake) = @_;
				my $session =
					MIME::Base64::decode_base64(
						$handshake->req->fields->{'sec-websocket-key'} || '');
				$client->{'session'} = $session;
				my $allowed = eval { authorize_client($client) };
				# Refuse revoked or unauthorized sessions
				# before accepting a target.
				if (!$allowed) {
					warn "Rejected status connection: ".
						($@ || 'invalid session or module access').
						"\n";
					$client->disconnect();
					return;
					}
				},
			# utf8(client, bytes) selects one target and
			# its visibility state.
			utf8 => sub {
				my (undef, $bytes) = @_;
				my $input = eval { convert_from_json($bytes,
								     1) };
				my $id = ref($input) eq 'HASH'
					? $input->{'id'}
					: undef;
				# Accept an overview or authorized VM UUID;
				# reject foreign details.
				if (!$client->{'user'} || !defined($id) ||
				    ref($id) ||
				    $id !~ /\A(?:overview|[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12})\z/i ||
				    ($id ne 'overview' && !$client->{'policy'}->allows('view', $id))) {
					$client->disconnect(); return;
					}
				my $subscription =
					$clients{$client} ||= { client =>
									$client,
								policy => $client->{'policy'} };
				# A new target or explicit resync
				# needs a full snapshot.
				delete($subscription->{'known'})
					if ($input->{'snapshot'} ||
					    ($subscription->{'id'} || '') ne lc($id));
				# A resync also needs the overview job count.
				delete($subscription->{'jobs'})
					if ($input->{'snapshot'});
				$subscription->{'id'} = lc($id);
				$subscription->{'paused'} = $input->{'paused'}
					? 1
					: 0;
				$client->{'deadline'} = undef;
				},
			# disconnect(client) releases write watchers
			# and subscription state.
			disconnect => sub {
				$server->unwatch_writable($client->socket());
				delete($clients{$client});
				},
		);
		},
	# on_tick(server) handles revocation, libvirt events
	# and shared sampling.
	on_tick => sub {
		my ($server) = @_;
		my $now = time();
		# Unsubscribed handshakes cannot keep a
		# server alive indefinitely.
		for my $entry (values %{$server->{'conns'}}) {
			my $client = $entry->{'conn'};
			$client->disconnect()
				if ($client->{'deadline'} &&
				    $client->{'deadline'} < $now);
			}
		# Connected subscribers, including hidden pages,
		# keep the cache alive.
		if (%clients) { $idle_since = $now; }
		# Release resources after the last subscriber has
		# been gone for a minute.
		elsif ($now - $idle_since > 60) { $server->shutdown(); return; }
		# Revoked sessions cannot retain a live
		# subscription after logout.
		if ($now - $last_auth >= 15) {
			$last_auth = $now;
			# A replacement owns a new URI or route;
			# release this collector too.
			my $state =
				eval { convert_from_json(read_file_contents(
					$file)) } ||
				{ };
			if (($state->{'pid'} || 0) != $$) {
				$server->shutdown();
				return;
				}
			for my $sub (values %clients) {
				my $client = $sub->{'client'};
				$client->disconnect()
					if (!eval { authorize_client($client) });
				}
			}
		# Keep quiet connections alive even when no VM
		# fields have changed.
		if ($now - $last_heartbeat >= 20) {
			$last_heartbeat = $now;
			$_->{'client'}->send_utf8(
				'{"type":"heartbeat"}') for values %clients;
			}
		my $ok = eval {
			# Libvirt keepalives need the event loop even between
			# subscribers. Idle collectors still
			# skip queries and probes.
			Sys::Virt::Event::run_default();
			return 1 if (!%clients);
			# Back off after connection failures instead of
			# retrying every tick.
			if (!$connection &&
			    $now >= $retry_at) { connect_libvirt(); }
			# Waiting for reconnection must
			# preserve the retry deadline.
			return 1 if (!$connection);
			die "Libvirt disconnected\n"
				if (!$connection->is_alive());
			# Cloudmin writes invalidations for settings
			# without libvirt events.
			my $changes = "$module_var_directory/status-changes";
			# Drain manual invalidations under the same
			# lock used by writers.
			if (-s $changes) {
				open(my $fh, '+<', $changes) ||
					die "Cannot read status changes\n";
				flock($fh, LOCK_EX);
				while (<$fh>) {
					chomp;
					$dirty{$_} = 1 if (/\A[a-f0-9-]{36}\z/);
					}
				truncate($fh, 0); close($fh);
				}
			foreach my $id (keys %dirty) {
				delete($dirty{$id});
				# A guest can disappear between lookup and
				# its subsequent reads.
				my $read =
					eval { collect_domain(
						$connection->get_domain_by_uuid(
							$id)); 1; };
				# Distinguish a deleted guest from a
				# failed inventory read.
				if (!$read) {
					# A confirmed deletion is a normal
					# delta; other errors need a retry.
					if (ref($@) &&
					    $@->code() == Sys::Virt::Error::ERR_NO_DOMAIN()) { $cache->remove($id); }
					# Retain uncertainty instead of
					# presenting a failed read as removal.
					else { die $@ || "Cannot read virtual machine\n"; }
					}
				}
			refresh_jobs($now);
			1;
			};
		# Mark views unavailable and rebuild the event
		# connection after a fault.
		if (!$ok) {
			warn "Status collection failed: $@";
			$_->{'client'}->send_utf8(
				'{"type":"error"}') for values %clients;
			$fault = 1; $retry_at = $now + 5;
			eval { $connection->domain_event_deregister_any($_); }
				for @events;
			@events = ();
			$connection = undef; $adapter = undef;
			}
		# Cached values must not be published as fresh while
		# libvirt is unavailable.
		return if ($fault);
		my $ids = $cache->resource_ids([ values %clients ]);
		# Live values come from the always-on collector, even
		# with history disabled.
		if (@$ids && $now >= $sample_at) {
			$sample_at = $now + 10;
			# DHCP can assign an address after boot without a domain
			# event. addresses(id, record) uses DHCP data without
			# a guest-agent query.
			$cache->refresh_addresses($ids, sub {
				my ($id, $record) = @_;
				return $adapter->get_domain_addresses(
					$connection->get_domain_by_uuid($id),
					$record, 1);
				});
			$cache->collected($ids, statistics_latest(), time());
			}
		# The worker is reused for every viewer; stale results
		# cannot overwrite events.
		if (!$pending) {
			my $id = $cache->next_probe([ values %clients ], $now);
			# Filesystem probes now belong to the always-on
			# collector. One request at a time keeps probe load
			# independent of viewer count.
			if ($id) {
				$pending = [ $id, $generation{$id} || 0 ];
				$probe_started = $now;
				(print $request convert_to_json({ id => $id },
								0,
								1)."\n") ||
					die "Health worker closed\n";
				}
			}
		# A hung probe worker must not leave every detail
		# page waiting forever.
		die "Health worker stopped responding\n"
			if ($pending && $now - $probe_started > 10);
		foreach my $sub (values %clients) {
			# Hidden pages retain their connection but
			# receive no status deltas.
			next if ($sub->{'paused'});
			my $message = $cache->message($sub);
			# Hide all job counts from delegated users,
			# including shared image jobs.
			my $jobs = !$sub->{'policy'}->allows('host')
				? 0
				: $job_error
					? undef
					: ($image_count ||
					   0) + ($job_counts{$sub->{'client'}->{'user'}} || 0);
			# The overview counts shared image jobs and this user's
			# VM jobs; detail pages need neither total.
			if ($sub->{'id'} eq 'overview' &&
			    (!exists($sub->{'jobs'}) ||
			     ($sub->{'jobs'} // -1) != ($jobs // -1))) {
				$message ||= { type => 'status', changed => { },
					       removed => [ ] };
				$message->{'jobs'} = $jobs;
				$sub->{'jobs'} = $jobs;
				}
			# Unchanged snapshots produce no application frame.
			# send_utf8 performs UTF-8 encoding; pass
			# text, not encoded bytes.
			$sub->{'client'}->send_utf8(convert_to_json($message))
				if ($message);
			}
		},
);
# probe_response(handle) reads one bounded JSON reply from the shared worker.
$server->watch_readable($response, sub {
	my $length = sysread($response, my $bytes, 65536);
	# EOF means no further probes can finish; oversized replies are invalid.
	die "Health worker exited\n" if (!$length);
	$buffer .= $bytes;
	die "Invalid health response\n" if (length($buffer) > 1024 * 1024);
	# Keep partial replies buffered until their newline arrives.
	if ($buffer =~ s/\A([^\n]*)\n//) {
		my $result = convert_from_json($1);
		my ($id, $version) = @$pending;
		# Ignore a reply collected before a lifecycle or device event.
		if ($version == ($generation{$id} || 0)) {
			# Health replies update the agent, SSH and
			# console capabilities.
			$cache->checked($id, $result, time());
			}
		$pending = undef;
		}
	});

package Cloudmin::StatusConnection;
use strict;
use warnings;
use Errno qw(EAGAIN EWOULDBLOCK EINTR);
our @ISA = ('Net::WebSocket::Server::Connection');

# send(self, type, [bytes]) Serializes frames and bounds each slow client's
# queue. Omit bytes for control frames without a payload.
sub send
{
my ($self, $type, $bytes) = @_;
# Let the WebSocket library finish handshake and close handling itself.
return if ($self->{'handshake'} || $type eq 'close');
my $frame = Protocol::WebSocket::Frame->new(type => $type,
					    max_payload_size => $self->{'max_send_size'});
$frame->append($bytes) if (defined($bytes));
my $watch = !length($self->{'outgoing'} || '');
$self->{'outgoing'} .= $frame->to_bytes();
# Drop slow clients before their queued snapshots grow without limit.
if (length($self->{'outgoing'}) > 4 * 1024 * 1024) {
	$self->disconnect();
	return;
	}
# A nonempty queue already has its writer registered.
return if (!$watch);
my $socket = $self->socket();
# writable(socket) drains complete frames without interleaving their bytes.
$self->server()->watch_writable($socket, sub {
	my $length = syswrite($socket, $self->{'outgoing'}, 65536);
	# Preserve unsent bytes on a transient nonblocking write failure.
	return if (!defined($length) &&
		   ($! == EAGAIN || $! == EWOULDBLOCK || $! == EINTR));
	# A closed or failed socket cannot consume the remaining queue.
	if (!$length) { $self->disconnect(); return; }
	substr($self->{'outgoing'}, 0, $length, '');
	# Stop writable wakeups once this client's queue is empty.
	$self->server()->unwatch_writable($socket)
		if (!length($self->{'outgoing'}));
	});
}

package main;
$server->start();
