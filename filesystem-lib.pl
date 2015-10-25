# Functions for getting and managing mounted filesystems

# get_device_filesystem(&server, device-file)
# Returns the code for the filesystem on some device, or undef if none
sub get_device_filesystem
{
my ($server, $device) = @_;
my ($out, $ex, $err);
for(my $i=0; $i<10; $i++) {
	# Try this over 10 seconds, as on EC2 it can take a short while for
	# a new device file for a volume to become active
	($out, $ex, $err) = &execute_command_on_server($server,
					"file -s ".quotemeta($device));
	last if (!$ex);
	sleep(1);
	}
if ($out =~ /(\S+)\s+filesystem\s+data/) {
	# EXT2 or 3 or XFS
	return lc($1);
	}
elsif ($out =~ /FAT\s+\(32/) {
	return "vfat";
	}
elsif ($out =~ /FAT\s+\((16|12)/) {
	return "fat";
	}
elsif ($out =~ /ReiserFS/) {
	return "reiserfs";
	}
else {
	# XXX what about Solaris?
	return undef;
	}
}

# create_device_filesystem(&server, device, fs, [size])
# Creates a new filesystem on some device. Returns undef on success, or an
# error message on failure.
sub create_device_filesystem
{
my ($server, $device, $fs, $size) = @_;
my $cmd;
if ($fs =~ /^ext\d+$/) {
	$cmd = "mkfs -t $fs -F ".quotemeta($device);
	if ($size) {
		$cmd .= " && ".&get_resize_command($server, $fs,
						   $device, int($size/(1024*1024)));
		}
	}
elsif ($fs eq 'reiserfs') {
	$cmd = "yes | mkreiserfs -f ".quotemeta($device);
	}
elsif ($fs eq 'xfs') {
	$cmd = "mkfs -t xfs -f ".quotemeta($device);
	}
elsif ($fs eq 'jfs') {
	$cmd = "mkfs -t jfs -q ".quotemeta($device);
	}
elsif ($fs eq 'swap') {
	$cmd = "mkswap ".quotemeta($device);
	if ($size) {
		$cmd .= " ".int($size/1024);
		}
	}
elsif ($fs eq 'ufs') {
	$cmd = "mkfs.ufs ".quotemeta($device);
	}
else {
	return "Unknown filesystem type $fs";
	}
my ($out, $ex, $err) = &execute_command_on_server($server, $cmd);
$err = $out if ($ex);
return $err;
}

# get_system_fstab(&server)
# Returns an array ref containing entries from a system's /etc/fstab file, in
# the same format as the regular file. Returns an error string on failure.
sub get_system_fstab
{
my ($server) = @_;
my (@rv, $mounted);

# Download fstab file
my $fstab = &transname();
my $err = &mount_filesystem_if_needed($server);
return $err if ($err);
$err = &get_file_from_server($server, "/etc/fstab", $fstab, 0, 0, 5);
&umount_filesystem_if_needed($server);
return "Failed to get /etc/fstab : $err" if ($err);

# Parse the file
open(FSTAB, $fstab);
while(<FSTAB>) {
	s/\r|\n//g;
	s/#.*$//g;
	my @r = split(/\s+/, $_);
	next if (!@r);	# Empty line
	if ($r[0] =~ /^dev\//) {
		# Fix stupid dev/sdaX line
		$r[0] = "/".$r[0];
		}
	push(@rv, \@r);
	}
close(FSTAB);
return \@rv;
}

# put_system_fstab(&server, &fstab)
# Write out the fstab file on a server, from an array ref of entries
sub put_system_fstab
{
my ($server, $fstab) = @_;
my $vhost = &get_parent_server($server);

# Create a temp file first
my $file = &transname();
&open_tempfile(FSTAB, ">$file", 0, 1);
foreach my $f (@$fstab) {
	&print_tempfile(FSTAB, join("\t", @$f)."\n");
	}
&close_tempfile(FSTAB);

# Upload the file
my $err = &mount_filesystem_if_needed($server);
return $err if ($err);
$err = &put_file_to_server($server, $file, "/etc/fstab", 0, 0, 5);
&umount_filesystem_if_needed($server);
return "Failed to write /etc/fstab : $err" if ($err);
return undef;
}

# sort_system_fstab(@fstab)
# Give a list of fstab entries, sort them so that the shortest mount point
# (like /) comes first
sub sort_system_fstab
{
my @fstab = @_;
return sort { length($a->[1]) <=> length($b->[1]) } @fstab;
}

# get_system_mounts(&server)
# Returns an array ref containing entries from a system's mounted filesystems,
# the same format as the regular file. Returns an error string on failure.
sub get_system_mounts
{
my ($server) = @_;
my (@rv, $mountcmd);

my ($out, $ex, $err);
if (&can_ssh_status($server)) {
	# Use mount command
	($out, $ex, $err) = &execute_command_on_server($server, "mount");
	return $err if ($err);
	return $out if ($ex);
	$mountcmd = 1;
	}
else {
	# Try the /etc/mtab file
	($out, $err) = &get_file_data_from_server($server, "/etc/mtab");
	return $err if ($err);
	}

# Parse the file
local $_;
foreach (split(/\r?\n/, $out)) {
	s/\r|\n//g;
	s/#.*$//g;
	my @r = split(/\s+/, $_);
	next if (!@r);	# Empty line
	if ($r[0] =~ /^dev\//) {
		# Fix stupid dev/sdaX line
		$r[0] = "/".$r[0];
		}
	if ($mountcmd) {
		# Mount command output has some extra columns
		@r = ( $r[0], $r[2], $r[4], $r[5] );
		$r[4] =~ s/^\((.*)\)$/$1/;
		}
	push(@rv, \@r);
	}
close(FSTAB);
return \@rv;
}

# mount_device_filesystem(&server, directory, device, filesystem)
# Mounts a filesystem on some virtual system. Returns undef on success, or an
# error message on failure.
sub mount_device_filesystem
{
my ($server, $mount, $device, $fs) = @_;
if ($server->{'status'} eq 'down' ||
    $server->{'status'} eq 'nohost' ||
    $server->{'status'} eq 'nossh' ||
    $server->{'status'} eq 'nosshlogin') {
	return "Filesystems cannot be mounted on systems in state ".
	       $server->{'status'};
	}
my $cmd = "mount";
if ($fs) {
	if ($server->{'type'} eq 'solaris') {
		$cmd .= " -F $fs";
		}
	else {
		$cmd .= " -t $fs";
		}
	}
if ($device) {
	$cmd .= " ".$device;
	}
if ($mount) {
	$cmd .= " ".$mount;
	}
my ($out, $ex, $err) = &execute_command_on_server($server,
	"test -d ".quotemeta($mount)." || mkdir -p ".quotemeta($mount));
my ($out, $ex, $err) = &execute_command_on_server($server, "$cmd 2>&1");
$err = $out if ($ex);
return $err;
}

# unmount_device_filesystem(&server, directory)
# Un-mount some mounted filesystem, and return undef on success or an error
# message on failure.
sub unmount_device_filesystem
{
my ($server, $mount) = @_;
my $cmd = "umount ".quotemeta($mount);
my ($out, $ex, $err) = &execute_command_on_server($server, "$cmd 2>&1");
$err = $out if ($ex);
return $err;
}

# list_disk_image_partitions(&server, file)
# Returns an array ref of information about partitions in some disk image
sub list_disk_image_partitions
{
my ($server, $fsfile) = @_;
my ($out, $ex, $err) = &execute_command_on_server($server,
	"fdisk -l -u ".quotemeta($fsfile));
return $err if ($err);	# Could not run fdisk
return $out if ($ex);	# fdisk failed
return $out if ($out =~ /valid\s+partition\s+table/i); # No partition table
return $out if ($out =~ /0\s+MB,\s+0\s+bytes/ &&       # Not a disk
		$out !~ /\n\Q$fsfile\E\d/);
my @rv;
my $p = 1;
my $secsize;
my $disklabel = 'dos';
foreach my $l (split(/\r?\n/, $out)) {
	if ($l =~ /=\s+(\d+)\s+bytes/i) {
		$secsize = $1;
		}
	elsif ($l =~ /Disk\s*label\s+type:\s+(\S+)/) {
		$disklabel = $1;
		}
	elsif ($l =~ /\s(\d+)\s+(\d+)\s+(\d+)\+?(\s+[0-9\.]+[kMGTP])?\s+([0-9a-f]+)\s+(\S+)/i &&
	       $disklabel eq "dos") {
		# Found a DOS format partition line
		push(@rv, { 'part' => $p,
			    'disklabel' => $disklabel,
			    'start' => $1,
			    'start_bytes' => $1 * $secsize,
			    'end' => $2,
			    'end_bytes' => $2 * $secsize,
			    'blocks' => $3,
			    'size_bytes' => ($2 - $1 + 1) * $secsize,
			    'type' => $5,
			    'offset' => $1 * $secsize });
		$p++;
		}
	elsif ($l =~ /\s\d+\s+(\d+)\s+(\d+)\s+(\d+\S+)\s+(\S.*\S)\s+(primary|logical|extended|ext\S+)/ && $disklabel eq "gpt") {
		# Found a GPT format partition line
		push(@rv, { 'part' => $p,
			    'disklabel' => $disklabel,
			    'start' => $1,
			    'start_bytes' => $1 * $secsize,
			    'end' => $2,
			    'end_bytes' => $2 * $secsize,
			    'blocks' => ($2 - $1) + 1,
			    'size_bytes' => ($2 - $1 + 1) * $secsize,
			    'type' => $4,
			    'offset' => $1 * $secsize });
		}
	}
$secsize || return "Sector size not found in disk image";

# Use parted to get offsets
($out, $ex, $err) = &execute_command_on_server($server,
	"parted -s ".quotemeta($fsfile)." unit B print");
foreach my $l (split(/\r?\n/, $out)) {
	$l =~ s/^\s+//;
	my ($n, $start, $end, $size, $type, $fs) = split(/\s+/, $l);
	if ($n =~ /^\d+$/) {
		my ($p) = grep { $_->{'part'} eq $n } @rv;
		if ($p) {
			$p->{'parted_start'} = $start;
			$p->{'parted_end'} = $end;
			$p->{'parted_size'} = $size;
			$p->{'parted_type'} = $type;
			$p->{'parted_fs'} = $fs;
			$p->{'start_bytes'} = &parse_parted_size($start);
			$p->{'end_bytes'} = &parse_parted_size($end);
			$p->{'size_bytes'} = &parse_parted_size($size);
			}
		}
	}
return \@rv;
}

# create_disk_image_partition(&server, file, [number], [size], [make-label],
#			      [bootable], [parted-type], [no-fs])
# Creates a new partition on some empty disk image. If no partition number
# is given, only the disk label is created.
sub create_disk_image_partition
{
my ($vhost, $real, $num, $size, $make_label, $bootable, $ptype) = @_;
$ptype ||= "ext2";

my $ver = &get_parted_version($vhost);
if ($ver && $ptype ne "ufs") {
	# Create the disk label with parted
	if ($make_label) {
		my $labeltype;
		if ($ver < 2) {
			# Old parted only supports DOS format reliably
			$labeltype = "msdos";
			}
		elsif ($config{'disk_format'} == 0) {
			# User wants old DOS format
			$labeltype = "msdos";
			}
		elsif ($config{'disk_format'} == 1) {
			# User wants new GPT format
			$labeltype = "gpt";
			}
		else {
			# Based on disk size
			$labeltype = $size >= 1024*1024*1024*1024 ?
					"gpt" : "msdos";
			}
		my ($out, $ex, $err) = &execute_command_on_server($vhost, 
			"parted -s ".quotemeta($real)." mklabel $labeltype");
		if ($ex || $err) {
			return "Failed to create disk label : ".($err || $out);
			}
		}

	# Create a partition
	if ($num) {
		my $mbs = $size ? int($size/1000/1000) : "100%";
		my ($out, $ex, $err) = &execute_command_on_server($vhost,
			"parted -s ".quotemeta($real)." ".
			"mkpart primary $ptype 1 ".$mbs);
		if ($ex || $err) {
			return "Failed to create partition : ".($err || $out);
			}

		# Make bootable
		if ($bootable) {
			my ($out, $ex, $err) =
			    &execute_command_on_server($vhost,
				"parted -s ".quotemeta($real).
				" set $num boot on");
			if ($ex || $err) {
				return "Failed to make bootable : ".
					($err || $out);
				}
			}
		}
	}
else {
	# Create input file for fdisk
	my $mbs = $size ? int($size/1000000) : undef;
	if ($mbs) {
		# Force round down by 8M, as fdisk on some systems won't allow
		# creation of a partition that occupies the whole disk
		$mbs -= 8;
		}
	my $temp = &transname();
	&open_tempfile(TEMP, ">$temp");
	if ($num) {
		&print_tempfile(TEMP, "n\n");	 # New partition
		&print_tempfile(TEMP, "p\n");	 # Primary
		&print_tempfile(TEMP, "$num\n"); # First partition
		&print_tempfile(TEMP, "\n");	 # First cylinder
		if ($mbs) {
			&print_tempfile(TEMP, "+${mbs}MB\n");	# Specific size
			}
		else {
			&print_tempfile(TEMP, "\n");	 # Use full disk
			}
		if ($bootable) {
			&print_tempfile(TEMP, "a\n");	 # Add bootable flag
			&print_tempfile(TEMP, "$num\n"); # First partition
			}
		if ($ptype eq "ufs") {
			# Set BSD partition type
			&print_tempfile(TEMP, "t\n");	# Change type
			&print_tempfile(TEMP, "a5\n");	# BSD
			}
		}
	&print_tempfile(TEMP, "w\n");	 # Write table
	&print_tempfile(TEMP, "q\n");	 # Quit
	&close_tempfile(TEMP);
	my $vhosttemp = &tempname_on_server($vhost);
	my $err = &put_file_to_server($vhost, $temp, $vhosttemp);
	&unlink_file($temp);

	# Create a partition with fdisk, by running the script
	my ($out, $ex, $err) = &execute_command_on_server($vhost,
		"fdisk -u $real <$vhosttemp");
	&delete_file_on_server($vhost, $vhosttemp);
	if ($err || $ex && $out !~ /The kernel still uses the old table/) {
		return "Failed to create partition : ".($out || $err);
		}
	}

return undef;
}

# get_resize_command(&vhost, fs-type, device, [size-in-mb])
# Returns the appropriate command to resize an EXT filesystem of some type
sub get_resize_command
{
my ($vhost, $fs, $dev, $size) = @_;
my $cmd;
if ($fs =~ /ext(\d+)$/) {
	# Use extN resize command if there is one, or otherwise
	# fall back to resize2fs
	$cmd = "resize".$1."fs";
	if (!&has_command_on_server($vhost, $cmd)) {
		$cmd = "resize2fs";
		}
	$cmd .= " ".quotemeta($dev);
	if ($size) {
		$cmd .= " ".$size."M";
		}
	}
elsif ($fs eq "ufs") {
	# Use linux port of growfs.ufs
	$cmd = "growfs.ufs -y";
	if ($size) {
		$cmd .= " -s ".int(($size-64) * 2048);
		}
	$cmd .= " ".quotemeta($dev);
	}
elsif ($fs eq "xfs") {
	# Special XFS resize command only works
	# on a mounted filesystem!
	my $mp = &tempname_on_server($vhost);
	$cmd = "(mkdir -p ".quotemeta($mp)." && ".
	       "mount -t xfs $dev $mp && ".
	       "xfs_growfs";
	if ($size) {
		$cmd .= " -D ".int(($size-64) * 1024 * 1024 / 4096);
		}
	else {
		$cmd .= " -d";
		}
	$cmd .= " ".quotemeta($mp);
	$cmd .= " ; ex=\$? ; umount $mp ; rmdir $mp ; exit \$ex)";
	}
return $cmd;
}

# get_fsck_command(&vhost, fs-type, [device])
# Returns a command to fsck an disk filesystem of some type
sub get_fsck_command
{
my ($vhost, $fs, $dev) = @_;
my $cmd;
if ($fs =~ /ext(\d+)$/) {
	$cmd = "e".$1."fsck";
	if (!&has_command_on_server($vhost, $cmd)) {
		$cmd = "fsck.".$fs;
		}
	if (!&has_command_on_server($vhost, $cmd) && $1 < 4) {
		$cmd = "e2fsck";
		}
	}
elsif ($fs eq "ufs") {
	$cmd = "fsck.ufs -y";
	}
elsif ($fs eq "xfs") {
	$cmd = "fsck.xfs -y";
	}
if ($cmd && $dev) {
	$cmd .= " -f -p ".quotemeta($dev);
	}
return $cmd;
}

# resize_disk_image_partition(&server, file, &partition, new-size)
# Expands the size of some partition by deleting and re-creating it
sub resize_disk_image_partition
{
my ($vhost, $real, $part, $newsize) = @_;
if (&has_command_on_server($vhost, "parted")) {
	# Delete and re-create with parted
	my ($out, $ex, $err) = &execute_command_on_server($vhost, 
		"parted -s ".quotemeta($real)." rm ".$part->{'part'});
	if ($ex || $err) {
		return "Failed to delete old partition : ".($err || $out);
		}

	my ($out, $ex, $err) = &execute_command_on_server($vhost,
		"parted -s ".quotemeta($real)." mkpart ".
		$part->{'parted_type'}." ".
		$part->{'parted_start'}." ".
		int($newsize/1000000)."M");
	if ($ex || $err) {
		# Oh crap .. try to put back the old partition size
		&execute_command_on_server($vhost,
			"parted -s ".quotemeta($real)." mkpart ".
			$part->{'parted_type'}." ".
			$part->{'parted_start'}." ".
			$part->{'parted_end'});
		return "Failed to create new partition : ".($err || $out);
		}
	}
else {
	# Delete and re-create in fdisk .. create input file first
	my $temp = &transname();
	my $mbs = int($newsize/1000/1000);
	&open_tempfile(TEMP, ">$temp");
	&print_tempfile(TEMP, "d\n");	# Delete
	&print_tempfile(TEMP, $part->{'part'}."\n");	# Partition number
	&print_tempfile(TEMP, "n\n");	# New partition
	&print_tempfile(TEMP, "p\n");   # Primary
	&print_tempfile(TEMP, $part->{'part'}."\n");	# Same partition
	&print_tempfile(TEMP, $part->{'start'}."\n");	# Same start
	&print_tempfile(TEMP, "+${mbs}MB\n");		# New size
	&print_tempfile(TEMP, "w\n");	 # Write table
	&print_tempfile(TEMP, "q\n");	 # Quit
	&close_tempfile(TEMP);
	my $vhosttemp = &tempname_on_server($vhost);
	my $err = &put_file_to_server($vhost, $temp, $vhosttemp);
	&unlink_file($temp);

	# Run input file
	my ($out, $ex, $err) = &execute_command_on_server($vhost,
		"fdisk -u ".quotemeta($real)." <$vhosttemp");
	&delete_file_on_server($vhost, $vhosttemp);
	if (($ex && $out !~ /WARNING:/) || $err) {
		return "Failed to delete and re-create partition : ".
		       ($out || $err);
		}
	}

return undef;
}

# delete_disk_image_partition(&server, file, partition-num)
# Deletes a single partition from a disk image
sub delete_disk_image_partition
{
my ($vhost, $real, $part) = @_;
$real || return "Missing device to delete partition from";
if (&has_command_on_server($vhost, "parted")) {
	# Delete with parted
	my ($out, $ex, $err) = &execute_command_on_server($vhost, 
		"parted -s ".quotemeta($real)." rm ".$part);
	if ($ex || $err) {
		return "Failed to delete old partition : ".($err || $out);
		}
	}
else {
	# Delete with fdisk
	my $temp = &transname();
	&open_tempfile(TEMP, ">$temp");
	&print_tempfile(TEMP, "d\n");	# Delete
	&print_tempfile(TEMP, $part->{'part'}."\n");	# Partition number
	&print_tempfile(TEMP, "w\n");	 # Write table
	&print_tempfile(TEMP, "q\n");	 # Quit
	&close_tempfile(TEMP);
	my $vhosttemp = &tempname_on_server($vhost);
	my $err = &put_file_to_server($vhost, $temp, $vhosttemp);
	&unlink_file($temp);

	# Run input file
	my ($out, $ex, $err) = &execute_command_on_server($vhost,
		"fdisk -u ".quotemeta($real)." <$vhosttemp");
	&delete_file_on_server($vhost, $vhosttemp);
	if ($ex || $err) {
		return "Failed to delete and re-create partition : ".
		       ($out || $err);
		}
	}
return undef;
}

# delete_all_disk_image_partitions(&vhost, real)
# Delete all partitions from some disk
sub delete_all_disk_image_partitions
{
my ($vhost, $real) = @_;
my $parts = &list_disk_image_partitions($vhost, $real);
if (ref($parts)) {
	my $err;
	foreach my $p (reverse(@$parts)) {
		$err ||= &delete_disk_image_partition($vhost, $real,
						      $p->{'part'});
		}
	return $err;
	}
return $parts;
}

# create_disk_image_filesystem(&server, device, filesystem, [partition], [size])
# Creates a filesystem on a partition using parted
sub create_disk_image_filesystem
{
my ($vhost, $real, $fs, $pnum, $size) = @_;
$pnum ||= 1;
my $parts = &list_disk_image_partitions($vhost, $real);
ref($parts) || return "Failed to list partitions on $real : $parts";
$pnum <= @$parts || return "Requested partition $pnum, but disk only has ".
			   scalar(@$parts)." partitions";
my $part = $parts->[$pnum-1];
$part || return "No partition $pnum found!";
$size ||= $part->{'size_bytes'};
my ($ok, $loop) = &loopback_mount_partition($vhost, $real, $part);
$ok || return $loop;
my $err = &create_device_filesystem($vhost, $loop, $fs, $size);
&loopback_unmount_partition($vhost, $loop);
return $err;
}

# parse_parted_size(string)
# Converts a string like 16.4kb or 200M into bytes
sub parse_parted_size
{
my ($str) = @_;
if ($str =~ /^([0-9]+)B/) {
	return $1;
	}
elsif ($str =~ /^([0-9\.]+)k/) {
	return int($1 * 1000);
	}
elsif ($str =~ /^([0-9\.]+)M/) {
	return int($1 * 1000 * 1000);
	}
elsif ($str =~ /^([0-9\.]+)G/) {
	return int($1 * 1000 * 1000 * 1000);
	}
elsif ($str =~ /^([0-9\.]+)T/) {
	return int($1 * 1000 * 1000 * 1000 * 1000);
	}
elsif ($str =~ /^([0-9\.]+)P/) {
	return int($1 * 1000 * 1000 * 1000 * 1000 * 1000);
	}
else {
	return int($str);
	}
}

# cleanup_server_fstab(&server)
# Gets the fstab file for a virtual system, removes entries for disks that 
# don't exist, and then writes it back out.
sub cleanup_server_fstab
{
my ($server) = @_;
my $dfunc = "type_".$server->{'manager'}."_list_disks";
my $disks = &$dfunc($server);
ref($disks) || return "Failed to list disks : $disks";
my %virts = map { $_->{'virt'}, $_ } @$disks;

my $fstab = &get_system_fstab($server);
ref($fstab) || return "Failed to read fstab file : $fstab";
my @newfstab;
foreach my $f (@$fstab) {
	my $ok = 1;
	if ($f->[0] =~ /^(\/dev\/(h|s|d|xv|v)d[a-z])(\d*)$/ && $f->[1] ne "/") {
		# If device is /dev/xvdX and no disk for that exists, remove it
		if (!$virts{$1} && !$virts{$f->[0]}) {
			$ok = 0;
			}
		}
	elsif (($f->[0] eq "LABEL=/" || $f->[0] eq "LABEL=root") &&
	       $server->{'image'}) {
		# Assume that first partition on first disk is /
		$f->[0] = $disks->[0]->{'virt'}."1";
		}
	push(@newfstab, $f) if ($ok);
	}
return &put_system_fstab($server, \@newfstab);
}

# get_label_map(&server)
# Returns a hash map from a labels (like /) to partitions like /dev/hda1
sub get_label_map
{
my ($server) = @_;

# Use cached label map if down
my %defrv = map { split(/=/, $_) } split(/\s+/, $server->{'label_map'});
return %defrv if (!&can_ssh_status($server));

# Find all partitions
my ($data, $ex, $err) = &execute_command_on_server($server,
						   "cat /proc/partitions");
return %defrv if ($ex || $er);
foreach my $l (split(/\r?\n/, $data)) {
	if ($l =~ /\d+\s+\d+\s+\d+\s+([a-z]+)(\d+)/) {
		push(@parts, "/dev/$1$2");
		}
	}
if (!@parts) {
	return ();
	}

# For each partition, get the label
my @cmds = map { "e2label $_ 2>/dev/null || echo NONE" } @parts;
my ($out, $ex, $err) = &execute_command_on_server($server, join(" ; ", @cmds));
my @lines = split(/\r?\n/, $out);
my %rv;
for(my $i=0; $i<@parts; $i++) {
	if ($lines[$i] ne 'NONE') {
		$rv{$lines[$i]} = $parts[$i];
		}
	}

# Also get the disk UUIDs
my ($out, $ex, $err) = &execute_command_on_server($server,
						  "ls -l /dev/disk/by-uuid");
if (!$ex && !$err) {
	foreach my $line (split(/\r?\n/, $out)) {
		if ($line =~ /(\S+)\s+\-\>\s+(\S+)/) {
			my ($uuid, $dev) = ($1, $2);
			$dev = &simplify_path("/dev/disk/by-uuid/$dev");
			$rv{$uuid} = $dev;
			}
		}
	}

return %rv;
}

# generate_label_map(&server)
# Set the label_map field on a server based on disks
sub generate_label_map
{
my ($server) = @_;
my $dfunc = "type_".$server->{'manager'}."_list_disks";
return if (!defined(&$dfunc));
my $disks = &$dfunc($server, 1);
return if (!ref($disks));
my %rv;
foreach my $d (@$disks) {
	if ($d->{'virt_label'}) {
		$rv{$d->{'virt_label'}} = $d->{'virt_mount'};
		}
	}
$server->{'label_map'} = join(" ", map { $_."=".$rv{$_} } keys %rv);
}

# delete_mapper_entries(&vhost, vg-name, lv-name)
# Calls dmsetup remove on all mappers for partitions on a disk
sub delete_mapper_entries
{
my ($vhost, $vg, $lv) = @_;
my $mapper = $vg."-".$lv;
my $dashvg = $vg;
$dashvg =~ s/\-/\-\-/g;
my $dashmapper=  $dashvg."-".$lv;
my $files = &list_dir_on_server($vhost, "/dev/mapper");
my $err;
if (ref($files)) {
	my @delmaps;
	foreach my $f (@$files) {
		if ($f =~ /^\Q$mapper\Ep?\d+$/ ||
		    $f =~ /^\Q$dashmapper\Ep?\d+$/) {
			push(@delmaps, $f);
			}
		}
	foreach my $f (@$files) {
		if ($f eq $mapper || $f eq $dashmapper) {
			push(@delmaps, $f);
			}
		}
	foreach my $f (@delmaps) {
		my ($cout, $cex, $cerr) = &execute_command_on_server($vhost,
			"dmsetup remove /dev/mapper/$f");
		$cerr = $cout if ($cex);
		$err ||= $cerr;
		&execute_command_on_server($vhost,
			"dmsetup remove /dev/mapper/$f-cow");
		}
	}
else {
	$err = $files;
	}
return $err;
}

# find_snapshot_source_logical_volume(&server, vg, lv)
# Checks for an LV with the given volume group and name, but which is not
# owned by any system. If one is found, returns the device path to it.
# Used when deleting the source of a snapshot when the original system has
# been removed.
sub find_snapshot_source_logical_volume
{
my ($server, $vg, $lv) = @_;
my $user;
my $t = $server->{'manager'};
foreach my $s (&list_managed_servers()) {
	next if ($s->{'manager'} ne $t ||
		 $s->{'id'} eq $server->{'id'} ||
		 $s->{$t.'_filesystem_vg'} ne $server->{$t.'_filesystem_vg'});
	my $dfunc = "type_".$t."_list_disks";
	my $sdisks = defined(&$dfunc) ? &$dfunc($s) : undef;
	if (!ref($sdisks)) {
		# Cannot be sure
		$user = $s;
		last;
		}
	my ($sd) = grep { $_->{'vg'} eq $vg && $_->{'lv'} eq $lv } @$sdisks;
	if ($sd) {
		$user = $s;
		last;
		}
	}
return $user ? undef : "/dev/$vg/$lv";
}

# split_lvm_device(path)
# Given an LVM device path like /dev/vg/lv , return vg and lv
sub split_lvm_device
{
my ($path) = @_;
if ($path =~ /^\/dev\/([^\/]+)\/([^\/]+)$/) {
	return ($1, $2);
	}
return ( );
}

# get_mounted_map(&server)
# Returns hash ref from mount device to mount point
sub get_mounted_map
{
my %mounted;
my ($out, $ex, $err) = &execute_command_on_server($server, "mount");
foreach my $l (split(/\r?\n/, $out)) {
	my ($dev, $on, $mp) = split(/\s+/, $l);
	$mounted{$dev} = $mp;
	}
($out, $ex, $err) = &execute_command_on_server($server, "cat /proc/swaps");
foreach my $l (split(/\r?\n/, $out)) {
	my ($dev) = split(/\s+/, $l);
	$mounted{$dev} = 'swap';
	}
return \%mounted;
}

# loopback_mount_partition(host, disk-image, partition-number|&part)
# Finds a free loopback device and maps it to a particular partition in a disk
# image, then returns an OK flag and the device path or error message.
sub loopback_mount_partition
{
my ($vhost, $real, $pnum) = @_;
my $part;
if (ref($pnum)) {
	# Partition object given
	$part = $pnum;
	}
else {
	# Need to find partition
	my $parts = &list_disk_image_partitions($vhost, $real);
	ref($parts) || return (0, "Failed to list partitions : $parts");
	@$parts || return (0, "Disk has no partitions!");
	if (!defined($pnum)) {
		# No partition number given, assume last non-swap/extended
		for(my $i=0; $i<@$parts; $i++) {
			if ($parts->[$i]->{'type'} ne '82' &&
			    $parts->[$i]->{'type'} ne '5') {
				$pnum = $i + 1;
				}
			}
		if (!defined($pnum)) {
			# Fall back to last one
			$pnum = scalar(@$parts);
			}
		}
	$part = $parts->[$pnum-1];
	}
my $loop = &get_loop_device($vhost);
my ($out, $ex, $err) = &execute_command_on_server($vhost,
	"losetup -o $part->{'offset'} $loop ".quotemeta($real));
if ($ex || $err) {
	return (0, "losetup failed : ".($err || $out));
	}
return (1, $loop);
}

# loopback_unmount_partition(host, loopback-device)
# Removes a previously setup loopback device
sub loopback_unmount_partition
{
my ($vhost, $loop) = @_;
&execute_command_on_server($vhost, "losetup -d $loop");
}

# list_directories()
# Returns a list of common directories for storing disk images. Fields for each
# are :
#   dir - Full path to the directory
#   desc - Human-readable description
#   managers - Space-separated list of virtualization types (empty for all)
#   plans - IDs of plans whose owners can use this directory (empty for all,
#   	    "none" for root only)
#   hosts - Host system IDs this directory is for (empty for all)
sub list_directories
{
my @rv;
my $got_def;

# Get directories users have created
opendir(STORAGES, $disk_directories_dir);
foreach my $f (readdir(STORAGES)) {
	next if ($f eq "." || $f eq "..");
	my %directory;
	&read_file("$disk_directories_dir/$f", \%directory);
	$directory{'id'} = $f;
	push(@rv, \%directory);
	if (!$directory{'dir'}) {
		$got_def = \%directory;
		}
	}
closedir(STORAGES);

# Fake up entry for defaults
if (!$got_def) {
	unshift(@rv, { 'dir' => '',
		       'id' => 1,
		       'default' => 1,
		       'desc' => 'Default directory or LV on host',
		       'managers' => '',
		       'plans' => '',
		       'hosts' => '' });
	}

return @rv;
}

# list_available_directories()
# Returns directories the current user can use
sub list_available_directories
{
my @rv;
foreach my $dir (&list_directories()) {
	if (!$access{'owner'}) {
		# Root can access everything
		push(@rv, $dir);
		}
	elsif ($dir->{'plans'} eq '') {
		# Dir is available to all
		push(@rv, $dir);
		}
	elsif ($dir->{'plans'} ne 'none') {
		# Check owner's plan
		foreach my $pid (split(/\s+/, $dir->{'plans'})) {
			if ($pid eq $access{'plan'}) {
				push(@rv, $dir);
				last;
				}
			}
		}
	}
return @rv;
}

# list_available_directories_for_manager(manager)
# Returns directories usable by some virtualization type
sub list_available_directories_for_manager
{
my ($manager) = @_;
my @rv;
foreach my $dir (&list_available_directories()) {
	if ($dir->{'managers'} &&
	    &indexof($manager, split(/\s+/, $dir->{'managers'})) < 0) {
		next;
		}
	push(@rv, $dir);
	}
return @rv;
}

# get_directory(id)
# Returns a disk file directory, looked up by ID
sub get_directory
{
my ($id) = @_;
my ($rv) = grep { $_->{'id'} eq $id } &list_directories();
return $rv;
}

# save_directory(&directory)
# Create or update a disk file directory
sub save_directory
{
my ($directory) = @_;
if (!-d $disk_directories_dir) {
	&make_dir($disk_directories_dir, 0700);
	}
$directory->{'id'} ||= &server_id();
&lock_file("$disk_directories_dir/$directory->{'id'}");
&write_file("$disk_directories_dir/$directory->{'id'}", $directory);
&unlock_file("$disk_directories_dir/$directory->{'id'}");
}

# delete_directory(&delete)
# Delete an existing disk file directory (but not files in it)
sub delete_directory
{
my ($directory) = @_;
&unlink_logged("$disk_directories_dir/$directory->{'id'}");
}

# validate_directory(&server, [&for-vhost], [field])
# Checks if the directory field of the server object is usable by the current
# user and on the selected host system. Returns an error message if not.
sub validate_directory
{
my ($server, $vhost, $field) = @_;
$field ||= 'directory';
if ($server->{'force_directory'} && &can_action($server, "global")) {
	return undef;	# Assume OK
	}

# If the directory is the virtualization type default for the host, just use it
$vhost ||= &get_parent_server($server);
if ($server->{$field} eq $vhost->{$server->{'manager'}.'_dir'}) {
	return undef;
	}

# Does this directory exist at all, and can it be used?
my @dirs = &list_directories();
my @matchdirs = grep { $_->{'dir'} eq $server->{$field} } @dirs;
@matchdirs || return $text{'directory_evdir'};
@dirs = &list_available_directories();
my @availdirs = grep { $_->{'dir'} eq $server->{$field} } @dirs;
@availdirs || return $text{'directory_evdir2'};

# Check each possible dir
my $lasterr;
foreach my $dir (@availdirs) {
	# Ok for host?
	if ($dir->{'hosts'} &&
	    &indexof($vhost->{'id'}, split(/\s+/, $dir->{'hosts'})) < 0) {
		$lasterr = &text('directory_evhost', $vhost->{'host'});
		next;
		}

	# Ok for virtualization type?
	if ($dir->{'managers'} &&
	    &indexof($server->{'manager'},
		     split(/\s+/, $dir->{'managers'})) < 0) {
		$lasterr = &text('directory_evmanager',
				 $text{$server->{'manager'}.'_typedesc'});
		next;
		}

	return undef;
	}
return $lasterr;
}

# directory_selector(type, [value], [exclude-default])
# Returns a field for choosing a disk image directory chooser for some system
# type. May return undef if there are no choices.
sub directory_selector
{
my ($manager, $value, $nodef) = @_;
my @dirs = &list_available_directories_for_manager($manager);
if ($nodef) {
	@dirs = grep { $_->{'dir'} } @dirs;
	}
if (@dirs == 1 && $dirs[0]->{'dir'} eq '') {
	# Just one directory, and it is for the host system default .. so no
	# need for a selector
	return undef;
	}
elsif (@dirs) {
	# Possibly multiple directories to choose from
	@dirs = sort { $a->{'dir'} cmp $b->{'dir'} } @dirs;
	return &ui_select("directory", $value,
		  [ map { [ $_->{'dir'},
			    $_->{'dir'} ?
				$_->{'dir'}." (".$_->{'desc'}.")" :
				$_->{'desc'} ] }
			@dirs ], 1, 0, $value ? 1 : 0);
	}
else {
	# No directories available
	return "<i>$text{'create_nodirectory'}</i>";
	}
}

# get_parted_version(&vhost)
# If a system has parted installed, return the verison number. Otherwise return
# undef.
sub get_parted_version
{
my ($vhost) = @_;
my ($out, $ex, $err) = &execute_command_on_server($vhost, "parted -v");
return undef if ($ex || $err);
if ($out =~ /^.*parted.*\s([0-9\.]+)/) {
	return $1;
	}
return undef;
}

1;

