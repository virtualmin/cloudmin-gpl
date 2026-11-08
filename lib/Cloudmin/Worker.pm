package Cloudmin::Worker;

# The controller retains job records and libvirt access. A fresh systemd service
# processes each task under its own temporary UID, with no
# inherited credentials.
use strict;
use warnings;
use JSON::PP qw(encode_json decode_json);
use File::Path qw(make_path remove_tree);
use File::Basename qw(dirname);
use Cwd qw(abs_path);
use Fcntl qw(:DEFAULT O_NOFOLLOW);
use Errno qw(EEXIST EXDEV);
use IPC::Open3;
use IO::Select;
use Symbol qw(gensym);
use POSIX qw(WNOHANG);
use Time::HiRes qw(time);

my $ROOT = '/var/lib/private/cloudmin-workers';
my $PUBLIC = '/var/lib/cloudmin-workers';
my %TIMEOUT =
	( image => 3600, local_image => 3600, convert => 3600, inspect => 180,
	  clone_prepare => 900,
	  backup_archive => 7200, backup_transfer => 7200,
	  backup_host_key => 30,
	  seed => 60, keys => 30, keypair => 30, size => 20,
	  software => 7500 );
my $SMALL_FILE = 16 * 1024**2;
my $RESERVE_BYTES = 256 * 1024**2;

# byte_limit(value) Accepts positive byte budgets representable exactly in
# controller and UI JSON.
sub byte_limit
{
my ($value) = @_;
die "Invalid image byte limit\n" if (!defined($value) || ref($value) ||
				     $value !~ /\A[1-9]\d{0,15}\z/ || $value > 9007199254740991);
return 0 + $value;
}

# new(class) Creates a runner without touching the host during
# ordinary page rendering.
sub new
{
return bless({ }, $_[0]);
}

# generate_id() Allocates a private task identifier
# independent of all user input.
sub generate_id
{
open(my $fh, '<', '/dev/urandom') || die "Cannot allocate image worker\n";
read($fh, my $bytes, 16) == 16 || die "Cannot allocate image worker\n";
return unpack('H*', $bytes);
}

# path(id) Checks a task ID's format before deriving its private directory path.
sub path
{
my ($id) = @_;
# Reject traversal and arbitrary service names before using the identifier.
die "Invalid image worker identifier\n" if (($id || '') !~ /\A[a-f0-9]{32}\z/);
return "$ROOT/$id";
}

# private_root() Requires root-owned, private parents before
# preparing input for a worker.
sub private_root
{
# The isolation policy depends on Linux service and namespace support.
die "Image workers require Linux and systemd\n"
	if ($^O ne 'linux' || !-x '/usr/bin/systemd-run');
# Unprivileged callers must not prepare directories for privileged claims.
die "Only the Cloudmin controller may start image workers\n"
	if ($< != 0 || $> != 0);
for my $path ( '/var/lib/private', $ROOT ) {
	# Concurrent imports may both initialize these shared parents.
	mkdir($path, 0700) || $! == EEXIST ||
		die "Cannot create worker directory: $!\n" if (!-e $path);
	my @s = lstat($path);
	# Existing parents are trusted only if other users
	# cannot replace inputs.
	die "Unsafe worker directory: $path\n"
		if (!@s || !-d _ || -l _ || $s[4] != 0 || ($s[2] & 0077));
	}
}

# command(self, task, id, [limit]) Builds a fixed sandbox policy. Requests
# cannot choose users or unit properties. limit is the controller's byte budget,
# defaulting to 16 MiB.
sub command
{
my ($self, $task, $id, $limit) = @_;
path($id);
my $file_limit = byte_limit(defined($limit) ? $limit : $SMALL_FILE);
# Small images still need space for bounded logs, manifests and request data.
$file_limit = $SMALL_FILE if ($file_limit < $SMALL_FILE);
# Resource limits exist only for the supported task types.
die "Unknown image worker task\n" if (!exists($TIMEOUT{$task}));
my $helper = abs_path(dirname(__FILE__).'/../../worker.pl');
# Resolve the packaged worker before handing its path to systemd.
die "Image worker program is missing\n" if (!$helper);
my $guestfs = $task eq 'inspect' || $task eq 'clone_prepare';
my @properties =
	(
		'DynamicUser=yes', "StateDirectory=cloudmin-workers/$id",
		'StateDirectoryMode=0700',
		"WorkingDirectory=$PUBLIC/$id", 'UMask=0077',
		'NoNewPrivileges=yes',
		'CapabilityBoundingSet=', 'AmbientCapabilities=',
		'ProtectSystem=strict',
		'ProtectHome=yes', 'PrivateTmp=yes', 'ProtectProc=invisible',
		# Supermin reads module files to build its appliance; loading
		# modules stays forbidden.
		'ProtectKernelTunables=yes',
		'ProtectKernelModules='.($guestfs ? 'no' : 'yes'),
		'SystemCallFilter=~@module', 'ProtectKernelLogs=yes',
		'ProtectControlGroups=yes', 'RestrictNamespaces=yes',
		'RestrictSUIDSGID=yes',
		'LockPersonality=yes', 'RestrictRealtime=yes',
		'KeyringMode=private',
		'TemporaryFileSystem=/run:ro',
		# Keep user lookup and resolver data available, without
		# host control sockets.
		'BindReadOnlyPaths=-/run/systemd/userdb -/run/systemd/resolve/resolv.conf '.
		'-/run/systemd/resolve/stub-resolv.conf -/run/NetworkManager/resolv.conf '.
		'-/run/NetworkManager/no-stub-resolv.conf',
		'InaccessiblePaths=-/etc/webmin -/var/webmin -/etc/libvirt -/var/lib/libvirt',
		'StandardInput=null', "StandardOutput=append:$ROOT/$id/events",
		"StandardError=append:$ROOT/$id/errors",
		'KillMode=control-group', 'TimeoutStopSec=5',
		"RuntimeMaxSec=$TIMEOUT{$task}",
		'TasksMax=64', 'MemoryMax='.($guestfs ? '2G' : '512M'),
		'LimitCORE=0',
		'LimitFSIZE='.$file_limit,
		# Network tasks include downloads, guest setup and
		# backup transfers/probes.
		'PrivateNetwork='.($task eq 'image' || $task eq 'size' ||
				   $task eq 'software' || $task eq 'backup_transfer' ||
				   $task eq 'backup_host_key' ? 'no' : 'yes'),
		'PrivateDevices='.($guestfs ? 'no' : 'yes'),
	);
# DynamicUser always isolates /tmp. Give host-file imports read-only views at
# fixed paths; ordinary Unix permissions still apply to every component.
push(@properties,
     'BindReadOnlyPaths=/tmp:/run/cloudmin-host-tmp /var/tmp:/run/cloudmin-host-var-tmp')
	if ($task eq 'local_image');
# The inspection appliance gets KVM access, but no libvirt group or sockets.
push(@properties, 'DevicePolicy=closed', 'DeviceAllow=/dev/kvm rw',
     'SupplementaryGroups=kvm') if ($guestfs);
# GNU tar can need openat2 calls blocked by this sandbox's SUID protection. Use
# bsdtar for supermin's extraction without changing the host's tar.
push(@properties, 'BindReadOnlyPaths=/usr/bin/bsdtar:/usr/bin/tar')
	if ($guestfs);
my @environment;
# Ubuntu protects /boot kernels from ordinary users. Point supermin at the
# staged copy of the running kernel and its matching installed modules.
if ($guestfs) {
	my $release = kernel_release();
	@environment =
		( "--setenv=SUPERMIN_KERNEL=$PUBLIC/$id/appliance-kernel",
		  "--setenv=SUPERMIN_MODULES=/lib/modules/$release",
		  "--setenv=SUPERMIN_KERNEL_VERSION=$release" );
	}
return ( '/usr/bin/systemd-run', '--quiet', '--wait', '--collect',
	 '--no-ask-password',
	 '--service-type=exec', "--unit=cloudmin-worker-$id",
	 (map { ( '--property', $_ ) } @properties),
	 '--setenv=PATH=/usr/sbin:/usr/bin:/sbin:/bin', '--setenv=LANG=C',
	 '--setenv=HOME='.$PUBLIC.'/'.$id, @environment, '/usr/bin/perl',
	 $helper );
}

# kernel_release() Uses the host kernel identity, never a guest image
# or request parameter.
sub kernel_release
{
my $release = (POSIX::uname())[2];
# The release becomes a path component and a service environment value.
die "Cannot determine the host kernel version\n"
	if ($release !~ /\A[a-zA-Z0-9._+-]+\z/);
return $release;
}

# stage_kernel(directory) Gives the temporary worker its own kernel without
# changing host permissions.
sub stage_kernel
{
my ($work) = @_;
my $release = kernel_release();
# Supermin needs modules that match the appliance kernel.
die "Install modules for the running kernel $release, or reboot after updating the kernel\n"
	if (!-d "/lib/modules/$release");
my ($source) = grep { -f $_ && !-l $_ }
	       ( "/boot/vmlinuz-$release", "/lib/modules/$release/vmlinuz" );
# An upgrade may remove the running kernel before reboot.
die "Install the running kernel $release, or reboot after updating the kernel\n"
	if (!$source);
my @s = lstat($source);
# The appliance must not boot a kernel writable by an unprivileged user.
die "Unsafe host kernel permissions\n" if ($s[4] != 0 || ($s[2] & 0022));
copy_file($source, "$work/appliance-kernel");
}

# write_data(path, data) Creates input files privately before systemd gives this
# directory to the worker.
sub write_data
{
my ($path, $data) = @_;
sysopen(my $fh, $path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600) ||
	die "Cannot prepare worker input: $!\n";
binmode($fh);
print($fh $data) && close($fh) || die "Cannot write worker input: $!\n";
}

# copy_file(source, destination, [limit]) Copies regular files or managed LVM
# bytes without parsing disk formats. Regular files use reflinks/sparse copying;
# LVs become private sparse files. limit optionally bounds inputs or outputs to
# their controller-issued budget.
sub copy_file
{
my ($source, $destination, $limit) = @_;
byte_limit($limit) if (defined($limit));
# Managed block disks are copied as bytes before entering the sandbox.
if (-b $source) {
	require(dirname(__FILE__).'/LVM.pm');
	return Cloudmin::LVM::copy_to_file($source, $destination, $limit);
	}
my @s = lstat($source);
# Reject special files before applying the separate byte budget.
die "Worker input must be a regular file\n"
	if (!@s || !-f _ || -l _);
# The worker and Webmin stores can live on different filesystems. Reserve space
# for a full copy before cp can consume the host's remaining storage. Report a
# storage shortage before a budget clamped to that same free space.
die "Not enough free space for private image processing\n"
	if (free_space(dirname($destination)) < $s[7] + $RESERVE_BYTES);
die "Worker input exceeds the image byte limit\n"
	if (defined($limit) && $s[7] > $limit);
system('/usr/bin/cp', '--reflink=auto', '--sparse=always', '--', $source,
       $destination) == 0 ||
	die "Cannot copy image into the private worker directory\n";
chmod(0600, $destination) || die "Cannot protect worker input\n";
}

# free_space(directory) Reads filesystem capacity without loading Webmin
# configuration or parsing a disk.
sub free_space
{
open(my $fh, '-|', '/usr/bin/stat', '-f', '-c', '%a:%S', '--', $_[0]) ||
	die "Cannot check worker staging space\n";
my $space = <$fh>;
close($fh) || die "Cannot check worker staging space\n";
my ($blocks, $size) = ($space || '') =~ /\A(\d+):(\d+)\s*\z/;
# An unreadable capacity must not be mistaken for enough free space.
die "Invalid worker staging space\n" if (!defined($blocks));
return $blocks * $size;
}

# run(self, task, request, [files => hash], [contents => hash],
#     [output => path], [outputs => hash], [progress => callback],
#     [started => callback], [consume => callback])
# Runs an isolated task and claims only its expected files. files maps staged
# basenames to source paths; contents maps basenames to bytes. output receives
# the single output file; outputs maps clone disk basenames to destination
# paths. started(id) journals the task; progress(event) can abort it by
# throwing. consume(path, result) reads claimed conversion output
# after the worker stops.
sub run
{
my ($self, $task, $request, %opts) = @_;
# Reject unknown tasks before creating service state or choosing a timeout.
die "Unknown image worker task\n" if (!exists($TIMEOUT{$task}));
# Only download and size-probe tasks receive Webmin's outgoing proxy settings.
# These stay in the private request file, outside job records and progress.
if ($task eq 'image' || $task eq 'size') {
	no warnings 'once';
	$request = { %$request, proxy => { map {
		defined($WebminCore::gconfig{$_})
			? ( $_ => $WebminCore::gconfig{$_} )
			: ()
		} qw(http_proxy proxy_user proxy_pass proxy_fallback noproxy bind_proxy) } };
	}
private_root();
# Libguestfs inspection and clone preparation use a fixed bsdtar bind mount.
die "Install bsdtar (libarchive-tools on Debian/Ubuntu) for disk inspection and clone preparation\n"
	if (($task eq 'inspect' || $task eq 'clone_prepare') &&
	    !-x '/usr/bin/bsdtar');
$self->cleanup_stale();
my $id = generate_id();
my $work = path($id);
mkdir($work, 0700) || die "Cannot create image worker: $!\n";
my ($result, $error);
my $ok = eval {
	write_data("$ROOT/$id.lease", encode_json({ created => time() }));
	my $limit = $SMALL_FILE;
	# Bound disk work by workspace free space, even without a configured
	# cap. Leave the host's reserved free space available.
	if ($task eq 'image' || $task eq 'local_image' || $task eq 'convert' ||
	    $task eq 'inspect' || $task eq 'clone_prepare' ||
	    $task eq 'backup_archive' || $task eq 'backup_transfer') {
		my $available = free_space($work) - $RESERVE_BYTES;
		die "Not enough free space for private image processing\n"
			if ($available <= 0);
		$limit = $task eq 'inspect' || $task eq 'clone_prepare'
			? byte_limit($available)
			: byte_limit($request->{'limit'});
		$limit = $available if ($limit > $available);
		if ($task eq 'clone_prepare') {
			# Writable QCOW2 copies can grow to full capacity in the
			# appliance. Check this filesystem separately from the
			# destination storage pool.
			die "Invalid clone disk budget\n"
				if (ref($request->{'disks'}) ne 'ARRAY' ||
				    !@{$request->{'disks'}} || @{$request->{'disks'}} > 32);
			my $capacity = 0;
			$capacity += byte_limit(
				$_->{'capacity'}) foreach @{$request->{'disks'}};
			die "Not enough temporary storage for full clone preparation\n"
				if (
					$capacity * 1.01 + 512 * 1024**2 > $available);
			}
		# Give acquisition workers the reduced budget as well as
		# enforcing it in systemd and when claiming their output.
		$request = { %$request,
			     limit => $limit } if ($task ne 'inspect');
		}
	# Let a persistent job record its task ID before any child can start.
	$opts{'started'}->($id) if ($opts{'started'});
	for my $name ( keys %{$opts{'files'} || { }},
		       keys %{$opts{'contents'} || { }} ) {
		# Callers may supply data files, but not
		# replace controller inputs.
		die "Invalid worker input filename\n"
			if ($name !~ /\A[a-z][a-z0-9.-]*\z/ ||
			    $name eq 'request.json' ||
			    $name eq 'appliance-kernel');
		}
	copy_file($opts{'files'}->{$_},
		  "$work/$_", $limit) for keys %{$opts{'files'} || { }};
	write_data(
		"$work/$_",
		$opts{'contents'}->{$_}) for keys %{$opts{'contents'} || { }};
	# Basic qemu-img inspection needs no appliance or private kernel copy.
	stage_kernel($work)
		if ($task eq 'clone_prepare' || $task eq 'inspect' &&
		    ($request->{'guest'} || $request->{'appliance'}));
	my $json = encode_json({ %$request, task => $task });
	# Bound the request that the isolated process will decode into memory.
	die "Image worker request is too large\n"
		if (length($json) > 512 * 1024);
	write_data("$work/request.json", $json);
	$result = $self->launch($task, $id, $opts{'progress'}, $limit);
	# A stopped service has no surviving descendants that
	# can alter this file.
	$self->stop($id);
	# Probes return JSON only; imports, archives and
	# downloads also return a file.
	$self->claim("$work/output", $opts{'output'}, $limit)
		if ($opts{'output'});
	# Conversion callers consume a checked regular output
	# after the sandbox stops.
	if ($opts{'consume'}) {
		die "Output consumer is available only for disk conversion\n"
			if ($task ne 'convert');
		$self->claim("$work/output", "$work/claimed", $limit);
		$opts{'consume'}->("$work/claimed", $result);
		}
	# Clones and archive extraction return only controller-selected files.
	# Claim them after the service and any guestfs appliance have stopped.
	foreach my $name (sort keys %{$opts{'outputs'} || { }}) {
		die "Invalid clone output filename\n"
			if (!(($task eq 'clone_prepare' &&
			       $name =~ /\Adisk\d+\z/) ||
			      ($task eq 'backup_archive' &&
			       $name =~ /\A(?:disk\d{1,2}|nvram|ssh-key|domain.xml)\z/)));
		$self->claim("$work/$name", $opts{'outputs'}->{$name}, $limit);
		}
	1;
	};
$error = $@;
my $cleaned = eval { $self->cleanup($id); 1 };
# Preserve the original task error when cleanup fails as well.
$error .= " Worker cleanup failed: $@" if (!$cleaned);
# A successful task is still a failure if its sandbox cannot be removed.
die $error if (!$ok || !$cleaned);
return $result;
}

# launch(self, task, id, [progress], [limit]) Reads bounded events from
# preopened files, without passing Webmin pipes over D-Bus. limit supplies the
# controller's file budget to the service policy.
sub launch
{
my ($self, $task, $id, $progress, $limit) = @_;
my $work = path($id);
# Retain these descriptors so a worker cannot redirect root reads using links.
write_data("$work/events", '');
write_data("$work/errors", '');
sysopen(my $events, "$work/events", O_RDONLY | O_NOFOLLOW) ||
	die "Cannot open worker events\n";
sysopen(my $errors, "$work/errors", O_RDONLY | O_NOFOLLOW) ||
	die "Cannot open worker errors\n";
my @command = $self->command($task, $id, $limit);
my ($stdin, $stdout, $stderr) = ( gensym(), gensym(), gensym() );
local $SIG{'CHLD'} = 'DEFAULT';
my $pid;
{
	# Clear inherited credentials only for the launcher, keeping Webmin's
	# context available to job callbacks in the parent process.
	local %ENV = ( PATH => '/usr/sbin:/usr/bin:/sbin:/bin',
		       LANG => 'C' );
	$pid = open3($stdin, $stdout, $stderr, @command);
	}
close($stdin);
my $select = IO::Select->new($stdout, $stderr);
my ($buffer, $diagnostic, $result, $failure, $hello) = ( '', '', undef, '',
							 0 );
my ($status, $received) = ( undef, 0 );
my $started = time();
# Allow systemd's own runtime stop to finish before the controller gives up.
my $deadline = $started + $TIMEOUT{$task} + 15;
my $last_tick = 0;
my $ok = eval {
	while (1) {
		# This is the controller deadline, independent of
		# systemd's exit reason.
		die "Image worker timed out\n" if (time() > $deadline);
		# Callers check cancellation on ticks. Once a second is enough
		# and avoids a job-store read on every 100 ms
		# poll of a long task.
		if ($progress && time() - $last_tick >= 1) {
			$progress->({ type => 'tick' });
			$last_tick = time();
			}
		# The client reports service-launch failures, not
		# worker protocol events.
		for my $fh ($select->can_read(0.1)) {
			my $n = sysread($fh, my $data, 16384);
			# A failed pipe read cannot be treated as an
			# orderly launcher exit.
			die "Cannot read service response: $!\n"
				if (!defined($n));
			# Stop watching closed launcher pipes while task
			# files are still drained.
			if (!$n) { $select->remove($fh); next; }
			$diagnostic = substr($diagnostic.$data, -4096);
			}
		my $read = 0;
		for my $fh ( $events, $errors ) {
			my $n = sysread($fh, my $data, 16384);
			# Fail rather than accept results from an
			# incompletely read event file.
			die "Cannot read image worker response: $!\n"
				if (!defined($n));
			$read += $n;
			$received += $n;
			# Bound total output as well as each
			# individual protocol message.
			die "Image worker output limit exceeded\n"
				if ($received > 8 * 1024**2);
			if (fileno($fh) == fileno($errors)) {
				# Diagnostics are bounded text, never part
				# of the JSON protocol.
				$diagnostic = substr($diagnostic.$data, -4096);
				next;
				}
			$buffer .= $data;
			# An unterminated or oversized JSON line must
			# not exhaust the parent.
			die "Image worker response is too large\n"
				if (length($buffer) > 65536);
			while ($buffer =~ s/\A([^\n]*)\n//) {
				my $event = eval { decode_json($1) };
				# Only JSON objects participate in the
				# worker event protocol.
				die "Invalid image worker response\n"
					if (ref($event) ne 'HASH');
				my $type = $event->{'type'} || '';
				if ($type eq 'identity') {
					# Require one non-root identity before
					# accepting task data.
					die "Invalid worker identity\n"
						if ($hello || grep {
							!defined($_) || ref($_) ||
								!/\A[1-9]\d*\z/
							} @$event{qw(uid euid)});
					$hello = 1;
					}
				else {
					# A single identity precedes progress
					# and exactly one final response.
					die "Invalid worker event order\n"
						if (!$hello ||
						    defined($result) || $failure);
					# Progress may update the job or raise
					# a cancellation error.
					if ($type eq 'progress') { $progress->($event) if ($progress); }
					# Accept only a structured task result
					# as the success response.
					elsif ($type eq 'result' &&
					       ref($event->{'data'}) eq 'HASH') { $result = $event->{'data'}; }
					# Bound the worker's failure message
					# before returning it to callers.
					elsif ($type eq 'error' &&
					       !ref($event->{'message'})) {
						$failure = substr($event->{'message'} || 'Image worker failed', 0, 1500);
						}
					# Unknown or malformed events must not
					# be treated as success.
					else { die "Unknown image worker response\n"; }
					}
				}
			}
		# Drain files once more after the service client exits
		# before accepting output.
		last if (defined($status) && !$read && !$select->count());
		# Poll the launcher without blocking delivery of
		# progress and cancellation.
		if ($pid) {
			my $done = waitpid($pid, WNOHANG);
			# Losing the launcher prevents verification of
			# successful completion.
			die "Cannot wait for image worker\n" if ($done < 0);
			# Preserve exit status once the child has been reaped.
			if ($done) { $status = $?; $pid = undef; }
			}
		# Avoid spinning after launcher pipes close but
		# before it is reaped.
		select(undef, undef, undef, 0.1)
			if (!$select->count() && !$read);
		}
	if ($status || $failure || !$hello || ref($result) ne 'HASH' ||
	    length($buffer)) {
		# Silent exits can be timeouts, crashes or external stops.
		# Report the elapsed time and limit without guessing why
		# the service stopped.
		my $reason = $failure || substr($diagnostic, 0, 1500);
		$reason ||= sprintf(
			'Image worker failed without an error message after %.0f seconds (time limit: %d seconds)',
			time() - $started, $TIMEOUT{$task});
		die "$reason\n";
		}
	1;
	};
my $error = $@;
if ($pid) {
	# Prevent further start requests, then stop the service and
	# all its descendants.
	kill('KILL', $pid);
	waitpid($pid, 0);
	my $stopped = eval { $self->stop($id); 1 };
	# Keep a failed service stop visible alongside the
	# original launch error.
	$error .= " Cannot stop image worker: $@" if (!$stopped);
	}
close($stdout); close($stderr); close($events); close($errors);
# Release descriptors before propagating a protocol or cancellation error.
die $error if (!$ok);
return $result;
}

# stop(self, id) Stops only this generated unit and confirms it has stopped
# before callers read its output.
sub stop
{
my ($self, $id) = @_;
path($id);
my $unit = "cloudmin-worker-$id.service";
# Collected units are already gone. Any other systemd failure is an error.
my $state =
	`/usr/bin/systemctl show --property=LoadState --value $unit 2>/dev/null`;
# A failed query gives no evidence that the service has stopped.
die "Cannot check image worker service\n" if ($?);
# systemd may already have collected a completed transient unit.
return if ($state =~ /\Anot-found\s*\z/);
# A successful stop waits for the entire service control group to exit.
return if (system('/usr/bin/systemctl', 'stop', $unit) == 0);
# A finished unit can be garbage-collected between the state check and stop.
$state =
	`/usr/bin/systemctl show --property=LoadState --value $unit 2>/dev/null`;
die "Cannot stop image worker service\n"
	if ($? || $state !~ /\Anot-found\s*\z/);
}

# claim(self, source, destination, [limit]) Rejects links and non-regular files
# before moving output to the private store. limit defaults to the 16 MiB budget
# for small provisioning tasks.
sub claim
{
my ($self, $source, $destination, $limit) = @_;
$limit = byte_limit(defined($limit) ? $limit : $SMALL_FILE);
my @s = lstat($source);
# Reject special files, shared inodes and outputs outside the size budget.
die "Invalid image worker output file\n"
	if (!@s || !-f _ || -l _ || $s[3] != 1 || !$s[7] || $s[7] > $limit);
# Claiming output must never replace a controller-owned file or link.
die "Image worker destination already exists\n"
	if (-e $destination || -l $destination);
if (!rename($source, $destination)) {
	# Staging and libvirt state may live on different filesystems.
	die "Cannot claim image worker output: $!\n" if ($! != EXDEV);
	copy_file($source, $destination, $limit);
	unlink($source) || die "Cannot remove worker output after copying\n";
	}
chown(0, 0, $destination) && chmod(0600, $destination) ||
	die "Cannot protect completed image worker output\n";
}

# cleanup(self, id) Stops a surviving task and removes its private state
# without following links.
sub cleanup
{
my ($self, $id) = @_;
my $work = path($id);
$self->stop($id);
my @s = lstat($work);
# A compromised task must not redirect recursive removal through a link.
die "Unsafe image worker directory\n" if (@s && (!-d _ || -l _));
# systemd creates one public symlink for each private StateDirectory.
unlink("$PUBLIC/$id") || die "Cannot remove worker directory link\n"
	if (-l "$PUBLIC/$id");
# Cleanup also handles tasks whose private directory was already removed.
remove_tree($work, { safe => 1, error => \my $errors }) if (@s);
# Keep the lease when removal fails so a later recovery can retry.
die "Cannot clean image worker files\n" if ($errors && @$errors);
# The controller-owned lease is the last piece of completed task state.
unlink("$ROOT/$id.lease") || die "Cannot remove worker lease\n"
	if (-e "$ROOT/$id.lease");
}

# cleanup_stale(self) Reclaims interrupted tasks after their maximum lifetime,
# using root-owned leases.
sub cleanup_stale
{
my ($self) = @_;
opendir(my $dh, $ROOT) || die "Cannot read image worker directory\n";
my @ids = map { /\A([a-f0-9]{32})\.lease\z/ ? $1 : () } readdir($dh);
closedir($dh);
for my $id (@ids) {
	my @s = lstat("$ROOT/$id.lease");
	# Only old, root-owned regular leases authorize reclaiming a task.
	next if (!@s || !-f _ || -l _ || $s[4] != 0 || time() - $s[9] < 7200);
	$self->cleanup($id);
	}
}

1;
