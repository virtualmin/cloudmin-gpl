package Cloudmin::SerialConsole;

# Bridge one authorized libvirt stream to the isolated WebSocket relay. This
# supervisor handles only bounded byte buffers, never browser protocol frames.
use strict;
use warnings;
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use Errno qw(EAGAIN EWOULDBLOCK EINTR);

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

1;
