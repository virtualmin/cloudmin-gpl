# Privileged setup and cleanup for isolated interactive relays. The systemd
# service handles WebSocket frames; its supervisor also forwards serial bytes.
use strict;
use warnings;
use File::Temp qw(tempfile);
use IO::Socket::INET;
use IO::Select;
use IPC::Open3 qw(open3);
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);
# Declare Webmin's cache to avoid a one-use warning on its qualified reference.
our $readonly_mode_cache;
our ($module_name, $module_var_directory, $module_root_directory,
     $session_id);

# run_interactive_relay(port, unit, command, [graphics], [authorized],
#                       [connected], [finished])
# Binds the proxy listener, starts a fresh service and waits for readiness.
# command(credential_path) returns systemd-run arguments. Only a console gets a
# guest byte descriptor; the SSH terminal gets only its listener. The setup
# parent exits on readiness; the supervisor stays to clean up the service.
# authorized(), when supplied, confirms the session and current guest grant. A
# false return or exception stops the service and removes its proxy route.
# graphics is an optional guest byte socket, or a no-argument factory returning
# a transport with handle(), pump() and close() methods. The factory opens
# streams only in the forked supervisor; pump() must not block supervision.
# connected() handles the SSH worker's authenticated event once, when supplied.
# finished() records the final outcome after relay cleanup, when supplied.
# Neither callback receives guest output; the caller retains validated settings.

sub run_interactive_relay
{
my ($port, $unit, $command, $graphics, $authorized, $connected,
    $finished) = @_;
# The dedicated supervisor must still remove its route after ACL revocation.
local $main::readonly_mode_cache = 0;
# Validate controller-supplied identity and route data before opening sockets.
die "Invalid relay launch\n" if (!$session_id || length($session_id) > 256 ||
				 $session_id =~ /\s/ || $port !~ /\A\d{1,5}\z/ ||
				 $port < 1 || $port > 65535 ||
				 $unit !~ /\Acloudmin-(?:console|terminal)-[a-f0-9]{32}\z/);
my $listener = IO::Socket::INET->new(Listen => 5, LocalAddr => '127.0.0.1',
				     LocalPort => $port, Proto => 'tcp',
				     ReuseAddr => 1) ||
	       die "Cannot listen for the relay: $!\n";
my ($file, $credential) = tempfile('relay-XXXXXXXX',
				   DIR => $module_var_directory, UNLINK => 0);
my ($reader, $writer, $child);
my $prepared = eval {
	# The credential stays private until systemd copies it into the service.
	print $file $session_id or die "Cannot write relay credentials: $!\n";
	close($file) or die "Cannot close relay credentials: $!\n";
	pipe($reader, $writer) ||
		die "Cannot create relay startup channel: $!\n";
	$child = fork();
	die "Cannot start relay supervisor: $!\n" if (!defined($child));
	1;
	};
if (!$prepared) {
	# A launch that never forked has no supervisor to remove its credential.
	my $error = $@;
	unlink($credential);
	die $error;
	}
if ($child) {
	# Do not return a working URL until the isolated process is listening.
	close($writer);
	close($listener);
	my $result = '';
	my $readable = IO::Select->new($reader)->can_read(25);
	my $ready = $readable &&
		    sysread($reader, $result, 1) && $result eq '1';
	close($reader);
	if (!$ready) {
		# The supervisor owns service and proxy
		# cleanup on failed startup.
		kill('TERM', $child) if (!$readable);
		waitpid($child, 0);
		die "Cannot start isolated relay; check the session log\n";
		}
	exit(0);
	}
close($reader);
untie(*STDIN);
open(STDIN, '<', '/dev/null') || die "Cannot detach relay supervisor\n";
my ($pid, $transport);
my $ok = eval {
	# stopped(signal) sends interrupted startup through the
	# normal cleanup path.
	local $SIG{'TERM'} = sub { die "Relay supervisor stopped\n"; };
	local $SIG{'INT'} = $SIG{'TERM'};
	local $SIG{'HUP'} = $SIG{'TERM'};
	# expired(signal) bounds supervision even if the
	# service stops responding.
	local $SIG{'ALRM'} = sub { die "Relay lifetime exceeded\n"; };
	local $SIG{'PIPE'} = 'IGNORE';
	local $SIG{'CHLD'} = 'DEFAULT';
	alarm(8 * 3600 + 60);
	if (ref($graphics) eq 'CODE') {
		# Serial streams stay in this process; the sandbox
		# gets their byte socket.
		$transport = $graphics->();
		$graphics = $transport->handle();
		}
	# This socket carries diagnostics across the systemd/SELinux boundary,
	# separately from the console's guest byte socket.
	socketpair(my $errors, my $child_errors, AF_UNIX, SOCK_STREAM,
		   PF_UNSPEC) ||
		die "Cannot create relay diagnostic channel: $!\n";
	open(my $null, '+<', '/dev/null') ||
		die "Cannot open relay output: $!\n";
	socketpair(my $handoff, my $child_handoff, AF_UNIX, SOCK_STREAM,
		   PF_UNSPEC) || die "Cannot create relay socket handoff: $!\n";
	my @args = $command->($credential);
	{
		# A new service gets no CGI environment, Webmin
		# memory or extra handles.
		local %ENV =
			( PATH => '/usr/sbin:/usr/bin:/sbin:/bin',
			  LANG => 'C' );
		$pid = open3('<&'.fileno($child_handoff),
			     '>&'.fileno($null),
			     '>&'.fileno($child_errors), @args);
		}
	close($child_errors);
	close($child_handoff);
	# Python's standard library supplies SCM_RIGHTS; Perl has no core API
	# for it. Passing directly avoids systemd's restrictions
	# on inherited sockets.
	my $sender;
	{
		local %ENV = ( PATH => '/usr/bin:/bin', LANG => 'C' );
		$sender = open3('<&'.fileno($listener),
				'>&'.fileno($graphics || $null),
				'>&'.fileno($handoff),
				'/usr/bin/python3',
				"$module_root_directory/relay-sockets.py",
				'send', $graphics ? 2 : 1);
		}
	waitpid($sender, 0);
	die "Cannot hand sockets to the relay\n" if ($?);
	close($handoff);
	close($listener);
	close($graphics) if ($graphics);
	my ($buffer, $ready, $logged) = ( '', 0, 0 );
	my $events = '';
	my $last_access_check = 0;
	my $readable = IO::Select->new($errors);
	# Poll diagnostics so a quiet relay still rechecks
	# permissions every five seconds.
	while (1) {
		if ($authorized && time() - $last_access_check >= 5) {
			# Logout, removed VM assignments and revoked
			# grants stop the service.
			die "Interactive access has been revoked\n"
				if (!$authorized->());
			$last_access_check = time();
			}
		# Serial pumping waits at most 100 ms; other relays poll once a
		# second. EOF on the diagnostic socket means the
		# service has closed it.
		$transport->pump() if ($transport);
		next if (!$readable->can_read($transport ? 0 : 1));
		last if (!sysread($errors, my $bytes, 4096));
		if (!$ready) {
			# The fixed readiness line is emitted before
			# browser callbacks run.
			$buffer .= $bytes;
			# Keep the newline ending any earlier diagnostic, so the
			# next event still starts its own line.
			if ($buffer =~ s/(\A|\n)Cloudmin relay ready\n/$1/) {
				# systemd now holds its private copy; release
				# the source and caller.
				$ready = 1;
				unlink($credential);
				syswrite($writer, '1');
				close($writer);
				}
			die "Relay startup failed: $buffer\n"
				if (length($buffer) > 8192);
			$bytes = $ready ? $buffer : '';
			$buffer = '' if ($ready);
			}
		if ($connected) {
			# Read complete diagnostic lines; terminal output
			# uses another socket.
			$events .= $bytes;
			$bytes = '';
			while ($events =~ s/\A([^\n]*\n)//) {
				my $line = $1;
				if ($line eq "Cloudmin SSH authenticated\n") {
					# Handle authentication once per relay,
					# even if its event repeats.
					$connected->() if (ref($connected) eq 'CODE');
					$connected = 1;
					}
				else {
					# Keep ordinary diagnostics
					# available in the session log.
					$bytes .= $line;
					}
				}
			# A malformed diagnostic stream cannot
			# grow without a newline.
			die "Relay diagnostic line is too long\n"
				if (length($events) > 8192);
			}
		# Bound session logs even if a failed service
		# emits repeated errors.
		if (length($bytes) && $logged < 65536) {
			my $message = substr($bytes, 0, 65536 - $logged);
			print STDERR $message;
			$logged += length($message);
			}
		}
	die "Relay startup failed: $buffer\n" if (!$ready);
	waitpid($pid, 0);
	$pid = undef;
	1;
	};
my $error = $@;
alarm(0);
# Release the serial port even when startup or a permission check failed.
$transport->close() if ($transport);
# Stop the whole service, including SSH descendants, before releasing its route.
# An already-collected unit needs no stop, but an active one must not survive.
system('/usr/bin/systemctl', 'stop', "$unit.service") if ($pid);
if ($pid) {
	# Reap the systemd-run launcher after stopping its service.
	kill('TERM', $pid);
	waitpid($pid, 0);
	}
unlink($credential) if (-e $credential);
eval { remove_miniserv_websocket($port, $module_name); };
close($writer) if (defined(fileno($writer)));
# Preference failures must not prevent cleanup or obscure a relay error.
if ($finished) {
	eval { $finished->(); };
	warn "Cannot save relay outcome: $@" if ($@);
	}
die $error if (!$ok);
exit(0);
}

1;
