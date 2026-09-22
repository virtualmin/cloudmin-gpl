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

# inventory(self, [refresh])
# Retains LVM UUIDs so device-node recreation and renamed paths do not hide a
# replaced volume. A single read supplies every pool in the current operation.
sub inventory
{
my ($self, $refresh) = @_;
return $self->{'inventory'} if ($self->{'inventory'} && !$refresh);
my $groups = $self->report('vgs', 'vg',
	'vg_name,vg_uuid,vg_size,vg_free,vg_extent_size,vg_attr');
my $volumes = $self->report('lvs', 'lv',
	'vg_name,vg_uuid,lv_name,lv_uuid,lv_attr,segtype,pool_lv,origin,'.
	'data_percent,metadata_percent,lv_size,origin_size,lv_path,lv_active,lv_tags,'.
	'lv_kernel_major,lv_kernel_minor,zero,lv_health_status');
my %groups;
# Index groups first so the LV report can be checked against their UUIDs.
foreach my $group (@$groups) {
	name($group->{'vg_name'});
	$group->{$_} = number($group->{$_}) for qw(vg_size vg_free vg_extent_size);
	die "Invalid LVM volume group identity\n"
		if (($group->{'vg_uuid'} || '') !~ /\A[a-zA-Z0-9-]{32,40}\z/);
	$group->{'volumes'} = {};
	$groups{$group->{'vg_name'}} = $group;
	}
foreach my $volume (@$volumes) {
	# A group replaced between the two commands cannot supply a valid snapshot
	# of the inventory; let the caller retry the whole read.
	my $group = $groups{$volume->{'vg_name'}};
	die "LVM inventory changed while reading it; retry\n"
		if (!$group || $group->{'vg_uuid'} ne $volume->{'vg_uuid'});
	$volume->{'lv_size'} = number($volume->{'lv_size'});
	die "Invalid LVM volume identity\n"
		if (($volume->{'lv_uuid'} || '') !~ /\A[a-zA-Z0-9-]{32,40}\z/);
	$group->{'volumes'}->{$volume->{'lv_name'}} = $volume;
	}
return $self->{'inventory'} = \%groups;
}

# group(self, name, [expected_uuid]) resolves a current volume group.
sub group
{
my ($self, $name, $uuid) = @_;
name($name);
my $group = $self->inventory()->{$name} || die "LVM volume group is missing\n";
die "The LVM volume group was replaced\n" if ($uuid && $group->{'vg_uuid'} ne $uuid);
return $group;
}

# usable(volume) identifies ordinary disks, excluding pool internals.
sub usable
{
my ($volume) = @_;
return ($volume->{'segtype'} || '') =~ /\A(?:linear|striped|thin|snapshot)\z/ &&
	($volume->{'lv_attr'} || '') =~ /\A[-Vos][wr]/ &&
	($volume->{'lv_path'} || '') =~ m{\A/dev/};
}

# capacity(record) distinguishes a classic snapshot's origin from its COW store.
sub capacity
{
my ($record) = @_;
return number(($record->{'lv_attr'} || '') =~ /^s/ ? $record->{'origin_size'} : $record->{'lv_size'});
}

# identity(path) resolves a local LVM block device to its persistent LV UUID.
sub identity
{
my ($path) = @_;
my $volume = device($path);
return 'lvm:'.$volume->{'vg_uuid'}.':'.$volume->{'lv_uuid'};
}

# device(path, [driver]) resolves a block device, including /dev/mapper aliases.
# Inventory views may share a driver; mutation guards request fresh metadata.
sub device
{
my ($path, $driver) = @_;
my @stat = stat($path);
die "Cannot identify LVM block device\n" if (!@stat || !-b _);
$driver ||= __PACKAGE__->new();
# Device numbers match aliases without trusting the caller's path spelling.
foreach my $group (values %{$driver->inventory()}) {
	foreach my $volume (values %{$group->{'volumes'}}) {
		next if (!usable($volume) || !$volume->{'lv_path'});
		my @other = stat($volume->{'lv_path'});
		return $volume
			if (@other && -b _ && $stat[6] == $other[6]);
		}
	}
die "Block device is not a supported LVM logical volume\n";
}

# copy_to_file(path, destination, [limit]) stages opaque LV bytes for a worker.
# The parser sees only this private regular file, never a host block device.
sub copy_to_file
{
my ($path, $destination, $limit) = @_;
my $volume = device($path);
host_use($volume);
my $size = capacity($volume);
# A budget reduced by free space should report the storage shortage first.
die "Not enough free space for private image processing\n"
	if (Cloudmin::Worker::free_space(dirname($destination)) < $size + 256*1024**2);
die "Worker input exceeds the image byte limit\n" if (defined($limit) && $size > $limit);
# Check the opened device against the inventory before copying any bytes.
sysopen(my $in, $path, O_RDONLY) or die "Cannot open logical volume: $!\n";
my @opened = stat($in);
my @current = stat('/dev/block/'.$volume->{'lv_kernel_major'}.':'.$volume->{'lv_kernel_minor'});
die "The logical volume changed while opening it\n" if (!@opened || !@current || $opened[6] != $current[6]);
sysopen(my $out, $destination, O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW, 0600)
	or die "Cannot create private disk copy: $!\n";
my $remaining = $size;
while ($remaining) {
	my $read = sysread($in, my $buffer, $remaining > 1048576 ? 1048576 : $remaining);
	die "Cannot read logical volume at byte ".($size-$remaining).": $!\n" if (!defined($read));
	die "Logical volume ended at byte ".($size-$remaining)."; expected $size bytes\n" if (!$read);
	# Preserve empty regions without allocating their full virtual capacity.
	if ($buffer !~ /[^\0]/) {
		sysseek($out, $read, 1) // die "Cannot seek private disk copy\n";
		}
	else {
		# Partial writes are valid; finish the nonzero chunk before reading more.
		my $offset = 0;
		while ($offset < $read) {
			my $written = syswrite($out, $buffer, $read-$offset, $offset);
			die "Cannot write private disk copy\n" if (!$written);
			$offset += $written;
			}
		}
	$remaining -= $read;
	}
# A trailing hole still needs the full disk length in the private file.
truncate($out, $size) && close($out) or die "Cannot finish private disk copy\n";
close($in);
die "The logical volume changed during copying\n"
	if (identity($path) ne 'lvm:'.$volume->{'vg_uuid'}.':'.$volume->{'lv_uuid'});
}

# host_use(volume, [group_devices]) refuses host mounts, swap and device users.
# Callers separately check guest, snapshot and imported-image references.
# group_devices maps allowed major:minor numbers to true for a whole-group stop;
# volume must then include open_count. Without group_devices, refuse all holders.
sub host_use
{
my ($volume, $group_devices) = @_;
my $path = $volume->{'lv_path'};
my @stat = stat($path);
die "LVM device is inactive or missing\n" if (!@stat || !-b _);
my ($major, $minor) = @{$volume}{qw(lv_kernel_major lv_kernel_minor)};
die "Cannot identify the LVM device number\n"
	if (($major || '') !~ /\A\d+\z/ || !defined($minor) || $minor !~ /\A\d+\z/);
my @device = stat("/dev/block/$major:$minor");
die "The LVM device number changed\n" if (!@device || $device[6] != $stat[6]);
# Mount checks use device numbers, so alternate path names cannot hide use.
open(my $mounts, '<', '/proc/self/mountinfo') || die "Cannot check host mounts\n";
while (my $line = <$mounts>) {
	my @fields = split(/\s+/, $line);
	die "This logical volume is mounted on the host\n" if ($fields[2] eq "$major:$minor");
	}
close($mounts);
# Btrfs mountinfo uses an anonymous device number, not its backing devices.
btrfs_host_use("$major:$minor");
# Swap does not appear in mountinfo and needs a separate device check.
open(my $swap, '<', '/proc/swaps') || die "Cannot check host swap\n";
while (my $line = <$swap>) {
	my ($source) = split(/\s+/, $line);
	next if (!$source || $source !~ m{^/});
	my @other = stat($source);
	die "This logical volume supplies host swap\n" if (@other && -b _ && $stat[6] == $other[6]);
	}
close($swap);
# A holder can be a host filesystem's partition or another device-mapper layer.
my $holders = "/sys/dev/block/$major:$minor/holders";
opendir(my $dir, $holders) || die "Cannot check block-device dependencies\n";
my @holders = grep { $_ ne '.' && $_ ne '..' } readdir($dir);
closedir($dir);
foreach my $holder (@holders) {
	# Individual-volume operations cannot disturb any dependent block device.
	die "Other block devices depend on this logical volume\n" if (!$group_devices);
	open(my $dev, '<', "$holders/$holder/dev") || die "Cannot identify dependent block device\n";
	my $number = <$dev>;
	close($dev);
	chomp($number) if (defined($number));
	# Internal thin mappings stop with the group; outside dependants do not.
	die "Other block devices depend on this volume group\n"
		if (!defined($number) || !$group_devices->{$number});
	}
# Each internal holder accounts for one kernel open. Extra opens include raw
# disk users and mounts in other namespaces, even on internal thin devices.
die "This logical volume is open on the host\n"
	if ($group_devices && $volume->{'open_count'} > @holders);
return 1;
}

# group_host_use(self, group) checks every mapping before deactivating a VG.
# Device-mapper UUIDs cover thin-pool aliases and hidden data/metadata devices.
# group is a fresh inventory record with vg_uuid and volumes; nothing is stopped.
sub group_host_use
{
my ($self, $group) = @_;
(my $uuid = $group->{'vg_uuid'}) =~ s/-//g;
die "Cannot identify volume group devices\n" if ($uuid !~ /\A[a-zA-Z0-9]{32}\z/);
my $prefix = "LVM-$uuid";
my (@devices, %numbers);
foreach my $line (split(/\n/, $self->command('dm_info'))) {
	my ($id, $major, $minor, $open) = map { s/^\s+|\s+$//g; $_ } split(/\|/, $line, -1);
	# Exclude mappings from other groups before validating this group's report.
	next if (!defined($id) || index($id, $prefix) != 0);
	# The remaining UUID identifies the LV and optional internal mapping role.
	die "Cannot check volume group device state\n" if (
		$id !~ /\A\Q$prefix\E[a-zA-Z0-9]{32}(?:-[a-zA-Z0-9_-]+)?\z/ ||
		grep { !defined($_) || $_ !~ /\A\d+\z/ } ($major, $minor, $open));
	$numbers{"$major:$minor"} = 1;
	push(@devices, { lv_path => "/dev/block/$major:$minor",
		lv_kernel_major => $major, lv_kernel_minor => $minor, open_count => 0+$open });
	}
foreach my $lv (values %{$group->{'volumes'}}) {
	# A missing mapping must not make a known active LV appear safe to stop.
	next if (($lv->{'lv_active'} || '') ne 'active');
	die "LVM device inventory changed; retry\n" if (
		!$numbers{($lv->{'lv_kernel_major'} // '').':'.($lv->{'lv_kernel_minor'} // '')});
	}
# Build the full allowed set before testing dependencies between its mappings.
host_use($_, \%numbers) foreach @devices;
return 1;
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

# thin_id(base_uuid, thin_uuid) gives a thin destination a stable public UUID.
sub thin_id
{
my $id = substr(sha256_hex(join(':', 'cloudmin-lvm-thin', @_)), 0, 32);
substr($id, 12, 1) = '5';
substr($id, 16, 1) = sprintf('%x', 8 | (hex(substr($id, 16, 1)) & 3));
$id =~ s/\A(.{8})(.{4})(.{4})(.{4})(.{12})\z/$1-$2-$3-$4-$5/;
return $id;
}

package Cloudmin::LVM::Pool;
use strict;
use warnings;

# new(class, driver, native_pool, group, [thin_pool]) binds immutable LVM IDs.
sub new
{
my ($class, $driver, $native, $group, $thin) = @_;
return bless({ driver => $driver, native => $native, vg => $group->{'vg_name'},
	vg_uuid => $group->{'vg_uuid'}, thin => $thin ? $thin->{'lv_name'} : '',
	thin_uuid => $thin ? $thin->{'lv_uuid'} : '',
	id => $thin ? Cloudmin::LVM::thin_id($native->get_uuid_string(), $thin->{'lv_uuid'}) : $native->get_uuid_string() }, $class);
}

# group(self, [refresh]) rechecks the VG and thin-pool identities.
sub group
{
my ($self, $refresh) = @_;
$self->{'driver'}->inventory(1) if ($refresh);
my $group = $self->{'driver'}->group($self->{'vg'}, $self->{'vg_uuid'});
if ($self->{'thin'}) {
	# A recreated thin pool must not inherit its predecessor's public identity.
	my $thin = $group->{'volumes'}->{$self->{'thin'}};
	die "The LVM thin pool is missing or was replaced\n" if (!$thin ||
		$thin->{'lv_uuid'} ne $self->{'thin_uuid'} || $thin->{'segtype'} ne 'thin-pool');
	}
return $group;
}

# get_uuid_string(self) returns the selected destination's public ID.
sub get_uuid_string { return $_[0]->{'id'}; }
# get_name(self) distinguishes thin pools sharing one volume group.
sub get_name { return $_[0]->{'native'}->get_name().($_[0]->{'thin'} ? '/'.$_[0]->{'thin'} : ''); }
# is_persistent(self) follows the registered libvirt volume group.
sub is_persistent { return $_[0]->{'native'}->is_persistent(); }
# get_autostart(self) reports the volume group's boot policy.
sub get_autostart { return $_[0]->{'native'}->get_autostart(); }
# is_active(self) requires both the registered VG and the selected thin pool.
sub is_active
{
my ($self) = @_;
return 0 if (!$self->{'native'}->is_active());
return !$self->{'thin'} || $self->group()->{'volumes'}->{$self->{'thin'}}->{'lv_active'} eq 'active';
}

# refresh(self) refreshes both libvirt inventory and LVM metadata.
sub refresh
{
my ($self) = @_;
$self->{'native'}->refresh();
$self->group(1);
}

# get_info(self) reports physical space and thin data/metadata usage percentages.
sub get_info
{
my ($self) = @_;
my $group = $self->group();
# Thick allocations consume VG extents; thin allocations consume pool chunks.
return { state => $self->is_active() ? 2 : 0, capacity => $group->{'vg_size'},
	available => $group->{'vg_free'}, allocation => $group->{'vg_size'}-$group->{'vg_free'} }
	if (!$self->{'thin'});
my $thin = $group->{'volumes'}->{$self->{'thin'}};
# Missing usage is unsafe to treat as an empty pool, especially for metadata.
foreach my $field (qw(data_percent metadata_percent)) {
	die "Cannot read thin-pool usage; activate and check the pool\n"
		if (($thin->{$field} // '') !~ /\A\d+(?:\.\d+)?\z/ || $thin->{$field} > 100);
	}
my $allocation = int($thin->{'lv_size'}*$thin->{'data_percent'}/100);
return { state => $self->is_active() ? 2 : 0, capacity => $thin->{'lv_size'},
	allocation => $allocation, available => $thin->{'lv_size'}-$allocation,
	data_percent => 0+$thin->{'data_percent'}, metadata_percent => 0+$thin->{'metadata_percent'} };
}

# get_xml_description(self, [flags]) supplies metadata to Cloudmin's pool readers.
# Synthetic thin-pool XML is never submitted to libvirt.
sub get_xml_description
{
my ($self) = @_;
return $self->{'native'}->get_xml_description(0) if (!$self->{'thin'});
my $escape = \&Cloudmin::Libvirt::xml_escape;
return '<pool type="lvmthin"><name>'.$escape->($self->get_name()).'</name><uuid>'.
	$self->get_uuid_string().'</uuid><source><name>'.$escape->($self->{'vg'}).
	'</name><thin_pool>'.$escape->($self->{'thin'}).'</thin_pool></source><target><path>/dev/'.
	$escape->($self->{'vg'}).'</path></target></pool>';
}

# list_all_volumes(self, [flags]) excludes thin metadata and other destinations.
sub list_all_volumes
{
my ($self) = @_;
return map { Cloudmin::LVM::Volume->new($self, $_) }
	grep { Cloudmin::LVM::usable($_) && ($_->{'pool_lv'} || '') eq $self->{'thin'} }
	values %{$self->group()->{'volumes'}};
}

# aligned_capacity(self, bytes) rounds ordinary disks to complete VG extents.
# Thin volumes use sectors; their physical allocation follows the thin pool.
sub aligned_capacity
{
my ($self, $bytes) = @_;
my $unit = $self->{'thin'} ? 512 : $self->group()->{'vg_extent_size'};
return int(($bytes+$unit-1)/$unit)*$unit;
}

# create_volume(self, xml, [flags]) creates a raw LV without formatting any PV.
sub create_volume
{
my ($self, $xml, $flags) = @_;
die "Unsupported LVM volume flags\n" if ($flags);
die "Start the LVM storage pool first\n" if (!$self->is_active());
my $doc = Cloudmin::Libvirt::parse_xml_document($xml);
# Accept raw byte capacities only; reject names before calling Webmin.
my $name = Cloudmin::LVM::name($doc->findvalue('/volume/name'));
Cloudmin::LVM::device_path($self->{'vg'}, $name);
my $size = Cloudmin::LVM::number($doc->findvalue('/volume/capacity'));
die "Logical volumes must contain raw disks\n"
	if (($doc->findvalue('/volume/target/format/@type') || 'raw') ne 'raw');
die "Invalid logical volume capacity\n" if (!$size ||
	($doc->findvalue('/volume/capacity/@unit') || 'bytes') !~ /\A(?:bytes|B)\z/);
my $group = $self->group(1);
die "Destination logical volume already exists\n" if ($group->{'volumes'}->{$name});
my $info = $self->get_info();
# Thin disks reserve address space; ordinary LVs reserve physical extents.
die "Not enough free space in the LVM storage pool\n" if (!$self->{'thin'} && $size > $info->{'available'});
die "Extend the thin pool before allocating more disks\n" if ($self->{'thin'} &&
	($info->{'data_percent'} >= 95 || $info->{'metadata_percent'} >= 90 || !$info->{'available'}));
if ($self->{'thin'}) {
	# Thin allocation relies on the pool to zero new chunks and report health.
	my $thin = $group->{'volumes'}->{$self->{'thin'}};
	die "Enable zeroing on this thin pool before creating guest disks\n"
		if (($thin->{'zero'} || '') ne 'zero');
	die "Repair the thin pool before creating guest disks\n" if ($thin->{'lv_health_status'});
	}
# Webmin's helper accepts KiB and already supports thick and thin allocation.
$self->{'driver'}->create_logical_volume({name => $name, vg => $self->{'vg'},
	size => int(($size+1023)/1024), perm => $self->{'thin'} ? 'rw' : 'r', alloc => 'n',
	thin_in => $self->{'thin'}, size_of => ''});
$self->refresh();
my ($volume) = grep { $_->get_name() eq $name } $self->list_all_volumes();
die "Created logical volume is missing from storage inventory\n" if (!$volume);
# Thick LVs may contain data from a previous allocation. Erase all bytes before
# attaching an empty disk or uploading a shorter image. Thin pools zero chunks.
if (!$self->{'thin'}) {
	# A crash before tagging leaves a read-only disk, excluded from attachment.
	# Once writable, its durable marker blocks use until all old data is erased.
	my @identity = ('--select', 'lv_uuid='.$volume->{'uuid'});
	$self->{'driver'}->command('lvchange', '--addtag', 'cloudmin_zero_from_0', @identity);
	$self->{'driver'}->command('lvchange', '--permission', 'rw', @identity);
	$self->refresh();
	$volume->zero_range(0);
	$self->{'driver'}->command('lvchange', '--deltag', 'cloudmin_zero_from_0', @identity);
	$self->refresh();
	}
return $volume;
}

package Cloudmin::LVM::Volume;
use strict;
use warnings;
use Fcntl qw(O_RDONLY O_RDWR O_NOFOLLOW SEEK_SET);
use IO::Handle ();
use Errno qw(EOPNOTSUPP ENOTTY EINVAL);

# new(class, pool, record) retains UUID identity independently of device paths.
sub new
{
my ($class, $pool, $record) = @_;
return bless({ pool => $pool, name => $record->{'lv_name'}, uuid => $record->{'lv_uuid'} }, $class);
}

# record(self, [refresh]) refuses deleted, renamed or replaced logical volumes.
sub record
{
my ($self, $refresh) = @_;
my $record = $self->{'pool'}->group($refresh)->{'volumes'}->{$self->{'name'}};
die "The logical volume is missing or was replaced\n"
	if (!$record || $record->{'lv_uuid'} ne $self->{'uuid'} || !Cloudmin::LVM::usable($record) ||
	($record->{'pool_lv'} || '') ne $self->{'pool'}->{'thin'});
return $record;
}
# get_name(self) returns the logical volume name.
sub get_name { return $_[0]->{'name'}; }
# get_key(self) returns a persistent identity instead of a reusable device path.
sub get_key { return 'lvm:'.$_[0]->{'pool'}->{'vg_uuid'}.':'.$_[0]->{'uuid'}; }
# get_path(self) returns the verified current block-device path.
sub get_path
{
my ($self) = @_;
my $record = $self->record();
return Cloudmin::LVM::device_path($record->{'vg_name'}, $record->{'lv_name'});
}

# snapshot(self, name, [journal]) creates a restore point using Webmin LVM.
# The caller must stop guest writes and journal the name before allocation.
# journal(volume), when supplied, records the new UUID before tagging/activation.
sub snapshot
{
my ($self, $name, $journal) = @_;
my $pool = $self->{'pool'};
my $record = $self->record(1);
Cloudmin::LVM::host_use($record);
Cloudmin::LVM::device_path($pool->{'vg'}, $name);
die "Snapshot volume already exists\n" if ($pool->group()->{'volumes'}->{$name});
my $thin = $record->{'segtype'} eq 'thin';
# Reserve a full origin plus COW metadata so normal writes cannot fill a thick
# snapshot. Thin snapshots share their pool's data and metadata space.
my $bytes = $pool->aligned_capacity(int($record->{'lv_size'}*1.01)+16*1024**2);
my $info = $pool->get_info();
die "Not enough space for an LVM snapshot\n" if (!$thin && $bytes > $info->{'available'});
die "Extend the thin pool before taking a snapshot\n" if ($thin &&
	($info->{'data_percent'} >= 95 || $info->{'metadata_percent'} >= 90));
$pool->{'driver'}->create_logical_volume({name => $name, vg => $pool->{'vg'},
	size => int(($bytes+1023)/1024), size_of => '', perm => 'rw', alloc => 'n',
	is_snap => 1, snapof => $self->get_name(), thin_in => $pool->{'thin'}});
$pool->refresh();
my ($snapshot) = grep { $_->get_name() eq $name } $pool->list_all_volumes();
# Save ownership before later tagging or activation can fail.
die "Created LVM snapshot is missing\n" if (!$snapshot);
$journal->($snapshot) if ($journal);
$pool->{'driver'}->command('lvchange', '--addtag', 'cloudmin_snapshot',
	'--select', 'lv_uuid='.$snapshot->{'uuid'});
# LVM marks new thin snapshots to skip activation. Keep owned restore points
# readable now and after the registered volume group starts at boot.
$pool->{'driver'}->command('lvchange', '--setactivationskip', 'n', '--activate', 'y',
	'--select', 'lv_uuid='.$snapshot->{'uuid'}) if ($thin);
$pool->refresh();
return $snapshot;
}

# snapshot_health(self) rejects invalid or exhausted native restore points.
sub snapshot_health
{
my ($self) = @_;
my $record = $self->record(1);
die "The LVM snapshot is invalid or exhausted\n" if (
	$record->{'lv_health_status'} || ($record->{'lv_attr'} || '') =~ /^....[IS]/ ||
	(($record->{'lv_attr'} || '') =~ /^s/ &&
	 (($record->{'data_percent'} // '') !~ /\A\d+(?:\.\d+)?\z/ || $record->{'data_percent'} >= 100)));
return 1;
}

# get_info(self) reports the LV's virtual capacity and physical allocation.
sub get_info
{
my ($self) = @_;
my $record = $self->record();
my $allocation = $record->{'lv_size'};
if ($record->{'segtype'} eq 'thin') {
	# Thin disks report allocated chunks rather than their full address space.
	my $percent = $record->{'data_percent'};
	die "Cannot read thin-volume allocation\n" if (($percent // '') !~ /\A\d+(?:\.\d+)?\z/);
	$allocation = int($allocation*$percent/100);
	}
return { type => 1, capacity => Cloudmin::LVM::capacity($record), allocation => $allocation };
}

# get_xml_description(self, [flags]) describes raw block storage for callers.
sub get_xml_description
{
my ($self) = @_;
my $escape = \&Cloudmin::Libvirt::xml_escape;
my $info = $self->get_info();
return '<volume type="block"><name>'.$escape->($self->get_name()).'</name><key>'.
	$escape->($self->get_key()).'</key><capacity>'.$info->{'capacity'}.'</capacity><allocation>'.
	$info->{'allocation'}.'</allocation><target><path>'.$escape->($self->get_path()).
	'</path><format type="raw"/></target></volume>';
}

# write_file(self, path) copies validated raw bytes without parsing guest data.
# Comparing each chunk avoids allocating empty thin regions or rewriting them.
sub write_file
{
my ($self, $path) = @_;
die "LVM changes are disabled in read-only mode\n"
	if ($self->{'pool'}->{'driver'}->{'readonly'} || WebminCore::is_readonly_mode());
my $record = $self->record(1);
Cloudmin::LVM::host_use($record);
my @input = lstat($path);
# Root copies bytes only; disk formats must already be checked in the worker.
die "Logical volume input must be a regular raw file\n" if (!@input || !-f _ || -l _);
die "Raw disk exceeds logical volume capacity\n" if ($input[7] > $record->{'lv_size'});
sysopen(my $in, $path, O_RDONLY|O_NOFOLLOW) or die "Cannot read raw disk: $!\n";
sysopen(my $out, $record->{'lv_path'}, O_RDWR) or die "Cannot open logical volume: $!\n";
my @opened = stat($out);
my @current = stat('/dev/block/'.$record->{'lv_kernel_major'}.':'.$record->{'lv_kernel_minor'});
die "The logical volume changed while opening it\n" if (!@opened || !@current || $opened[6] != $current[6]);
my $offset = 0;
while ($offset < $input[7]) {
	if ($self->{'pool'}->{'thin'} && $offset % (128*1024**2) == 0) {
		# Recheck during long uploads, not just when the thin disk is allocated.
		$self->{'pool'}->group(1);
		my $info = $self->{'pool'}->get_info();
		die "Extend the thin pool before writing more disk data\n"
			if ($info->{'data_percent'} >= 95 || $info->{'metadata_percent'} >= 90);
		}
	my $length = $input[7]-$offset;
	# Read at most one MiB and compare it with the destination's current bytes.
	$length = 1048576 if ($length > 1048576);
	my $read = sysread($in, my $buffer, $length);
	die "Cannot read raw disk\n" if (!defined($read) || !$read);
	sysseek($out, $offset, SEEK_SET) // die "Cannot seek logical volume\n";
	my $previous = '';
	while (length($previous) < $read) {
		my $got = sysread($out, my $part, $read-length($previous));
		die "Cannot read logical volume\n" if (!$got);
		$previous .= $part;
		}
	if ($previous ne $buffer) {
		# Skipping identical chunks avoids unnecessary thin-pool allocation.
		sysseek($out, $offset, SEEK_SET) // die "Cannot seek logical volume\n";
		my $written = 0;
		while ($written < $read) {
			my $n = syswrite($out, $buffer, $read-$written, $written);
			die "Cannot write logical volume\n" if (!$n);
			$written += $n;
			}
		}
	$offset += $read;
	}
# Flush writes before the caller attaches the disk or records completion.
close($in) && $out->sync() && close($out) or die "Cannot finish writing logical volume\n";
$self->record(1);
}

# resize(self, bytes, [flags]) grows an LV without touching its guest filesystem.
sub resize
{
my ($self, $bytes, $flags) = @_;
die "Unsupported LVM resize flags\n" if ($flags);
$bytes = Cloudmin::LVM::number($bytes);
my $record = $self->record(1);
Cloudmin::LVM::host_use($record);
die "Shrinking logical volumes is not supported\n" if ($bytes < $record->{'lv_size'});
my $driver = $self->{'pool'}->{'driver'};
die "LVM changes are disabled in read-only mode\n"
	if ($driver->{'readonly'} || WebminCore::is_readonly_mode());
my $tag = $self->initialization_pending();
if ($bytes > $record->{'lv_size'}) {
	# A retry at the final size skips allocation and resumes only pending zeroing.
	if ($self->{'pool'}->{'thin'}) {
		# Growing a thin disk must retain the zeroing and health guarantees
		# checked when the disk was first allocated.
		my $group = $self->{'pool'}->group(1);
		my $thin = $group->{'volumes'}->{$self->{'pool'}->{'thin'}};
		my $info = $self->{'pool'}->get_info();
		die "Repair or extend the thin pool and enable zeroing before growing disks\n"
			if (($thin->{'zero'} || '') ne 'zero' || $thin->{'lv_health_status'} ||
				$info->{'data_percent'} >= 95 || $info->{'metadata_percent'} >= 90);
		}
	die "Not enough free space to grow the logical volume\n"
		if (!$self->{'pool'}->{'thin'} && $bytes-$record->{'lv_size'} > $self->{'pool'}->get_info()->{'available'});
	if (!$self->{'pool'}->{'thin'} && !$tag) {
		# Keep the old boundary on the LV so interrupted growth can finish zeroing.
		$tag = 'cloudmin_zero_from_'.$record->{'lv_size'};
		$driver->command('lvchange', '--addtag', $tag, '--select', 'lv_uuid='.$self->{'uuid'});
		}
	$driver->resize_logical_volume($record, $bytes);
	}
$self->{'pool'}->refresh();
if ($tag) {
	# Clear the durable marker only after every newly exposed byte is zeroed.
	my ($offset) = $tag =~ /_(\d+)$/;
	$self->zero_range($offset);
	$driver->command('lvchange', '--deltag', $tag, '--select', 'lv_uuid='.$self->{'uuid'});
	$self->{'pool'}->refresh();
	}
}

# initialization_pending(self) returns an unfinished creation/growth marker.
sub initialization_pending
{
my ($self) = @_;
my @tags = grep { /^cloudmin_zero_from_\d+$/ } split(/,/, $self->record()->{'lv_tags'} || '');
die "Conflicting logical volume initialization markers\n" if (@tags > 1);
return $tags[0];
}

# zero_range(self, offset) erases new thick extents before guest access resumes.
sub zero_range
{
my ($self, $offset) = @_;
die "LVM changes are disabled in read-only mode\n"
	if ($self->{'pool'}->{'driver'}->{'readonly'} || WebminCore::is_readonly_mode());
my $record = $self->record(1);
Cloudmin::LVM::host_use($record);
die "Invalid logical volume initialization boundary\n" if ($offset > $record->{'lv_size'});
sysopen(my $out, $record->{'lv_path'}, O_RDWR) or die "Cannot open logical volume: $!\n";
my @opened = stat($out);
my @current = stat('/dev/block/'.$record->{'lv_kernel_major'}.':'.$record->{'lv_kernel_minor'});
die "The logical volume changed while opening it\n" if (!@opened || !@current || $opened[6] != $current[6]);
sysseek($out, $offset, SEEK_SET) // die "Cannot seek logical volume\n";
my $remaining = $record->{'lv_size'}-$offset;
# BLKZEROOUT guarantees zero-filled reads, unlike ordinary discard. Linux can
# offload it to storage or punch zeroed holes in a loop-backed file. Keep the
# checked descriptor open so a renamed device cannot redirect initialization.
if ($remaining) {
	my $range = pack('QQ', $offset, $remaining);
	if (ioctl($out, 0x127f, $range)) { # Linux <linux/fs.h>: BLKZEROOUT
		# Successful zeroout covers the entire requested range.
		$remaining = 0;
		}
	elsif ($! != EOPNOTSUPP && $! != ENOTTY && $! != EINVAL) {
		# Only unsupported-operation errors permit the buffered-write fallback.
		die "Cannot zero logical volume: $!\n";
		}
	}
# Devices without the zeroout operation receive ordinary buffered zero writes.
my $zeros = "\0" x 1048576;
while ($remaining) {
	my $written = syswrite($out, $zeros, $remaining > length($zeros) ? length($zeros) : $remaining);
	die "Cannot zero logical volume\n" if (!$written);
	$remaining -= $written;
	}
$out->sync() && close($out) or die "Cannot finish initializing logical volume\n";
$self->record(1);
}

# delete(self, [flags]) removes only the UUID checked by the caller's usage guard.
sub delete
{
my ($self, $flags) = @_;
die "Unsupported LVM deletion flags\n" if ($flags);
Cloudmin::LVM::host_use($self->record(1));
$self->{'pool'}->{'driver'}->command('lvremove', '--yes', '--select', 'lv_uuid='.$self->{'uuid'});
$self->{'pool'}->refresh();
}

1;
