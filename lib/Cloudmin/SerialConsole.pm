package Cloudmin::SerialConsole;

# Bridge one authorized libvirt stream to the isolated WebSocket relay. This
# supervisor handles only bounded byte buffers, never browser protocol frames.
use strict;
use warnings;
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use Errno qw(EAGAIN EWOULDBLOCK EINTR);

# new(class, adapter, stream, [history_reader])
# Bridges an already-authorized stream and retains its libvirt adapter until
# close(). Register libvirt's default event loop before opening the stream.
# An optional history_reader supplies both the replay and subsequent log output;
# without one, output comes directly from the PTY.
sub new
{
my ($class, $adapter, $stream, $history) = @_;
my $replay = $history ? $history->history() : '';
# A length prefix lets the browser suppress terminal replies during replay.
my $self = bless { adapter => $adapter, stream => $stream,
	history => $history, to_guest => '',
	to_browser => pack('N', length($replay)).$replay }, $class;
my $ok = eval {
	# Give the relay a byte socket; keep the management stream in this process.
	socketpair(my $relay, my $peer, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
		|| die "Cannot create serial console channel: $!\n";
	$self->{'handle'} = $relay;
	$self->{'peer'} = $peer;
	# A slow relay must not block the supervisor's event loop or access checks.
	my $flags = fcntl($peer, F_GETFL, 0);
	defined($flags) && fcntl($peer, F_SETFL, $flags | O_NONBLOCK)
		|| die "Cannot configure serial console channel: $!\n";
	# Forward each callback's readiness mask to its bounded I/O handler.
	$self->{'watch'} = Sys::Virt::Event::add_handle(fileno($peer), 1,
		sub { $self->socket_ready($_[2]); });
	$stream->add_callback(1, sub { $self->stream_ready($_[1]); });
	$self->{'stream_watch'} = 1;
	# Wake the idle event loop every 100 ms for route cleanup and access checks.
	$self->{'timer'} = Sys::Virt::Event::add_timeout(100, sub { });
	# Send the replay prefix even when no live output is available.
	$self->update();
	1;
	};
if (!$ok) {
	# Failed setup must release libvirt's exclusive console lock as well.
	my $error = $@;
	$self->close();
	die $error;
	}
return $self;
}

# handle(self) returns the only descriptor given to the unprivileged relay.
sub handle { return $_[0]->{'handle'}; }

# update(self) enables writes only while bytes are queued and bounds memory.
sub update
{
my ($self) = @_;
# Disconnect slow peers before either direction can grow an unbounded queue.
die "Serial console buffer limit exceeded\n" if
	(length($self->{'to_guest'}) > 1024 * 1024 ||
	 length($self->{'to_browser'}) > 1024 * 1024);
# Always watch reads (1); watch writes (2) only until their queue is drained.
# Watching an idle writable socket would keep the event loop busy.
Sys::Virt::Event::update_handle($self->{'watch'},
	1 | (length($self->{'to_browser'}) ? 2 : 0));
$self->{'stream'}->update_callback(
	1 | (length($self->{'to_guest'}) ? 2 : 0));
}

# socket_ready(self, events) transfers raw bytes to/from the relay's socket.
# events is libvirt's readable/writable/error/hangup bitmask (1/2/4/8).
sub socket_ready
{
my ($self, $events) = @_;
my $ok = eval {
	my $peer = $self->{'peer'};
	if ($events & 1) {
		# EOF means the browser relay has closed; do not keep the port locked.
		my $count = sysread($peer, my $bytes, 65536);
		die "Serial console disconnected\n" if (defined($count) && !$count);
		# Retry interrupted reads or temporary lack of data on a later event.
		die "Cannot read serial console channel: $!\n" if
			(!defined($count) && $! != EAGAIN && $! != EWOULDBLOCK && $! != EINTR);
		$self->{'to_guest'} .= $bytes if ($count);
		}
	if ($events & 2 && length($self->{'to_browser'})) {
		# Keep unsent bytes when the browser is slower than the guest.
		my $count = syswrite($peer, $self->{'to_browser'}, 65536);
		die "Serial console disconnected\n" if (defined($count) && !$count);
		# Temporary write failures leave the queued bytes intact for retry.
		die "Cannot write serial console channel: $!\n" if
			(!defined($count) && $! != EAGAIN && $! != EWOULDBLOCK && $! != EINTR);
		substr($self->{'to_browser'}, 0, $count, '') if ($count);
		}
	# Error and hangup events end the session even without readable data.
	die "Serial console disconnected\n" if ($events & (4 | 8));
	$self->update();
	1;
	};
# Do not throw through libvirt's C event dispatcher; pump() reports the failure.
$self->{'error'} ||= $@ if (!$ok);
}

# stream_ready(self, events) transfers bytes without interpreting guest output.
# events uses the same readiness bits as socket_ready().
sub stream_ready
{
my ($self, $events) = @_;
my $ok = eval {
	my $stream = $self->{'stream'};
	if ($events & 1) {
		# Libvirt returns -2 for a transient lack of data on nonblocking streams.
		my $count = $stream->recv(my $bytes, 65536);
		die "Serial console closed\n" if ($count == 0 || $count == -1);
		# Recorded sessions use one output cursor for history and live bytes.
		# Drain the PTY as well so it cannot block the guest or duplicate output.
		$self->{'to_browser'} .= $bytes if ($count > 0 && !$self->{'history'});
		}
	if ($events & 2 && length($self->{'to_guest'})) {
		# Send at most one chunk per event so ACL checks cannot be starved.
		my $bytes = substr($self->{'to_guest'}, 0, 65536);
		my $count = $stream->send($bytes, length($bytes));
		die "Cannot write serial console\n" if ($count == 0 || $count == -1);
		# Keep unwritten bytes, including all input on would-block (-2).
		substr($self->{'to_guest'}, 0, $count, '') if ($count > 0);
		}
	# A closed guest port must release the browser relay and its proxy route.
	die "Serial console closed\n" if ($events & (4 | 8));
	$self->update();
	1;
	};
# Defer callback errors until pump() returns from libvirt's C dispatcher.
$self->{'error'} ||= $@ if (!$ok);
}

# pump(self) advances serial I/O once, waiting at most 100 ms when idle.
sub pump
{
my ($self) = @_;
if ($self->{'history'}) {
	# Poll regular files with the idle timer; readiness watches would spin.
	$self->{'to_browser'} .= $self->{'history'}->read();
	$self->update();
	}
Sys::Virt::Event::run_default();
die $self->{'error'} if ($self->{'error'});
}

# close(self) releases event callbacks, descriptors and the exclusive stream.
# It is safe to call after partial startup or more than once.
sub close
{
my ($self) = @_;
# Remove only registered watches; partial startup may not have created them all.
eval { Sys::Virt::Event::remove_timeout(delete $self->{'timer'}); }
	if (defined($self->{'timer'}));
eval { Sys::Virt::Event::remove_handle(delete $self->{'watch'}); }
	if (defined($self->{'watch'}));
eval { $self->{'stream'}->remove_callback(); }
	if (delete $self->{'stream_watch'});
# Abort releases the port's exclusive lock before dropping the connection.
eval { $self->{'stream'}->abort(); } if ($self->{'stream'});
delete $self->{'stream'};
delete $self->{'adapter'};
# Release the private log handle along with the exclusive console stream.
delete $self->{'history'};
foreach my $name (qw(handle peer)) {
	# The handoff already closed handle on successful startup.
	close($self->{$name}) if ($self->{$name} && defined(fileno($self->{$name})));
	delete $self->{$name};
	}
}

1;
