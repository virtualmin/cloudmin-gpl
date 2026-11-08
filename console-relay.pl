#!/usr/bin/perl
# Relay one authenticated browser connection to a VNC or serial byte socket.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../vendor_perl";
use Net::WebSocket::Server;
use Protocol::WebSocket::Frame;
use IO::Socket::INET;
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use Errno qw(EAGAIN EWOULDBLOCK EINTR);
use lib "$Bin/lib";
use Cloudmin::Relay;
# The optional mode selects the startup deadline; it defaults to graphical.
my $mode = shift(@ARGV) || 'graphical';
# Reject an unknown mode before reading credentials or inherited sockets.
die "Invalid console type\n" if ($mode !~ /\A(?:graphical|serial)\z/);
my ($listener, $session_id) = Cloudmin::Relay::initialize();
# Root supplies only the already-authorized guest byte socket on descriptor 1.
open(my $graphics, '+<&=', 1) || die "Cannot open console stream\n";
my ($connection, $server);
my %pending;
# signal(name) ends the service; the root supervisor removes its proxy route.
$SIG{$_} = sub { exit(0); } for qw(TERM INT HUP ALRM);
$SIG{'PIPE'} = 'IGNORE';
# An unconnected serial relay holds an exclusive port: allow 15 seconds for the
# browser to attach. Graphical connections retain their 60-second window.
alarm($mode eq 'serial' ? 15 : 60);

# queue_console_bytes(handle, bytes) Keeps partial writes in memory while
# bounding a slow peer's pending traffic.

sub queue_console_bytes
{
my ($handle, $bytes) = @_;
my $buffer = \$pending{fileno($handle)};
my $watch = !length($$buffer || '');
$$buffer .= $bytes;
# Disconnect a stalled peer when its queued data exceeds the limit.
die "Console traffic is too large\n" if (length($$buffer) > 16 * 1024 * 1024);
# A queue that was already nonempty has a writer registered.
return if (!$watch);
# writable(server, handle) drains the captured queue without losing partial
# writes; both callback arguments are unused.
$server->watch_writable($handle, sub {
	my $written = syswrite($handle, $$buffer, 65536);
	# Readiness can change between notification and the write itself.
	return if (!defined($written) &&
		   ($! == EAGAIN || $! == EWOULDBLOCK || $! == EINTR));
	# Closing either end releases the complete relay.
	exit(0) if (!$written);
	substr($$buffer, 0, $written, '');
	# Avoid writable wakeups while there is nothing to forward.
	$server->unwatch_writable($handle) if (!length($$buffer));
	});
}

# browser_alive(client) resets the active browser's 60-second timeout. Returns
# false for other clients. Input, pongs and text count as activity.

sub browser_alive
{
# Rejected or additional clients must not keep another session alive.
return 0 if (!$connection || $_[0] != $connection);
alarm(60);
return 1;
}

$server = Net::WebSocket::Server->new(
	listen => $listener,
	# Library pings bypass our partial-write queue and could
	# split a guest frame.
	silence_max => 0,
	tick_period => 15,
	# on_tick(server) queues pings after guest frames. Browsers reply
	# without JavaScript, even when background page timers are throttled.
	on_tick => sub {
		# Before authentication, only the startup deadline applies.
		return if (!$connection);
		my $frame = Protocol::WebSocket::Frame->new(type => 'ping');
		queue_console_bytes($connection->socket(), $frame->to_bytes());
		},
	# on_connect(server, client) installs authentication and I/O callbacks.
	on_connect => sub {
		my ($server, $client) = @_;
		$client->max_recv_size(1024 * 1024);
		my $authenticated;
		$client->on(
			# handshake(client, handshake) permits only this
			# session's first client.
			handshake => sub {
				my ($client, $handshake) = @_;
				# The proxy replaces this key with the
				# authenticated Webmin session.
				$authenticated = !$connection &&
						 Cloudmin::Relay::authenticated(
							 $handshake->req->fields->{'sec-websocket-key'}, $session_id);
				$client->disconnect() if (!$authenticated);
				},
			# ready(client) attaches the prepared stream
			# after authentication.
			ready => sub {
				# Rejected or additional clients cannot attach
				# to the guest console.
				return if (!$authenticated || $connection);
				$connection = $client;
				# Switch only after the HTTP upgrade has
				# been written in full.
				$connection->socket()->blocking(0);
				my $flags = fcntl($graphics, F_GETFL, 0);
				defined($flags) &&
					fcntl($graphics, F_SETFL,
					      $flags | O_NONBLOCK) ||
					die "Cannot configure the console socket\n";
				# Start the 60-second browser activity deadline.
				# systemd still enforces the eight-hour
				# total session limit.
				browser_alive($client);
				# readable(server, handle) frames guest output.
				# Uses the captured socket; ignores arguments.
				$server->watch_readable($graphics, sub {
					my $length = sysread($graphics,
							     my $buffer, 65536);
					# Retry transient reads; EOF or a
					# permanent error ends the relay.
					return if (!defined($length) &&
						   ($! == EAGAIN || $! == EWOULDBLOCK ||
						    $! == EINTR));
					exit(0) if (!$length);
					my $frame = Protocol::WebSocket::Frame->new(type => 'binary');
					$frame->append($buffer);
					queue_console_bytes($connection->socket(), $frame->to_bytes());
					});
				},
			# binary(client, bytes) forwards authorized guest input.
			binary => sub {
				my ($client, $bytes) = @_;
				# Only the first authenticated client
				# may send guest input.
				return if (!$authenticated || !$graphics ||
					   !browser_alive($client));
				queue_console_bytes($graphics, $bytes);
				},
			# pong(client, bytes) counts activity, discarding bytes.
			pong => sub { browser_alive($_[0]); },
			# utf8(client, text) counts activity, discarding text.
			utf8 => sub { browser_alive($_[0]); },
			# disconnect(client) releases the relay only for
			# its active connection.
			disconnect => sub {
				# An unauthorized or second client cannot
				# close the active console.
				exit(0) if ($connection &&
					    $_[0] == $connection);
				},
		);
		},
);
Cloudmin::Relay::ready();
$server->start();
