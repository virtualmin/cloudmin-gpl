#!/usr/bin/perl
# Deliberately attempts forbidden operations inside the production sandbox.
use strict;
use warnings;
use JSON::PP qw(encode_json decode_json);
use POSIX ();
use IO::Socket::UNIX;
use Socket qw(SOCK_STREAM);
$| = 1;
die 'Probe must not run as root' if ($< == 0 || $> == 0);
open(my $input, '<', 'request.json') || die $!;
my $r = decode_json(do { local $/; <$input> });

# emit(event) Uses the production worker protocol to expose test observations.

sub emit
{
print encode_json($_[0]), "\n";
}
emit({ type => 'identity', uid => 0 + $<, euid => 0 + $> });
my $mode = $r->{'mode'} || 'access';
# Report the permissions and namespaces visible inside the sandbox.
if ($mode eq 'access') {
	my %read;
	for my $path (@{$r->{'paths'}}) {
		$read{$path} = open(my $fh, '<', $path) ? 1 : 0;
		}
	open(my $status, '<', '/proc/self/status') || die $!;
	my %status =
		map { /^([^:]+):\s*(.*?)\s*$/ ? ( $1 => $2 ) : () } <$status>;
	eval { POSIX::setuid(0); };
	my $regained = $< == 0 || $> == 0 ? 1 : 0;
	my $libvirt = eval { require Sys::Virt;
		Sys::Virt->new(uri => 'qemu:///system'); 1 } || 0;
	my $socket = IO::Socket::UNIX->new(Type => SOCK_STREAM,
					   Peer => '/run/libvirt/virtqemud-sock');
	opendir(my $fds, '/proc/self/fd') || die $!;
	my @fds = map { readlink("/proc/self/fd/$_") || '' } grep { /^\d+$/ }
		  readdir($fds);
	emit({ type => 'result',
	       data => { uid => 0 + $<, groups => "$)", read => \%read,
			 network_namespace => readlink('/proc/self/ns/net'),
			 capabilities => $status{'CapEff'},
			 bounds => $status{'CapBnd'},
			 no_new_privileges => $status{'NoNewPrivs'},
			 regained_root => $regained, libvirt => $libvirt,
			 socket => $socket ? 1 : 0,
			 environment_leaked => exists(
				 $ENV{'CLOUDMIN_FIXTURE_SECRET'}) ? 1 : 0,
			 fds => \@fds } });
	}
# Make unsafe output objects that the controller must refuse to claim.
elsif ($mode eq 'symlink' || $mode eq 'hardlink' || $mode eq 'fifo') {
	symlink('/etc/shadow', 'output') || die $! if ($mode eq 'symlink');
	link('request.json', 'output') || die $! if ($mode eq 'hardlink');
	POSIX::mkfifo('output', 0600) == 0 || die $! if ($mode eq 'fifo');
	emit({ type => 'result', data => { } });
	}
# Exceed the protocol limit without producing a valid final result.
elsif ($mode eq 'large') {
	print 'x' x 100000;
	sleep(120);
	}
# Exercise identity, response-order and output-path tampering checks.
elsif ($mode eq 'root_identity' || $mode eq 'duplicate_result' ||
       $mode eq 'redirect_events') {
	# A claimed root identity must be rejected despite the actual task UID.
	if ($mode eq 'root_identity') {
		emit({ type => 'identity', uid => 0, euid => 0 });
		}
	elsif ($mode eq 'redirect_events') {
		# The controller must keep reading its existing
		# descriptor, not this link.
		unlink('events') || die $!;
		symlink('/etc/shadow', 'events') || die $!;
		}
	emit({ type => 'result', data => { safe => 1 } });
	emit({ type => 'result',
	       data => { } }) if ($mode eq 'duplicate_result');
	}
# Create a descendant to test whole-service cancellation and recovery.
elsif ($mode eq 'children') {
	my $child = fork();
	die $! if (!defined($child));
	# Keep the child alive long enough to prove service cleanup stops it.
	if (!$child) { sleep(120); exit(0); }
	emit({ type => 'progress', phase => 'child', pid => $child });
	sleep(120);
	}
# Keep another task alive while cross-task access checks run.
elsif ($mode eq 'hold') {
	emit({ type => 'progress', phase => 'held', uid => 0 + $< });
	sleep(5);
	emit({ type => 'result', data => { uid => 0 + $< } });
	}
# Fail unknown probe modes rather than reporting an unrelated success.
else { die 'Unknown fixture'; }
