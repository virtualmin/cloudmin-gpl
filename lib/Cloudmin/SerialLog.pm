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

package Cloudmin::SerialLog::Reader;
use strict;
use warnings;

1;
