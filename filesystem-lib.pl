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

1;

