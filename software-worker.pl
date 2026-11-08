#!/usr/bin/perl
package Cloudmin::SoftwareWorker;

# Monitor guest setup from the existing unprivileged worker sandbox.
use strict;
use warnings;
use JSON::PP qw(encode_json decode_json);
use IPC::Open3;
use IO::Select;
use IO::Handle;
use Socket qw(AF_INET AF_INET6 inet_pton);
use POSIX qw(WNOHANG);
use Errno qw(EPIPE EINTR);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC sleep);

my %REASONS = map { $_ => 1 } qw(identity perl privilege cloud_init_missing
	cloud_init_timeout cloud_init_failed credentials helper);
my %STEPS = map { $_ => 1 } qw(before packages download install after);
my %STAGES =
	( %STEPS,
	  map { $_ =>
			1 } qw(boot accepted queued complete failed cancelled unavailable) );

# quote(value) quotes one fixed argument for the remote POSIX shell.

sub quote
{
my $value = $_[0];
$value =~ s/'/'"'"'/g;
return "'$value'";
}

# failure(reason) emits a fixed JSON error before private stdin is consumed.

sub failure
{
return "printf '%s\\n' ".quote(encode_json({ stage => 'failed', reason =>
									$_[0] }))."; exit 1";
}

# remote_command(username, [wait_boot]) checks guest dependencies before launch.
# wait_boot defaults to true; cancellation skips it. No prerequisite command may
# consume the credentials waiting on stdin.

sub remote_command
{
my ($username, $wait_boot) = @_;
$wait_boot = 1 if (!defined($wait_boot));
my $helper = '/usr/local/lib/cloudmin/guest-software.pl';
my $check = "/usr/bin/perl -c $helper </dev/null >/dev/null 2>&1";
my $command = '';
if ($wait_boot) {
	# Perl or individual modules may still be installing
	# when SSH becomes ready.
	$command =
		"if ! $check; then ".
		"if ! command -v cloud-init >/dev/null 2>&1; then ".
		failure('cloud_init_missing')."; fi; ".
		"printf '%s\\n' '{\"stage\":\"boot\"}'; ".
		"timeout 900 cloud-init status --wait </dev/null >/dev/null 2>&1; ".
		"case \$? in 0|2) ;; 124) ".failure('cloud_init_timeout').
		" ;; ".
		"*) ".failure('cloud_init_failed')." ;; esac; fi; ";
	}
$command .= "if ! $check; then ".failure('perl')."; fi; ".
	    "exec /usr/bin/perl $helper watch";
if ($username ne 'root') {
	# Use the account's existing passwordless sudo without
	# consuming its input.
	$command =
		"if ! sudo -n true </dev/null 2>/dev/null; then ".
		failure('privilege').
		"; fi; exec sudo -n /bin/sh -c ".quote($command);
	}
return $command;
}

# emit(value) uses the controller's existing bounded worker protocol.

sub emit
{
print encode_json($_[0]), "\n" or die "Controller disconnected\n";
STDOUT->flush;
}

# ssh_command(request) validates the target and pins only this guest's host key.

sub ssh_command
{
my ($request) = @_;
my ($address, $username, $uuid, $public) =
	@{$request}{qw(address username uuid host_public_key)};
# Accept only literal IPs and bounded guest identity fields from the controller.
die "Invalid guest address\n" if (!defined($address) ||
				  (!inet_pton(AF_INET,
					      $address) && !inet_pton(AF_INET6,
								      $address)));
die "Invalid guest identity\n" if (($username ||
				    '') !~ /\A[a-z_][a-z0-9_-]{0,31}\z/ ||
				   ($uuid || '') !~ /\A[a-f0-9-]{36}\z/);
die "Invalid guest host key\n"
	if (($public || '') !~ /\Assh-rsa [A-Za-z0-9+\/=]+(?: [^\r\n]*)?\s*\z/);
$public =~ s/\s+\z//;
# Pin identity by UUID so discovering another address does not change trust.
open(my $known, '>', 'known_hosts') || die "Cannot pin guest identity\n";
print $known "$uuid $public\n" or die "Cannot pin guest identity\n";
close($known) || die "Cannot pin guest identity\n";
# Ignore host configuration and SSH agents; credentials travel only on stdin.
return [ '/usr/bin/ssh', '-F', '/dev/null', '-T', '-i', 'identity',
	 '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes', '-o',
	 'IdentityAgent=none',
	 '-o', 'StrictHostKeyChecking=yes', '-o',
	 'UserKnownHostsFile=known_hosts',
	 '-o', 'GlobalKnownHostsFile=/dev/null', '-o', "HostKeyAlias=$uuid",
	 '-o', 'ConnectTimeout=10', '-o', 'ServerAliveInterval=15', '-o',
	 'ServerAliveCountMax=3',
	 '-o', 'ClearAllForwardings=yes', '-o', 'LogLevel=ERROR',
	 '-l', $username, '--', $address,
	 remote_command($username, ($request->{'action'} || '') ne 'cancel') ];
}

# wait_child(pid, seconds) bounds the wait after SSH closes its output.

sub wait_child
{
my ($pid, $seconds) = @_;
my $deadline = clock_gettime(CLOCK_MONOTONIC) + $seconds;
while (clock_gettime(CLOCK_MONOTONIC) < $deadline) {
	my $result = waitpid($pid, WNOHANG);
	return $? & 127 ? 128 + ($? & 127) : $? >> 8 if ($result == $pid);
	die "Cannot wait for SSH\n" if ($result == -1 && $! != EINTR);
	sleep(0.05);
	}
die "SSH exit timed out\n";
}

# monitor(command, payload, timeout) streams private input
# and known status only.

sub monitor
{
my ($command, $payload, $timeout) = @_;
open(my $null, '>', '/dev/null') || die "Cannot open worker output sink\n";
my ($input, $output);
my $pid = open3($input, $output, '>&'.fileno($null), @$command);
my ($result, $reaped);
my $ok = eval {
	# Deliver credentials once; keep reading if a prerequisite closes stdin.
	local $SIG{'PIPE'} = 'IGNORE';
	my $data = encode_json($payload);
	while (length($data)) {
		my $n = syswrite($input, $data);
		if (!defined($n)) {
			# Retry interrupted writes; a closed pipe can still
			# have a useful reply.
			next if ($! == EINTR);
			# Still read a prerequisite failure if
			# SSH closed stdin early.
			last if ($! == EPIPE);
			die "Cannot send guest request\n";
			}
		die "Cannot send guest request\n" if (!$n);
		substr($data, 0, $n, '');
		}
	close($input);
	# Read bounded status records until the guest reports a terminal result.
	my $select = IO::Select->new($output);
	my ($buffer, $stage, $step, $reason) = ('');
	my $deadline = clock_gettime(CLOCK_MONOTONIC) + $timeout;
	while (clock_gettime(CLOCK_MONOTONIC) < $deadline) {
		next if (!$select->can_read(1));
		my $n = sysread($output, my $chunk, 4096);
		if (!defined($n)) {
			# A signal can interrupt a read without
			# breaking the SSH stream.
			next if ($! == EINTR);
			die "Cannot read guest response\n";
			}
		if (!$n) {
			# Keep the reported result even if SSH then
			# exits with an error.
			my $code = wait_child($pid, 10);
			$reaped = 1;
			if (($stage ||
			     '') !~ /\A(?:complete|failed|cancelled)\z/) {
				# Retry a disconnected session that
				# gave no final result.
				$stage = $code != 0 && $code != 255
					? 'failed'
					: 'unavailable';
				$reason = $stage eq 'failed' ? 'helper' : undef;
				}
			$result =
				{ stage => $stage, failed_step => $step,
				  reason =>
					  $reason };
			last;
			}
		# Reject oversized or unterminated lines before
		# decoding guest JSON.
		$buffer .= $chunk;
		die "Invalid guest response\n" if (length($buffer) > 8192);
		while ($buffer =~ s/\A([^\n]*)\n//) {
			# Forward known states without exposing guest text.
			my $value = decode_json($1);
			$stage = $value->{'stage'};
			die "Invalid guest stage\n" if (!$STAGES{$stage || ''});
			$step = $STEPS{$value->{'failed_step'} || ''}
				? $value->{'failed_step'}
				: undef;
			$reason = $REASONS{$value->{'reason'} || ''}
				? $value->{'reason'}
				: undef;
			emit({ type => 'progress', stage => $stage });
			}
		}
	die "Guest response timed out\n" if (!$result);
	1;
	};
my $error = $@;
if (!$reaped) {
	# Ending monitoring does not stop the guest's
	# independent systemd service.
	kill('KILL', $pid);
	waitpid($pid, 0);
	}
close($output);
close($input) if (defined(fileno($input)));
close($null);
die $error if (!$ok);
return $result;
}

# run(request) confines SSH to the unprivileged software worker.

sub run
{
my ($request) = @_;
# Only the sandbox worker may open the guest connection.
die "Privileged worker\n" if ($< == 0 || $> == 0);
my $command = ssh_command($request);
my $payload = { map { $_ => $request->{$_} || '' } qw(uuid serial key action) };
return monitor($command, $payload, ($request->{'action'} || '') eq 'cancel'
	? 60
	: 7400);
}

# main() keeps request contents and arbitrary child errors out of public events.

sub main
{
umask(0077);
# Bound the saved request before parsing or sending any of its private fields.
my $ok = eval {
	open(my $fh, '<', 'request.json') || die "Cannot read worker request\n";
	my $n = read($fh, my $json, 512 * 1024 + 1);
	die "Invalid worker request\n" if (!defined($n) || $n > 512 * 1024);
	close($fh);
	emit({ type => 'result', data => run(decode_json($json)) });
	1;
	};
if (!$ok) {
	# Arbitrary failures may include private request data or child output.
	emit({ type => 'error', message =>
					'Cannot communicate with the guest installer' });
	return 1;
	}
return 0;
}

# Loading routines for protocol tests must not start an SSH connection.
exit(main()) if (!caller);
1;
