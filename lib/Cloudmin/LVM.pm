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

# resize_logical_volume(self, record, bytes) uses Webmin after a grow-only check.
sub resize_logical_volume
{
my ($self, $record, $bytes) = @_;
die "LVM changes are disabled in read-only mode\n"
	if ($self->{'readonly'} || is_readonly_mode());
die "Shrinking logical volumes is not supported\n" if ($bytes <= $record->{'lv_size'});
# Webmin's resize API takes KiB; round up so it never shortens the request.
foreign_require('lvm', 'lvm-lib.pl');
my $error = foreign_call('lvm', 'resize_logical_volume',
	{ device => $record->{'lv_path'}, size => $record->{'lv_size'}/1024 },
	int(($bytes+1023)/1024));
die "Cannot grow logical volume: $error\n" if (defined($error) && length($error));
}

# command(self, operation, arguments...)
# Runs fixed LVM commands and a device-mapper report, with bounded execution.
# dm_info uses fixed fields and takes no command-line arguments.
sub command
{
my ($self, $operation, @args) = @_;
my $read = $operation eq 'vgs' || $operation eq 'lvs' || $operation eq 'dm_info';
die "Unsupported LVM operation\n"
	if ($operation !~ /\A(?:vgs|lvs|dm_info|lvcreate|lvextend|lvremove|lvchange)\z/);
die "LVM changes are disabled in read-only mode\n"
	if (!$read && ($self->{'readonly'} || is_readonly_mode()));
return $self->{'runner'}->($operation, @args) if ($self->{'runner'});
# Only production calls require Linux tools; fixture runners stop above.
die "LVM storage requires the local Linux host\n" if ($^O ne 'linux');
die "Install lvm2 to manage LVM storage\n" if (!-x '/usr/sbin/lvm');
# Device-mapper reports include thin-pool mappings omitted from lvs.
my @command = $operation eq 'dm_info'
	? ('/usr/sbin/dmsetup', 'info', '--columns', '--noheadings', '--separator', '|',
		'-o', 'uuid,major,minor,open')
	: ('/usr/sbin/lvm', $operation, @args);
my ($out, $err);
my $status = execute_command(join(' ', map { quote_path($_) }
	('/usr/bin/timeout', '--kill-after=5', '60', @command)),
	undef, \$out, \$err, 0, $read, !$read);
die "LVM $operation failed: ".substr($err || 'no diagnostic output', 0, 2000)."\n"
	if ($status);
die "LVM metadata is too large\n" if (length($out || '') > 16*1024**2);
return $out;
}

# name(value) validates a volume-group, logical-volume or thin-pool name.
sub name
{
my ($name) = @_;
die "Invalid LVM name\n" if (!defined($name) || ref($name) ||
	$name !~ /\A[a-zA-Z0-9_+][a-zA-Z0-9_.+-]{0,126}\z/ ||
	$name eq '.' || $name eq '..' || $name =~ /\A(?:snapshot|pvmove)/ ||
	$name =~ /_(?:cdata|cmeta|corig|mimage|mlog|rimage|rmeta|tdata|tmeta|vorigin)/);
return $name;
}

# device_path(group, volume) returns the stable, escaped device-mapper name.
# Use this canonical path so libvirt does not resolve a longer /dev/VG alias.
sub device_path
{
my ($group, $volume) = map { name($_) } @_;
s/-/--/g for ($group, $volume);
my $name = "$group-$volume";
die "The combined volume group and logical volume name is too long\n"
	if (length($name) > 127);
return "/dev/mapper/$name";
}

# number(value) requires an exact nonnegative byte count from LVM JSON.
sub number
{
my ($value) = @_;
die "Invalid LVM capacity\n" if (!defined($value) || ref($value) ||
	$value !~ /\A\d+(?:\.0+)?\z/ || $value > 9007199254740991);
return 0+$value;
}

# report(self, operation, section, fields)
# Decodes LVM's JSON report without relying on localized table output.
sub report
{
my ($self, $operation, $section, $fields) = @_;
my $data = convert_from_json($self->command($operation, '--reportformat', 'json',
	'--units', 'b', '--nosuffix', '-o', $fields));
die "Invalid LVM inventory\n" if (ref($data) ne 'HASH' || ref($data->{'report'}) ne 'ARRAY');
my @rows;
foreach my $report (@{$data->{'report'}}) {
	# LVM can return several report sections; consume only the requested one.
	next if (!exists($report->{$section}));
	die "Invalid LVM inventory\n" if (ref($report->{$section}) ne 'ARRAY');
	foreach my $row (@{$report->{$section}}) {
		# Keep fields scalar and remove the padding used by LVM's JSON reports.
		die "Invalid LVM inventory row\n" if (ref($row) ne 'HASH');
		foreach my $value (values %$row) {
			die "Invalid LVM inventory field\n" if (ref($value));
			$value =~ s/^\s+|\s+$//g if (defined($value));
			}
		push(@rows, $row);
		}
	}
return \@rows;
}

# usable(volume) identifies ordinary disks, excluding pool internals.
sub usable
{
my ($volume) = @_;
return ($volume->{'segtype'} || '') =~ /\A(?:linear|striped|thin|snapshot)\z/ &&
	($volume->{'lv_attr'} || '') =~ /\A[-Vos][wr]/ &&
	($volume->{'lv_path'} || '') =~ m{\A/dev/};
}

# btrfs_host_use(device_number, [sysfs_root]) refuses any mounted Btrfs member.
# The optional root allows isolated tests; callers use the kernel's sysfs tree.
sub btrfs_host_use
{
my ($number, $root) = @_;
$root //= '/sys/fs/btrfs';
# An unloaded Btrfs module has no mounted filesystems or sysfs directory.
return 1 if (!-e $root);
opendir(my $filesystems, $root) || die "Cannot check host Btrfs filesystems\n";
my @ids = grep { /\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/i }
	readdir($filesystems);
closedir($filesystems);
foreach my $id (@ids) {
	# Kernel device links cover all members, including secondary and seed disks.
	# They are removed on unmount, even if the UUID directory remains.
	opendir(my $devices, "$root/$id/devices") || die "Cannot check host Btrfs devices\n";
	my @names = grep { $_ ne '.' && $_ ne '..' } readdir($devices);
	closedir($devices);
	foreach my $name (@names) {
		open(my $device, '<', "$root/$id/devices/$name/dev")
			|| die "Cannot read host Btrfs device number\n";
		my $other = <$device>;
		close($device);
		die "Cannot identify host Btrfs device number\n"
			if (!defined($other) || $other !~ /\A\d+:\d+\s*\z/);
		$other =~ s/\s+\z//;
		die "This logical volume is mounted on the host by Btrfs\n" if ($other eq $number);
		}
	}
return 1;
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
