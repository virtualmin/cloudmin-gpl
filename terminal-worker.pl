#!/usr/bin/perl
# Own the SSH terminal inside its unprivileged systemd service.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/..", "$Bin/../vendor_perl";
use IO::Select;
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use Errno qw(EAGAIN EWOULDBLOCK EINTR);
use WebminCore qw(convert_from_json);
use MIME::Base64 qw(decode_base64);
use POSIX qw(setsid WNOHANG);
use File::Temp qw(tempdir);
# The relay must enter through the restricted unit, with SSH
# as its sole command.
die "SSH terminals must run without root privileges\n" if ($< == 0 || $> == 0);
die "Invalid terminal command\n" if (!@ARGV || $ARGV[0] ne '/usr/bin/ssh');

# OpenSSH creates this private marker only after host verification and login.
# Guest output stays on the PTY and cannot supply the supervisor's event. The
# fixed local command writes only within the service's private /tmp.
# EscapeChar=none in the launcher prevents interactive local command escapes.
my $success_dir = tempdir('cloudmin-ssh-XXXXXXXX', DIR => '/tmp', CLEANUP => 1);
my $success_file = "$success_dir/authenticated";
splice(@ARGV, 1, 0, '-o', 'PermitLocalCommand=yes',
       '-o', "LocalCommand=/usr/bin/touch $success_file");

# Session credentials exist in both login modes. Only key login may load the
# additional private key; password login must not require or receive one.
if ($ENV{'CLOUDMIN_TERMINAL_KEY'}) {
	die "The virtual machine SSH key is unavailable\n"
		if (!$ENV{'CREDENTIALS_DIRECTORY'});
	my $key = $ENV{'CREDENTIALS_DIRECTORY'}.'/ssh-key';
	# systemd grants access through an ACL; a mode-bit check can reject it.
	open(my $key_file, '<', $key) ||
		die "The virtual machine SSH key is unavailable\n";
	close($key_file);
	splice(@ARGV, 1, 0, '-i', $key);
	}

# Reuse Webmin's Linux PTY helper without initializing Webmin or reading its
# protected configuration. The process library also checks for strace at load.
{
	package CloudminTerminalPTY;
	use WebminCore qw(has_command error);
	require "$FindBin::Bin/../proc/linux-lib.pl";
	}
my ($pty, undef, undef, $ttyname) = CloudminTerminalPTY::get_new_pty();
die "Cannot allocate SSH terminal\n" if (!$pty);
my $pid = fork();
die "Cannot start SSH\n" if (!defined($pid));
if (!$pid) {
	# Give SSH its own controlling terminal for password
	# prompts and resizing.
	setsid() >= 0 || die "Cannot create SSH session\n";
	open(my $tty, '+<', $ttyname) || die "Cannot open SSH terminal: $!\n";
	ioctl($tty, 0x540e, 0) || die "Cannot attach SSH terminal: $!\n";
	close($pty);
	open(STDIN, '<&', $tty) || die "Cannot open terminal input\n";
	open(STDOUT, '>&', $tty) || die "Cannot open terminal output\n";
	open(STDERR, '>&', $tty) || die "Cannot open terminal errors\n";
	close($tty);
	exec { $ARGV[0] } @ARGV;
	die "Cannot execute SSH\n";
	}
binmode(STDIN);
binmode(STDOUT);
my $owner = $$;

END
{
# Closing the browser's pipe must not leave the guest login running.
if ($owner && $$ == $owner && $pid) {
	kill('TERM', $pid);
	waitpid($pid, WNOHANG);
	}
}
# signal(name) exits through END so the local SSH child is terminated.
$SIG{$_} = sub { exit(0); } for qw(TERM INT HUP);
my $readers = IO::Select->new(\*STDIN, $pty);
my $writers = IO::Select->new();
my $pending = '';
my %queued;
my $finished;
my $authenticated;
# Drain output while accepting pasted input, so a full PTY cannot deadlock SSH.
foreach my $handle ( $pty, \*STDOUT ) {
	my $flags = fcntl($handle, F_GETFL, 0);
	defined($flags) && fcntl($handle, F_SETFL, $flags | O_NONBLOCK) ||
		die "Cannot configure terminal channel\n";
	}

# queue_bytes(handle, bytes) bounds pending traffic without logging its content.
sub queue_bytes
{
my ($handle, $bytes) = @_;
my $buffer = \$queued{fileno($handle)};
$$buffer .= $bytes;
# Stop a stalled peer from consuming unbounded service memory.
die "Terminal traffic is too large\n" if (length($$buffer) > 4 * 1024 * 1024);
$writers->add($handle);
}

while (1) {
	# Wake while login is pending so a silent session still reports success.
	my ($readable, $writable) = IO::Select->select($readers, $writers,
						       undef, $authenticated
							       ? undef
							       : 1);
	if (!$authenticated && -f $success_file) {
		# Report once on the private diagnostics channel,
		# even for a quiet login.
		$authenticated = 1;
		unlink($success_file);
		my $message = "Cloudmin SSH authenticated\n";
		syswrite(STDERR, $message);
		}
	foreach my $handle (@{$writable || [ ]}) {
		# Partial writes stay queued while reads and
		# terminal resizes continue.
		my $buffer = \$queued{fileno($handle)};
		my $written = syswrite($handle, $$buffer, 8192);
		# Temporary backpressure keeps the buffer for the
		# next writable event.
		next if (!defined($written) &&
			 ($! == EAGAIN || $! == EWOULDBLOCK || $! == EINTR));
		# A broken channel cannot carry the rest of this session.
		exit(0) if (!$written);
		substr($$buffer, 0, $written, '');
		# An empty queue no longer needs writable notifications.
		$writers->remove($handle) if (!length($$buffer));
		}
	# EOF from SSH is final only after its remaining
	# output has been delivered.
	exit(0) if ($finished && !$writers->count());
	foreach my $handle (@{$readable || [ ]}) {
		my $length = sysread($handle, my $bytes, 8192);
		# A readable notification does not guarantee the
		# next read will succeed.
		next if (!defined($length) &&
			 ($! == EAGAIN || $! == EWOULDBLOCK || $! == EINTR));
		if (!$length) {
			# Parent EOF ends the session; SSH EOF first
			# flushes the final output.
			exit(0) if (fileno($handle) != fileno($pty));
			$readers->remove($pty);
			$writers->remove($pty);
			$finished = 1;
			exit(0) if (!$writers->count());
			next;
			}
		if (fileno($handle) == fileno($pty)) {
			# SSH output is a byte stream, including
			# terminal control sequences.
			queue_bytes(\*STDOUT, $bytes);
			next;
			}
		# Bound incomplete input frames; the parent
		# separately limits keystrokes.
		$pending .= $bytes;
		die "Terminal input is too large\n"
			if (length($pending) > 2 * 1024 * 1024);
		while ($pending =~ s/\A([^\n]*)\n//) {
			my $event = eval { convert_from_json($1) };
			# Reject malformed framing before touching the
			# PTY or its dimensions.
			die "Invalid terminal input\n"
				if (ref($event) ne 'HASH');
			if (defined($event->{'data'}) &&
			    !ref($event->{'data'})) {
				# Only the parent supplies this base64 framing,
				# never an SSH command.
				queue_bytes($pty,
					    decode_base64($event->{'data'}));
				}
			elsif (($event->{'rows'} || '') =~ /\A\d{1,4}\z/ &&
			       ($event->{'cols'} || '') =~ /\A\d{1,4}\z/ &&
			       $event->{'rows'} > 0 &&
			       $event->{'rows'} <= 2000 &&
			       $event->{'cols'} > 0 &&
			       $event->{'cols'} <= 2000) {
				# SSH forwards the updated terminal
				# dimensions to the guest.
				ioctl($pty, 0x5414,
				      pack('s4', $event->{'rows'},
					   $event->{'cols'}, 0, 0)) ||
					die "Cannot resize SSH terminal\n";
				kill('WINCH', $pid);
				}
			else {
				# Unknown events must not reach ioctl
				# with unchecked values.
				die "Invalid terminal dimensions\n";
				}
			}
		}
	}
