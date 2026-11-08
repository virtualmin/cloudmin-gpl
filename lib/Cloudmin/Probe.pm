package Cloudmin::Probe;

# Guest probes run in short-lived children so a stuck native call cannot stall
# the shared status collector or the next guest's probe.
use strict;
use warnings;
use IO::Select;
use WebminCore qw(convert_to_json convert_from_json);
use POSIX qw(_exit WNOHANG);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);

# run(callback, timeout) Returns a JSON-compatible probe result, or an error
# after the time/size limit. Call only from the probe supervisor, before it
# opens any libvirt connection.
sub run
{
my ($callback, $timeout) = @_;
# Reap a child whose exit completed just after the previous bounded cleanup.
1 while (waitpid(-1, WNOHANG) > 0);
pipe(my $reader, my $writer) || return { error => 1 };
my $pid = fork();
return { error => 1 } if (!defined($pid));
# The child runs native calls independently of the supervisor deadline.
if (!$pid) {
	close($reader);
	$SIG{$_} = 'DEFAULT' foreach qw(TERM INT HUP ALRM CHLD);
	my $result = eval { $callback->() } || { error => 1 };
	my $bytes = eval { convert_to_json($result, 0, 1) } || '{"error":1}';
	print $writer $bytes;
	close($writer);
	_exit(0);
	}
close($writer);
# stop(): kill and reap this probe without waiting indefinitely for exit.
my $stop = sub {
	kill('KILL', $pid);
	for (1 .. 10) {
		last if (waitpid($pid, WNOHANG) != 0);
		Time::HiRes::sleep(0.01);
		}
	};
# The supervisor must also release its child when the collector stops it.
local $SIG{$_} = sub { $stop->(); _exit(0); } foreach qw(TERM INT HUP);
my $select = IO::Select->new($reader);
# Read a bounded JSON reply using the monotonic deadline.
my $deadline = clock_gettime(CLOCK_MONOTONIC) + $timeout;
my ($bytes, $finished) = ( '', 0 );
while (length($bytes) <= 1024 * 1024) {
	my $remaining = $deadline - clock_gettime(CLOCK_MONOTONIC);
	last if ($remaining <= 0);
	next if (!$select->can_read($remaining > 1 ? 1 : $remaining));
	my $length = sysread($reader, my $chunk, 65536);
	last if (!defined($length));
	# EOF marks a complete reply; a timeout or read failure does not.
	if (!$length) { $finished = 1; last; }
	$bytes .= $chunk;
	}
close($reader);
$stop->();
return { error => 1 } if (!$finished);
my $result = eval { convert_from_json($bytes) };
return ref($result) eq 'HASH' ? $result : { error => 1 };
}

1;
