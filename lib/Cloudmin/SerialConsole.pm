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

1;
