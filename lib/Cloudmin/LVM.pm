package Cloudmin::LVM;

# LVM supplies block storage; libvirt continues to own guest definitions.
# Thin pools are separate destinations within a registered libvirt volume group.
use strict;
use warnings;
use Cwd qw(abs_path);
use Digest::SHA qw(sha256_hex);
use File::Basename qw(dirname);
use Fcntl qw(O_RDONLY O_WRONLY O_CREAT O_EXCL O_NOFOLLOW SEEK_SET);
use WebminCore qw(convert_from_json execute_command quote_path is_readonly_mode
	foreign_require foreign_call);

# new(class, [readonly => boolean], [runner => callback], [creator => callback])
# Defaults to read-only access and loads metadata on demand.
# runner(operation, arguments...) and creator(settings) isolate tests.
sub new
{
my ($class, %options) = @_;
return bless({ readonly => 1, %options }, $class);
}

# create_logical_volume(self, settings) uses Webmin's existing LVM creation API.
# Cloudmin validates names, space and ownership before calling the shared helper.
sub create_logical_volume
{
my ($self, $settings) = @_;
die "LVM changes are disabled in read-only mode\n"
	if ($self->{'readonly'} || is_readonly_mode());
my $error;
if ($self->{'creator'}) {
	# Tests supply metadata without invoking the host's LVM module.
	$error = $self->{'creator'}->($settings);
	}
else {
	# Reuse Webmin's allocation options and command error handling.
	foreign_require('lvm', 'lvm-lib.pl');
	$error = foreign_call('lvm', 'create_logical_volume', $settings);
	}
die "Cannot create logical volume: $error\n" if (defined($error) && length($error));
}

package Cloudmin::LVM::Pool;
use strict;
use warnings;

package Cloudmin::LVM::Volume;
use strict;
use warnings;
use Fcntl qw(O_RDONLY O_RDWR O_NOFOLLOW SEEK_SET);
use IO::Handle ();
use Errno qw(EOPNOTSUPP ENOTTY EINVAL);

1;
