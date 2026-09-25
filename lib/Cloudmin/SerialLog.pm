package Cloudmin::SerialLog;

# Native virtlogd logs retain console output while no browser is connected.
use strict;
use warnings;
use Fcntl qw(O_RDONLY O_NOFOLLOW O_NONBLOCK S_ISREG SEEK_SET);
use Errno qw(ENOENT);

# new(class, [directory], [qemu_config], [log_config])
# Creates a log manager using /var/log/libvirt/qemu and the qemu.conf and
# virtlogd.conf files under /etc/libvirt unless paths are supplied.
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
	# Native settings are scalars, optionally quoted and followed by a comment.
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
return 0 if (setting($self->{'qemu_config'}, 'stdio_handler', 'logd') ne 'logd');
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
		# Some external guests expose a later serial port as the default console.
		my $port = $console->findvalue('target/@port');
		($serial) = grep { ($_->findvalue('target/@port') || '0') eq $port }
			$doc->findnodes('/domain/devices/serial');
		}
	$node = $serial || $console;
	}
# File, TCP and other console backends do not support this PTY/log pairing.
return $node && $node->getAttribute('type') eq 'pty' ? $node : undef;
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
	(!@st || !S_ISREG($st[2]) || $st[4] != $> || ($st[2] & 0077) || $st[3] != 1);
return $fh;
}

package Cloudmin::SerialLog::Reader;
use strict;
use warnings;

1;
