#!/usr/bin/perl
# Checks real UID separation, denied access, hostile output and process cleanup.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use Fcntl qw(F_SETFD);
use JSON::PP qw(encode_json decode_json);
use Digest::SHA qw(sha256_hex);
use MIME::Base64 qw(encode_base64);
die 'Disposable Linux VM as root only' if ($^O ne 'linux' || $< != 0);
require "$Bin/../../lib/Cloudmin/Worker.pm";
$| = 1;

{
	package ProbeWorker;
	our @ISA = ('Cloudmin::Worker');

	# command(self, task, id, [limit]) Uses the production policy with a
	# hostile test program.
	sub command
	{
	my ($self, $task, $id, $limit) = @_;
	my @args = $self->SUPER::command($task, $id, $limit);
	$args[-1] = "$FindBin::Bin/worker-probe.pl";
	@args = map { /^RuntimeMaxSec=/ &&
		$self->{'short_timeout'} ? 'RuntimeMaxSec=2' : $_ } @args;
	return @args;
	}
	}

my $tmp = tempdir('/tmp/cloudmin-worker-check-XXXXXX', CLEANUP => 1);
my $runner = Cloudmin::Worker->new();
my $probe = ProbeWorker->new();
my @ids;
# started(id) records task identities for the final
# private-state cleanup checks.
my $started = sub { push(@ids, $_[0]); };

# A real open root descriptor and environment canary must not reach the service.
open(my $secret, '>', "$tmp/root-canary") || die $!;
print($secret 'private fixture'); close($secret);
chmod(0600, "$tmp/root-canary");
open($secret, '<', "$tmp/root-canary") || die $!;
fcntl($secret, F_SETFD, 0) || die $!;
local $ENV{'CLOUDMIN_FIXTURE_SECRET'} = 'private fixture';
my @paths = ( "$tmp/root-canary", '/etc/shadow', '/etc/webmin/miniserv.users',
	      '/var/webmin/modules/server-manager/image-jobs/form-key' );
my $r = $probe->run('keys', { paths => \@paths }, started => $started);
ok($r->{'uid'} > 0, 'worker has an unprivileged UID');
is($r->{'capabilities'}, '0000000000000000',
   'worker has no effective Linux capabilities');
is($r->{'bounds'}, '0000000000000000', 'worker cannot regain capabilities');
is($r->{'no_new_privileges'}, '1',
   'setuid executables cannot elevate the worker');
ok(!$r->{'regained_root'}, 'setuid to root is denied');
ok(!$r->{'libvirt'} && !$r->{'socket'},
   'system libvirt control is inaccessible');
ok(!$r->{'environment_leaked'}, 'controller environment is not inherited');
ok(!grep(/root-canary/, @{$r->{'fds'}}),
   'open root file descriptors are not inherited');
ok(!$r->{'read'}->{$_}, "worker cannot read $_") for @paths;

# Inspect every task's actual policy, including KVM access and online workers.
my $host_network = readlink('/proc/self/ns/net');
for my $task (qw(image local_image inspect seed keys size)) {
	my $policy =
		$probe->run($task, { paths => \@paths, limit => 16 * 1024**2 },
			    started => $started);
	ok($policy->{'uid'} > 0 && $policy->{'capabilities'}
	   eq '0000000000000000' &&
	   $policy->{'bounds'} eq '0000000000000000' &&
	   $policy->{'no_new_privileges'} eq '1',
	   "$task has no root identity or capabilities");
	ok(!$policy->{'libvirt'} && !$policy->{'socket'} &&
	   !grep({ $policy->{'read'}->{$_} } @paths),
	   "$task cannot access controller secrets or libvirt");
	# Download and size tasks need host networking to reach publishers.
	if ($task eq 'image' || $task eq 'size') {
		is($policy->{'network_namespace'}, $host_network,
		   "$task can use the host network for HTTPS");
		}
	# All other task types must have no access to the
	# host network namespace.
	else {
		isnt($policy->{'network_namespace'}, $host_network,
		     "$task has a separate network namespace");
		}
	}

# Concurrent tasks must not share an identity or see each other's inputs.
my $child = fork();
die $! if (!defined($child));
# Hold one task open while the parent probes cross-task file access.
if (!$child) {
	my $held = $probe->run('keys', { mode => 'hold' },
			       contents => { canary => 'private job' },
			       started => sub { open(my $fh, '>',
						     "$tmp/held-id") || die $!;
			print($fh $_[0]); close($fh); },
			       progress => sub {
			# Publish the live worker UID only after the
			# hold probe is running.
			if (($_[0]->{'phase'} || '') eq 'held') {
				open(my $fh, '>', "$tmp/held-uid") ||
					die $!; print($fh $_[0]->{'uid'}); close($fh);
				}
			});
	exit(0);
	}
my $deadline = time() + 10;
select(undef, undef, undef,
       0.1) while (!-s "$tmp/held-uid" && time() < $deadline);
open(my $fh, '<', "$tmp/held-id") || die 'Concurrent worker did not start';
my $held_id = do { local $/; <$fh> }; close($fh);
open($fh, '<', "$tmp/held-uid") || die $!;
my $held_uid = do { local $/; <$fh> }; close($fh);
my $other = "/var/lib/cloudmin-workers/$held_id/canary";
$r = $probe->run('keys', { paths => [ $other ] }, started => $started);
isnt($r->{'uid'}, $held_uid, 'concurrent workers have different UIDs');
ok(!$r->{'read'}->{$other}, 'another worker cannot read the active task input');
waitpid($child, 0);
is($?, 0, 'concurrent worker finishes normally');

# Do not follow any filesystem objects supplied by a compromised worker.
for my $mode (qw(symlink hardlink fifo large)) {
	my $ok = eval { $probe->run('keys', { mode => $mode },
				    output => "$tmp/claimed",
				    started => $started); 1 };
	ok(!$ok, "$mode output is rejected");
	ok(!-e "$tmp/claimed", "$mode cannot create privileged output");
	}
for my $mode (qw(root_identity duplicate_result)) {
	ok(!eval { $probe->run('keys', { mode => $mode }, started => $started);
		1 },
	   "$mode protocol violation is rejected");
	}
ok($probe->run('keys', { mode => 'redirect_events' },
	       started => $started)->{'safe'},
   'replacing the event path cannot redirect a privileged read');

# Cancellation and service deadlines must kill tool descendants as well.
for my $timeout ( 0, 1 ) {
	my $pid;
	local $probe->{'short_timeout'} = $timeout;
	my $ok = eval {
		$probe->run('keys', { mode => 'children' }, started => $started,
			    progress => sub {
				# Capture the descendant PID before injecting
				# cancellation or waiting.
				if (($_[0]->{'phase'} || '') eq 'child') {
					$pid = $_[0]->{'pid'};
					die "Fixture cancelled\n" if (!$timeout);
					}
				});
		1;
		};
	ok(!$ok && $pid,
	   $timeout
		   ? 'timeout stops a running task'
		   : 'cancellation stops a running task');
	my $running = 0;
	# A remaining zombie entry does not mean the
	# descendant is still running.
	if (open(my $stat, '<', "/proc/$pid/stat")) {
		my $line = <$stat>;
		$running = $line !~ /\) Z /;
		}
	ok(!$running, 'external tool descendant cannot survive cleanup');
	}

# Recovery must stop tasks whose root job process died and
# remove private inputs.
my $coordinator = fork();
die $! if (!defined($coordinator));
# Leave a live task behind when this fixture's root process is killed.
if (!$coordinator) {
	$probe->run('keys', { mode => 'children' }, started => sub {
		open(my $f, '>', "$tmp/orphan-id") ||
			die $!; print($f $_[0]); close($f);
		}, progress => sub {
			# Publish the descendant PID so recovery can
			# verify it was stopped.
			if (($_[0]->{'phase'} || '') eq 'child') {
				open(my $f, '>', "$tmp/orphan-pid") ||
					die $!; print($f $_[0]->{'pid'}); close($f);
				}
			});
	exit(1);
	}
$deadline = time() + 10;
select(undef, undef, undef,
       0.1) while (!-s "$tmp/orphan-pid" && time() < $deadline);
open($fh, '<', "$tmp/orphan-id") || die 'Recovery worker did not start';
my $orphan = do { local $/; <$fh> }; close($fh);
open($fh, '<', "$tmp/orphan-pid") || die 'Recovery child did not start';
my $orphan_pid = do { local $/; <$fh> }; close($fh);
kill('KILL', $coordinator); waitpid($coordinator, 0);
$probe->cleanup($orphan);
push(@ids, $orphan);
ok(!-d "/var/lib/private/cloudmin-workers/$orphan",
   'recovery removes abandoned private state');
my $alive = 0;
# Treat a reaped or zombie descendant as stopped after recovery.
if (open(my $stat, '<',
	 "/proc/$orphan_pid/stat")) { $alive = <$stat> !~ /\) Z /; }
ok(!$alive, 'recovery stops descendants after the root job process dies');

# Exercise actual disk and provisioning tools under the same policy.
system('/usr/bin/qemu-img', 'create', '-q', '-f', 'qcow2', "$tmp/image",
       '32M') == 0 || die;
open($fh, '<', "$tmp/image") || die $!;
my $bytes = do { local $/; <$fh> }; close($fh);
my $checksum = sha256_hex($bytes);
$r = $runner->run('image',
		  { format => 'qcow2', limit => 1024**2, sha256 => $checksum },
		  files => { image => "$tmp/image" }, output => "$tmp/checked",
		  started => $started);
is($r->{'verified'}, 'sha256', 'real SHA-256 verification runs unprivileged');
is($r->{'virtual-size'}, 32 * 1024**2, 'real qemu-img inspection succeeds');
open($fh, '<', "$tmp/checked") || die $!;
is(sha256_hex(do { local $/; <$fh> }), $checksum,
   'handoff preserves every image byte'); close($fh);
is((stat("$tmp/checked"))[4], 0, 'claimed image belongs to the controller');
is((stat("$tmp/checked"))[2] & 0777, 0600, 'claimed image remains private');

# Local imports must never turn a root-only host file into a downloadable disk.
my $public = tempdir('/tmp/cloudmin-readable-image-XXXXXX', CLEANUP => 1);
chmod(0755, $public) || die $!;
open(my $public_image, '>', "$public/image") || die $!;
print($public_image $bytes); close($public_image);
chmod(0644, "$public/image") || die $!;
my $local = $runner->run('local_image',
			 { format => 'qcow2', path => "$public/image",
			   limit => 1024**2, sha256 => $checksum },
			 output => "$tmp/local-checked", started => $started);
is($local->{'checksum_digest'}, $checksum,
   'readable host image is copied and verified without root');
for my $path ( "$tmp/root-canary", '/etc/shadow',
	       '/etc/webmin/miniserv.users' ) {
	ok(!eval { $runner->run('local_image',
				{ format => 'raw', path => $path,
				  limit => 1024**2 },
				output => "$tmp/forbidden-copy",
				started => $started); 1 },
	   'private host input is rejected');
	ok(!-e "$tmp/forbidden-copy",
	   'private host input produces no importable data');
	}
symlink("$public/image", "$public/link") || die $!;
POSIX::mkfifo("$public/fifo", 0644) == 0 || die $!;
for my $name (qw(link fifo)) {
	ok(!eval { $runner->run('local_image',
				{ format => 'raw', path => "$public/$name",
				  limit => 1024**2 },
				output => "$tmp/forbidden-copy",
				started => $started); 1 },
	   "local $name is rejected without blocking");
	}

# A separate tmpfs exercises handoff when Webmin and worker storage differ.
my $cross = tempdir('/dev/shm/cloudmin-worker-check-XXXXXX', CLEANUP => 1);
isnt((stat($cross))[0], (stat('/var/lib/private/cloudmin-workers'))[0],
     'cross-filesystem fixture uses a different device');
$runner->run('image',
	     { format => 'qcow2', limit => 1024**2, sha256 => $checksum },
	     files => { image => "$tmp/image" }, output => "$cross/checked",
	     started => $started);
is(-s "$cross/checked", length($bytes),
   'cross-filesystem handoff preserves the size');
open($fh, '<', "$cross/checked") || die $!;
is(sha256_hex(do { local $/; <$fh> }), $checksum,
   'cross-filesystem handoff preserves every byte'); close($fh);
# A digest mismatch must prevent the controller from claiming any output disk.
ok(!eval { $runner->run('image',
			{ format => 'qcow2', limit => 1024**2, sha256 =>
								       '0' x 64 },
			files => { image => "$tmp/image" },
			output => "$tmp/bad",
			started => $started); 1 }, 'bad checksum fails closed');
like($@, qr/checksum mismatch/i, 'checksum failure is explained');
ok(!-e "$tmp/bad", 'bad checksum produces no importable output');
# A backing-file reference must be rejected before it could become VM storage.
system('/usr/bin/qemu-img', 'create', '-q', '-u', '-f', 'qcow2', '-F', 'raw',
       '-b',
       '/etc/shadow', "$tmp/linked", '32M') == 0 || die;
ok(!eval { $runner->run('image', { format => 'qcow2', limit => 1024**2 },
			files => { image => "$tmp/linked" },
			output => "$tmp/bad",
			started => $started); 1 },
   'a QCOW2 reference to a host file is rejected');
ok(!-e "$tmp/bad", 'linked image produces no importable output');
# Exercise successful and failed key parsing, then actual seed ISO generation.
my $key = 'ssh-ed25519 '.
	  encode_base64(pack('N', 11).'ssh-ed25519'.pack('N',
							 32).('A' x 32), '');
ok($runner->run('keys', { keys => "$key\n" }, started => $started),
   'real SSH key parser runs unprivileged');
ok(!eval { $runner->run('keys', { keys => "not an SSH key\n" },
			started => $started); 1 },
   'invalid SSH key is rejected');
ok($runner->run('seed',
		{ uuid => 'fixture',
		  request =>
			  { username => 'fixture', hostname => 'fixture',
			    mac => '52:54:00:12:34:56', address_mode => 'dhcp',
			    auth_type => 'keys',
			    ssh_keys => $key } },
		output => "$tmp/seed.iso", started => $started),
   'real cloud-init disk is generated unprivileged');
ok(-s "$tmp/seed.iso", 'cloud-init disk is handed back to the controller');

# Every success, failure, timeout and cancellation must
# remove its private state.
for my $id ( @ids, $held_id ) {
	ok(!-e "/var/lib/private/cloudmin-workers/$id" &&
	   !-e "/var/lib/private/cloudmin-workers/$id.lease" &&
	   !-l "/var/lib/cloudmin-workers/$id",
	   'completed task leaves no worker files or lease');
	}
done_testing();
