package Cloudmin::SerialLog;

# Native virtlogd logs retain console output while no browser is connected.
use strict;
use warnings;
use Fcntl qw(O_RDONLY O_NOFOLLOW O_NONBLOCK S_ISREG SEEK_SET);
use Errno qw(ENOENT);

# new(class, [directory], [qemu_config], [log_config]) Creates a log manager
# using /var/log/libvirt/qemu and the qemu.conf and virtlogd.conf files under
# /etc/libvirt unless paths are supplied.

sub new
{
my ($class, $directory, $qemu, $log) = @_;
return bless { directory => $directory || '/var/log/libvirt/qemu',
	       qemu_config => $qemu || '/etc/libvirt/qemu.conf',
	       log_config => $log || '/etc/libvirt/virtlogd.conf' }, $class;
}

# path(self, uuid) names only this guest's Cloudmin-owned serial log.

sub path
{
my ($self, $uuid) = @_;
# Validate the UUID before building a privileged file path.
die "Invalid serial log identity\n" if (!defined($uuid) ||
					$uuid !~ /\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/i);
return "$self->{directory}/cloudmin-".lc($uuid)."-serial.log";
}

# setting(file, name, default) reads one scalar libvirt configuration value.

sub setting
{
my ($file, $name, $default) = @_;
open(my $in, '<', $file) || do {
	# Absent files use libvirt defaults; unreadable files stop auto-setup.
	return $default if ($! == ENOENT);
	die "Cannot read serial logging configuration: $!\n";
	};
my $value = $default;
while (<$in>) {
	# Native settings are scalars, optionally quoted and
	# followed by a comment.
	$value = $1 if /^\s*\Q$name\E\s*=\s*(.*?)\s*(?:#.*)?$/;
	}
$value =~ s/\A["'](.*)["']\z/$1/;
return $value;
}

# bounded(self) requires native log rotation before enabling recording.

sub bounded
{
my ($self) = @_;
# Direct QEMU file logging has no native rotation to bound disk use.
return 0
	if (setting($self->{'qemu_config'}, 'stdio_handler', 'logd') ne 'logd');
my $size = setting($self->{'log_config'}, 'max_size', '2097152');
my $backups = setting($self->{'log_config'}, 'max_backups', '3');
# The reader supports 1–32 rotated backup files.
return $size =~ /\A[1-9][0-9]*(?:[ \t]*(?:bytes|[KMGTPE]i?B|[bBkKmMgGtTpPeE]))?\z/ &&
       $backups =~ /\A[0-9]+\z/ && $backups >= 1 && $backups <= 32;
}

# device(doc) selects the PTY behind libvirt's default console.

sub device
{
my ($doc) = @_;
my ($console) = $doc->findnodes('/domain/devices/console');
my ($serial) = $doc->findnodes('/domain/devices/serial');
my $node = $console;
# A serial-backed console and its serial element describe the same device.
if (!$console || !$console->findvalue('target/@type') ||
    $console->findvalue('target/@type') eq 'serial') {
	if ($console && length($console->findvalue('target/@port'))) {
		# Some external guests expose a later serial port as
		# the default console.
		my $port = $console->findvalue('target/@port');
		($serial) =
			grep { ($_->findvalue('target/@port') || '0') eq $port }
			$doc->findnodes('/domain/devices/serial');
		}
	$node = $serial || $console;
	}
# File, TCP and other console backends do not support this PTY/log pairing.
return $node && $node->getAttribute('type') eq 'pty' ? $node : undef;
}

# configure(self, xml) adds a private log, cleared on each cold start. Preserve
# custom logs and unsupported console devices.

sub configure
{
my ($self, $xml) = @_;
my $doc = Cloudmin::Libvirt::parse_xml_document($xml);
# Leave guests without a supported default console unchanged.
my $node = device($doc) || return $xml;
my $path = $self->path($doc->findvalue('/domain/uuid'));
my ($log) = $node->findnodes('log');
# A custom log belongs to the administrator, even on a supported console.
return $xml if ($log && $log->getAttribute('file') ne $path);
# Libvirt may repeat a serial device's log under its console alias. Keep just
# the serial definition so removing or replacing it cannot leave a stale copy.
my @aliases = grep { $_->findvalue('target/@type') eq 'serial' &&
	($_->findvalue('target/@port') || '0') eq
	($node->findvalue('target/@port') || '0') }
	      $doc->findnodes('/domain/devices/console');
my @duplicate_logs = $node->nodeName() eq 'serial'
	? map { $_->findnodes('log') } @aliases
	: ();
# Preserve custom settings on the console alias as well as the serial device.
return $xml if (grep { $_->getAttribute('file') ne $path } @duplicate_logs);
if (!$self->bounded()) {
	# Following rotation requires at least one retained file. Do not enable
	# logging when the host disables rotation or keeps no previous file.
	return $xml if (!$log && !@duplicate_logs);
	# Remove only managed definitions that can no longer be bounded safely.
	$_->unbindNode() foreach (grep { $_ } ( $log, @duplicate_logs ));
	return $doc->toString();
	}
# Refuse unsafe pre-existing paths before virtlogd opens or rotates them.
open_private($_) foreach ($path, map { "$path.$_" } 0 .. 31);
# Already-correct definitions need no rewrite or libvirt redefinition.
return $xml
	if ($log && $log->getAttribute('append') eq 'off' && !@duplicate_logs);
# Keep one log definition and discard earlier boot output on the next start.
$_->unbindNode() foreach @duplicate_logs;
$log ||= $node->addNewChild(undef, 'log');
$log->setAttribute('file', $path);
$log->setAttribute('append', 'off');
return $doc->toString();
}

# open_private(path) opens a regular private file without following symlinks.
# Returns undef for an absent file; refuses unsafe ownership, mode or links.

sub open_private
{
my ($path) = @_;
sysopen(my $fh, $path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) || do {
	# Rotation briefly removes a pathname before its successor is created.
	return undef if ($! == ENOENT);
	die "Cannot open serial history: $!\n";
	};
my @st = stat($fh);
# Validate the open file; rotation may already have renamed its path.
die "Serial history is not a private regular file\n" if
	(!@st || !S_ISREG($st[2]) || $st[4] != $> || ($st[2] & 0077) ||
	 $st[3] != 1);
return $fh;
}

# reader(self, uuid, xml) returns recent output and a cursor for the same log.
# The caller supplies the running domain's XML. Its log must match the managed
# path; this helper does not check the domain's power state or access grants.

sub reader
{
my ($self, $uuid, $xml) = @_;
my $path = $self->path($uuid);
my $doc = Cloudmin::Libvirt::parse_xml_document($xml);
# Unsupported or unrecorded consoles keep their live-only transport.
my $node = device($doc) || return undef;
return undef if ($node->findvalue('log/@file') ne $path);
for (1 .. 3) {
	# Open newest first and include older files only up to the replay limit.
	my $fh = open_private($path) || next;
	my @initial = stat($fh);
	my ($history, $left) = ( '', 65536 );
	my $current = $fh;
	my %seen;
	for my $index (-1 .. 31) {
		# Stop at the byte limit or the first missing older generation.
		last if (!$left);
		$current = open_private("$path.$index") if ($index >= 0);
		last if (!$current);
		my @st = stat($current);
		# Rotation can expose the same inode under two names.
		last if ($seen{"$st[0]:$st[1]"}++);
		# Prepend older bytes to keep the replay in order.
		my $count = $st[7] < $left ? $st[7] : $left;
		defined(sysseek($current, $st[7] - $count, SEEK_SET)) ||
			die "Cannot seek serial history: $!\n";
		my $read = sysread($current, my $bytes, $count);
		# Reject incomplete reads rather than replay partial history.
		die "Cannot read serial history\n"
			if (!defined($read) || $read != $count);
		$history = $bytes.$history;
		$left -= $count;
		}
	my @now = stat($path);
	# Retry if rotation changed the active file during the snapshot.
	next if (!@now || $now[0] != $initial[0] || $now[1] != $initial[1]);
	# Read live output from the same handle, after the replayed bytes.
	return bless { path => $path, fh => $fh, history => $history,
		       position => sysseek($fh, 0, 1) },
	       'Cloudmin::SerialLog::Reader';
	}
# Fail if rotation prevents a consistent snapshot.
die "Serial history changed while connecting; reconnect to the console\n";
}

# remove(self, uuid) removes only this guest's managed log and native rotations.

sub remove
{
my ($self, $uuid) = @_;
my $path = $self->path($uuid);
foreach my $file ( $path, map { "$path.$_" } 0 .. 31 ) {
	# Missing files are normal after failed creation or native rotation.
	unlink($file) || $! == ENOENT ||
		die "Cannot remove serial history: $!\n";
	}
}

package Cloudmin::SerialLog::Reader;
use strict;
use warnings;

# history(self) returns the bounded snapshot once, before following live bytes.

sub history
{
return delete($_[0]->{'history'}) || '';
}

# read(self) returns at most 64 KiB, following native
# renames without duplicates.

sub read
{
my ($self) = @_;
my $fh = $self->{'fh'};
my @st = stat($fh);
# Truncation invalidates the saved cursor; reconnect to obtain a new snapshot.
die "Serial history was truncated; reconnect to the console\n"
	if ($st[7] < $self->{'position'});
my $count = sysread($fh, my $bytes, 65536);
# A read error is different from an idle log at EOF.
die "Cannot read serial history: $!\n" if (!defined($count));
$self->{'position'} += $count;
# Drain this file before following rotation.
return $bytes if ($count);
my @active = stat($self->{'path'});
# EOF is normal while the active log is unchanged or between native renames.
return '' if (!@active || ($active[0] == $st[0] && $active[1] == $st[1]));
# Rotation can append its last bytes between our EOF read and the rename. Drain
# them before opening the next generation.
my @final = stat($fh);
return '' if ($final[7] > $self->{'position'});
# Find the next newer file, even after several rotations between polls.
for my $index (0 .. 31) {
	my @old = stat("$self->{path}.$index");
	# Locate the open inode's current name before selecting its successor.
	next if (!@old || $old[0] != $st[0] || $old[1] != $st[1]);
	my $next = $index ? "$self->{path}.".($index - 1) : $self->{'path'};
	my $new = Cloudmin::SerialLog::open_private($next) || return '';
	my @verify = stat("$self->{path}.$index");
	my @new = stat($new);
	# Retry a concurrent rename instead of rereading or
	# skipping a generation.
	return ''
		if (!@verify || $verify[0] != $st[0] || $verify[1] != $st[1] ||
		    ($new[0] == $st[0] && $new[1] == $st[1]));
	# Read the verified newer file from its start on the next poll.
	$self->{'fh'} = $new;
	$self->{'position'} = 0;
	return '';
	}
# Report lost output if rotation has overtaken the reader.
die "Serial history rotated too quickly; reconnect to the console\n";
}

1;
