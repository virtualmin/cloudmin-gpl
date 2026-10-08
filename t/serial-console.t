use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use Test::More;
use Cloudmin::SerialConsole;

# Fake only libvirt's event registration; bytes use a real Unix socket pair.
{
	package Sys::Virt::Event;
	our (%handles, %timers, $next);
	# add_handle(fd, events, callback) records the requested event mask.
	sub add_handle { $handles{++$next} = [@_]; return $next; }
	# update_handle(id, events) replaces a watcher mask.
	sub update_handle { $handles{$_[0]}->[1] = $_[1]; }
	# remove_handle(id) releases the watcher.
	sub remove_handle { delete $handles{$_[0]}; }
	# add_timeout(ms, callback) records the idle supervision deadline.
	sub add_timeout { $timers{++$next} = [@_]; return $next; }
	# remove_timeout(id) releases the timer.
	sub remove_timeout { delete $timers{$_[0]}; }
	# run_default() permits testing errors stored by a native callback.
	sub run_default { }
	package SerialStream;
	# add_callback(self, events, callback) registers the stream watcher.
	sub add_callback { $_[0]->{'events'} = $_[1]; $_[0]->{'callback'} = $_[2]; }
	# update_callback(self, events) records when input needs writable events.
	sub update_callback { $_[0]->{'events'} = $_[1]; }
	# remove_callback(self) releases the callback reference.
	sub remove_callback { delete $_[0]->{'callback'}; }
	# abort(self) records release of the exclusive port.
	sub abort { $_[0]->{'aborted'}++; }
	# recv(self, buffer, size) returns configured guest output or would-block.
	sub recv {
		# An empty fixture behaves like an idle nonblocking libvirt stream.
		return -2 if (!length($_[0]->{'output'} || ''));
		$_[1] = delete $_[0]->{'output'};
		return length($_[1]);
		}
	# send(self, buffer, size) simulates a partial write or a busy stream.
	sub send {
		# A busy stream consumes no input; the bridge must keep it queued.
		return -2 if ($_[0]->{'busy'});
		# Accept only two bytes so tests exercise repeated partial writes.
		$_[0]->{'input'} .= substr($_[1], 0, 2);
		return length($_[1]) > 2 ? 2 : length($_[1]);
		}
}

# Browser input must reach the guest queue unchanged and enable write events.
my $stream = bless {}, 'SerialStream';
my $bridge = Cloudmin::SerialConsole->new({}, $stream);
$bridge->socket_ready(2);
sysread($bridge->handle(), my $prefix, 4);
is($prefix, pack('N', 0), 'unrecorded console sends a zero replay length');
syswrite($bridge->handle(), "hello\r");
$bridge->socket_ready(1);
is($bridge->{'to_guest'}, "hello\r", 'browser input stays byte-for-byte intact');
is($stream->{'events'}, 3, 'pending input enables stream writes');
# Would-block and partial writes must preserve input order without busy polling.
$stream->{'busy'} = 1;
$bridge->stream_ready(2);
is($bridge->{'to_guest'}, "hello\r", 'would-block retains all input');
delete $stream->{'busy'};
$bridge->stream_ready(2) for 1..3;
is($stream->{'input'}, "hello\r", 'partial sends retain byte order');
is($stream->{'events'}, 1, 'empty queue disables writable events');
# Guest output is binary data, including NUL and bytes outside ASCII.
$stream->{'output'} = "login:\0\xff";
$bridge->stream_ready(1);
$bridge->socket_ready(2);
sysread($bridge->handle(), my $received, 100);
is($received, "login:\0\xff", 'guest bytes reach the relay without decoding');
# Socket closure must leave the event callback normally and fail in the pump.
close($bridge->handle());
$bridge->socket_ready(1);
ok(!eval { $bridge->pump(); 1 }, 'socket EOF ends supervision');
like($@, qr/disconnected/, 'EOF is reported outside the event callback');
# Repeated cleanup must release every watcher and the exclusive port only once.
$bridge->close();
$bridge->close();
is($stream->{'aborted'}, 1, 'cleanup aborts the stream exactly once');
is(scalar(keys %Sys::Virt::Event::handles), 0, 'cleanup removes socket watchers');
is(scalar(keys %Sys::Virt::Event::timers), 0, 'cleanup removes timers');
ok(!$stream->{'callback'}, 'cleanup releases stream callback');

# A stalled guest must not let browser input build an unbounded queue.
$bridge = Cloudmin::SerialConsole->new({}, bless({}, 'SerialStream'));
$bridge->{'to_guest'} = 'a' x (1024 * 1024 + 1);
ok(!eval { $bridge->update(); 1 }, 'stalled peers cannot build unbounded buffers');
$bridge->close();

# A recorded session follows one log cursor while still draining the PTY.
{
	package SerialHistory;
	# history(self) supplies output produced before the browser connected.
	sub history { return "login: tester"; }
	# read(self) supplies the next recorded bytes once.
	sub read { return delete($_[0]->{'output'}) || ''; }
}
$stream = bless {output => 'duplicate PTY bytes'}, 'SerialStream';
my $history = bless {output => "\r\nwelcome\r\n"}, 'SerialHistory';
$bridge = Cloudmin::SerialConsole->new({}, $stream, $history);
$bridge->stream_ready(1);
$bridge->pump();
$bridge->socket_ready(2);
sysread($bridge->handle(), $received, 100);
is($received, pack('N', 13)."login: tester\r\nwelcome\r\n",
	'history and live log bytes arrive once, in order, after the length prefix');
is($stream->{'input'} || '', '', 'replay sends no guest input');
ok(!exists($stream->{'output'}), 'recorded sessions still drain the PTY');
$bridge->pump();
is($bridge->{'to_browser'}, '', 'idle history does not repeat old bytes');
$bridge->close();
done_testing();
