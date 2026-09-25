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

package Cloudmin::SerialLog::Reader;
use strict;
use warnings;

1;
