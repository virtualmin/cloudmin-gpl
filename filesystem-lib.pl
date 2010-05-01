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
		$cmd .= " && resize2fs ".quotemeta($device)." ".
			int($size/1024)."k";
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
	$cmd = "newfs ".quotemeta($device);
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
$err = &get_file_from_server($server, "/etc/fstab", $fstab);
&umount_filesystem_if_needed($server);
return "Failed to get /etc/fstab : $err" if ($err);

# Parse the file
open(FSTAB, $fstab);
while(<FSTAB>) {
	s/\r|\n//g;
	s/#.*$//g;
	my @r = split(/\s+/, $_);
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
my $vhost = &type_xen_parent($server);

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
$err = &put_file_to_server($server, $file, "/etc/fstab");
&umount_filesystem_if_needed($server);
return "Failed to write /etc/fstab : $err" if ($err);
return undef;
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
return $err if ($err);
return $out if ($ex);
my @rv;
my $p = 1;
my $secsize;
foreach my $l (split(/\r?\n/, $out)) {
	if ($l =~ /=\s+(\d+)\s+bytes/i) {
		$secsize = $1;
		}
	elsif ($l =~ /\s(\d+)\s+(\d+)\s+(\d+)\+?\s+([0-9a-f]+)\s+(\S+)/i) {
		# Found a partition line
		push(@rv, { 'part' => $p,
			    'start' => $1,
			    'start_bytes' => $1 * $secsize,
			    'end' => $2,
			    'end_bytes' => $2 * $secsize,
			    'blocks' => $3,
			    'size_bytes' => ($2 - $1 + 1) * $secsize,
			    'type' => $4,
			    'offset' => $1 * $secsize });
		$p++;
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

# create_disk_image_partition(&server, file, number, [size], [make-label])
# Creates a new partition on some empty disk image
sub create_disk_image_partition
{
my ($vhost, $real, $num, $size, $make_label) = @_;

if (&has_command_on_server($vhost, "parted")) {
	# Create the disk label with parted
	if ($make_label) {
		my ($out, $ex, $err) = &execute_command_on_server($vhost, 
			"parted -s ".quotemeta($real)." mklabel msdos");
		if ($ex || $err) {
			return "Failed to create disk label : ".($err || $out);
			}
		}

	# Create a partition
	my $mbs = $size ? int($size/1000000) : undef;
	my ($out, $ex, $err) = &execute_command_on_server($vhost,
                "parted -s ".quotemeta($real).
		" mkpartfs primary ext2 1 ".$mbs);
	if ($ex || $err) {
		return "Failed to create partition : ".($err || $out);
		}
	}
else {
	# Create input file for fdisk
	my $mbs = $size ? int($size/1024/1024) : undef;
	my $temp = &transname();
	&open_tempfile(TEMP, ">$temp");
	&print_tempfile(TEMP, "n\n");	 # New partition
	&print_tempfile(TEMP, "p\n");	 # Primary
	&print_tempfile(TEMP, "$num\n"); # First partition
	&print_tempfile(TEMP, "\n");	 # First cylinder
	if ($mbs) {
		&print_tempfile(TEMP, "+${mbs}M\n");	# Specific size
		}
	else {
		&print_tempfile(TEMP, "\n");		# Use full disk
		}
	&print_tempfile(TEMP, "w\n");	 # Write table
	&print_tempfile(TEMP, "q\n");	 # Quit
	&close_tempfile(TEMP);
	my $vhosttemp = &tempname_on_server($vhost);
	my $err = &put_file_to_server($vhost, $temp, $vhosttemp);
	&unlink_file($temp);

	# Create a partition with fdisk
	my ($out, $ex, $err) = &execute_command_on_server($vhost,
		"fdisk -u $real <$vhosttemp");
	&delete_file_on_server($vhost, $vhosttemp);
	if ($ex || $err) {
		return "Failed to create partition : ".($out || $err);
		}
	}

return undef;
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
		return "Failed to create new partition : ".($err || $out);
		}
	}
else {
	# Delete and re-create in fdisk .. create input file first
	my $temp = &transname();
	my $mbs = int($newsize/1024/1024);
	&open_tempfile(TEMP, ">$temp");
	&print_tempfile(TEMP, "d\n");	# Delete
	&print_tempfile(TEMP, $part->{'part'}."\n");	# Partition number
	&print_tempfile(TEMP, "n\n");	# New partition
	&print_tempfile(TEMP, "p\n");   # Primary
	&print_tempfile(TEMP, $part->{'part'}."\n");	# Same partition
	&print_tempfile(TEMP, $part->{'start'}."\n");	# Same start
	&print_tempfile(TEMP, "+${mbs}M\n");		# New size
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

1;

