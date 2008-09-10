# Functions for getting and managing mounted filesystems

# get_device_filesystem(&server, device-file)
# Returns the code for the filesystem on some device, or undef if none
sub get_device_filesystem
{
local ($server, $device) = @_;
local ($out, $ex, $err);
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

# create_device_filesystem(&server, device, fs)
# Creates a new filesystem on some device. Returns undef on success, or an
# error message on failure.
sub create_device_filesystem
{
local ($server, $device, $fs) = @_;
local $cmd;
if ($fs =~ /^ext\d+$/) {
	$cmd = "mkfs -t $fs -F ".quotemeta($device);
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
	}
elsif ($fs eq 'ufs') {
	$cmd = "newfs ".quotemeta($device);
	}
else {
	return "Unknown filesystem type $fs";
	}
local ($out, $ex, $err) = &execute_command_on_server($server, $cmd);
$err = $out if ($ex);
return $err;
}

# get_system_fstab(&server)
# Returns an array ref containing entries from a system's /etc/fstab file, in
# the same format as the regular file. Returns an error string on failure.
sub get_system_fstab
{
local ($server) = @_;
local (@rv, $mounted);
if ($server->{'status'} eq 'down' && $server->{'manager'} eq 'xen') {
	# Fetch /etc/fstab from root filesystem
	local $vhost = &type_xen_parent($server);
	if (!$server->{'xen_mount'}) {
		# Mount image on temp directory on vhost
		local $err = &type_xen_mount_filesystem($server);
		return $err if ($err);
		$mounted++;
		}
	$fstab = &transname();
	local $err = &get_file_from_server($vhost,
		"$server->{'xen_mount'}/etc/fstab", $fstab);
	return "Failed to get $server->{'xen_mount'}/etc/fstab : $err"
		if ($err);
	}
elsif ($server->{'status'} ne 'nohost' && $server->{'status'} ne 'down') {
	# Get from /etc/fstab on system directly
	$fstab = &transname();
	local $err = &get_file_from_server($server, "/etc/fstab", $fstab);
	return "Failed to get /etc/fstab : $err" if ($err);
	}
else {
	return "The /etc/fstab file cannot be fetched from systems in state ".
	       $server->{'status'};
	}
if ($fstab) {
	# Parse the file
	open(FSTAB, $fstab);
	while(<FSTAB>) {
		s/\r|\n//g;
		s/#.*$//g;
		push(@rv, [ split(/\s+/, $_) ]);
		}
	close(FSTAB);
	}
&type_xen_umount_filesystem($server) if ($mounted);
return \@rv;
}

# put_system_fstab(&server, &fstab)
# Write out the fstab file on a server, from an array ref of entries
sub put_system_fstab
{
local ($server, $fstab) = @_;

# Create a temp file first
local $file = &transname();
&open_tempfile(FSTAB, ">$file", 0, 1);
foreach my $f (@$fstab) {
	&print_tempfile(FSTAB, join("\t", @$f)."\n");
	}
&close_tempfile(FSTAB);

if ($server->{'status'} eq 'down' && $server->{'manager'} eq 'xen') {
	# Mount temp filesystem to copy
	local $mounted;
	if (!$server->{'xen_mount'}) {
		local $err = &type_xen_mount_filesystem($server);
		return $err if ($err);
		$mounted++;
		}
	local $err = &put_file_to_server($vhost, $file,
		"$server->{'xen_mount'}/etc/fstab");
	&type_xen_umount_filesystem($server) if ($mounted);
	return "Failed to write /etc/fstab : $err" if ($err);
	}
elsif ($server->{'status'} ne 'nohost' && $server->{'status'} ne 'down') {
	# Write to /etc/fstab on system directly
	local $err = &put_file_to_server($server, $file, "/etc/fstab");
	return "Failed to write /etc/fstab : $err" if ($err);
	}
else {
	return "The /etc/fstab file cannot be updated on systems in state ".
	       $server->{'status'};
	}
return undef;
}

# mount_device_filesystem(&server, directory, device, filesystem)
# Mounts a filesystem on some virtual system. Returns undef on success, or an
# error message on failure.
sub mount_device_filesystem
{
local ($server, $mount, $device, $fs) = @_;
if ($server->{'status'} eq 'down' ||
    $server->{'status'} eq 'nohost' ||
    $server->{'status'} eq 'nossh' ||
    $server->{'status'} eq 'nosshlogin') {
	return "Filesystems cannot be mounted on systems in state ".
	       $server->{'status'};
	}
local $cmd = "mount";
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
local ($out, $ex, $err) = &execute_command_on_server($server,
	"test -d ".quotemeta($mount)." || mkdir -p ".quotemeta($mount));
local ($out, $ex, $err) = &execute_command_on_server($server, "$cmd 2>&1");
$err = $out if ($ex);
return $err;
}

# unmount_device_filesystem(&server, directory)
# Un-mount some mounted filesystem, and return undef on success or an error
# message on failure.
sub unmount_device_filesystem
{
local ($server, $mount) = @_;
local $cmd = "umount ".quotemeta($mount);
local ($out, $ex, $err) = &execute_command_on_server($server, "$cmd 2>&1");
$err = $out if ($ex);
return $err;
}

1;

