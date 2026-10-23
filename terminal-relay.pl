#!/usr/bin/perl
# Webmin's xterm transport attached directly to an isolated SSH process.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../vendor_perl";
use Net::WebSocket::Server;
use Protocol::WebSocket::Frame;
use IO::Socket::INET;
use IPC::Open3 qw(open3);
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use Errno qw(EAGAIN EWOULDBLOCK EINTR);
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);
use JSON::PP qw(encode_json);
use MIME::Base64 ();
use POSIX qw(WNOHANG);
use lib "$Bin/lib";
use Cloudmin::Relay;
my ($listener, $session_id) = Cloudmin::Relay::initialize();
# The controller supplies fixed SSH arguments, never a host shell command.
die "Invalid terminal command\n" if (!@ARGV || $ARGV[0] ne '/usr/bin/ssh');
my ($connection, $input, $output, $errors, $pid);
my $queued = '';
my $outgoing = '';
my $finished;
my $diagnostics_finished;
my $owner = $$;
END {
	# systemd also stops the entire service when the relay exits or is killed.
	if ($owner == $$ && $pid) {
		close($input) if ($input);
		kill('TERM', $pid);
		waitpid($pid, WNOHANG);
		}
	}
# signal(name) exits through END and systemd's service cleanup.
$SIG{$_} = sub { exit(0); } for qw(TERM INT HUP ALRM);
$SIG{'PIPE'} = 'IGNORE';
# Abandoned pages cannot keep listening without an authenticated socket.
alarm(60);
my $server;
$server = Net::WebSocket::Server->new(
	listen => $listener,
	# Output frames are written in chunks; a server ping written between two
	# chunks would corrupt the stream. Miniserv closes this socket when the
	# browser goes away, so idle-connection pings are not needed.
	silence_max => 0,
	# on_connect(server, client) installs session checks and terminal
	# callbacks.
	on_connect => sub {
		my ($server, $client) = @_;
		$client->max_recv_size(1024 * 1024);
		my $authenticated;
		$client->on(
			# handshake(client, handshake) admits this session's
			# first client only.
			handshake => sub {
				my ($client, $handshake) = @_;
				# Match the session substituted by Webmin's authenticated proxy.
				$authenticated = !$connection &&
				Cloudmin::Relay::authenticated(
					$handshake->req->fields->{'sec-websocket-key'}, $session_id);
				$client->disconnect() if (!$authenticated);
				},
			# ready(client) starts SSH only after the proxy session
			# is verified.
			ready => sub {
				# Extra clients cannot start another SSH process
				# or replace this one.
				return if (!$authenticated || $connection);
				$connection = $client;
				# Keep a slow browser from blocking the relay's input and cleanup.
				$connection->socket()->blocking(0);
				alarm(8 * 3600);
				# Separate private channels carry input events,
				# terminal output and worker diagnostics.
				my ($child_input, $child_output, $child_errors);
				socketpair($input, $child_input, AF_UNIX,
				SOCK_STREAM, PF_UNSPEC) &&
					socketpair($output, $child_output,
					AF_UNIX, SOCK_STREAM, PF_UNSPEC) &&
					socketpair($errors, $child_errors,
					AF_UNIX, SOCK_STREAM, PF_UNSPEC)
					|| die "Cannot create terminal channels\n";
				$pid = open3('<&'.fileno($child_input),
				'>&'.fileno($child_output),
					'>&'.fileno($child_errors), $^X,
					"$Bin/terminal-worker.pl", @ARGV);
				close($_) for grep { defined(fileno($_)) }
				($child_input, $child_output, $child_errors);
				die "Cannot start SSH\n" if (!$pid);
				my $flags = fcntl($input, F_GETFL, 0);
				defined($flags) &&
				fcntl($input, F_SETFL, $flags | O_NONBLOCK)
					|| die "Cannot configure terminal input\n";
				# output_readable(handle) frames worker output
				# and drains it on EOF.
				$server->watch_readable($output, sub {
					my $length = sysread($output,
						my $buffer, 8192);
					if (!$length) {
						# Drain guest output and login
						# events before closing.
						$finished = 1;
						$server->unwatch_readable($output);
						exit(0) if ($diagnostics_finished && !length($outgoing));
						return;
						}
					# WebSocket sockets are nonblocking.
					# Keep unsent frame bytes when a slow
					# browser cannot accept a complete write
					# immediately.
					my $frame = Protocol::WebSocket::Frame->new(type => 'binary');
					$frame->append($buffer);
					my $watch = !length($outgoing);
					$outgoing .= $frame->to_bytes();
					die "Terminal output is too large\n"
					if (length($outgoing) > 4 * 1024 * 1024);
					# browser_writable(socket) retains
					# unsent frame bytes across ticks.
					# A nonempty queue already has its writer registered.
					$server->watch_writable($connection->socket(), sub {
						my $written = syswrite($connection->socket(), $outgoing, 8192);
						# A transient failure leaves the
						# complete remainder queued.
						return if (!defined($written) &&
						($! == EAGAIN ||
						$! == EWOULDBLOCK ||
						$! == EINTR));
						# A disconnected browser no
						# longer needs its SSH worker.
						exit(0) if (!$written);
						substr($outgoing, 0, $written,
						'');
						# Stop writes when drained;
						# close after both worker
						# streams finish.
						if (!length($outgoing)) {
							$server->unwatch_writable($connection->socket());
							exit(0) if ($finished && $diagnostics_finished);
							}
						}) if ($watch);
					});
				# errors_readable(handle) forwards worker
				# diagnostics and login events until EOF.
				$server->watch_readable($errors, sub {
					# Forward worker diagnostics and login
					# events. SSH output and passwords stay
					# on the PTY and are never logged.
					if (sysread($errors, my $buffer,
						8192)) {
						print STDERR $buffer;
						}
					else {
						# Drain both streams so a quick
						# exit retains its login event.
						$diagnostics_finished = 1;
						$server->unwatch_readable($errors);
						exit(0) if ($finished && !length($outgoing));
						}
					});
				},
			# utf8(client, message) sends bounded resize or
			# keystroke events to SSH.
			utf8 => sub {
				my ($client, $message) = @_;
				# Only the authenticated connection can write to
				# the worker.
				return if (!$authenticated || !$input ||
				$client != $connection);
				my ($rows, $cols) =
					$message =~ /^\\033\[8;\((\d+)\);\((\d+)\)t\z/;
				my $event;
				if (defined($rows)) {
					# Reject impossible terminal dimensions
					# before passing them to ioctl.
					return if ($rows < 1 || $cols < 1 ||
						$rows > 2000 || $cols > 2000);
					$event = { rows => $rows,
					cols => $cols };
					}
				else {
					# Keep arbitrary UTF-8 keystrokes
					# separate from resize controls.
					utf8::encode($message)
						if (utf8::is_utf8($message));
					exit(1) if (length($message) > 1024 * 1024);
					$event = { data => MIME::Base64::encode_base64($message, '') };
					}
				# Keep pastes off the event loop's blocking
				# path; all input stays in memory and private
				# sockets, never in logs or command arguments.
				my $watch = !length($queued);
				$queued .= encode_json($event)."\n";
				exit(1) if (length($queued) > 4 * 1024 * 1024);
				# input_writable(handle) drains events without
				# blocking output reads.
				# Register only when input changes from empty to queued.
				$server->watch_writable($input, sub {
					my $written = syswrite($input, $queued,
						8192);
					# Leave queued input intact when the
					# worker is temporarily busy.
					return if (!defined($written) &&
					($! == EAGAIN || $! == EWOULDBLOCK ||
					$! == EINTR));
					# EOF or a permanent write failure ends
					# this terminal session.
					exit(0) if (!$written);
					substr($queued, 0, $written, '');
					$server->unwatch_writable($input)
					if (!length($queued));
					}) if ($watch);
				},
			# disconnect(client) ends the service belonging to the
			# active browser.
			disconnect => sub {
				# A rejected or second socket must not
				# disconnect the authorized user.
				exit(0) if ($connection &&
					$_[0] == $connection);
				},
		);
		},
);
Cloudmin::Relay::ready();
$server->start();
