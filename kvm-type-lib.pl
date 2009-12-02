# Functions for Kvm

sub type_kvm_desc
{
return $text{'kvm_typedesc'};
}

# type_kvm_parent(&server, [&all-servers])
# Returns the parent system that hosts this kvm
sub type_kvm_parent
{
my ($server, $servers) = @_;
if ($servers) {
	my ($vhost) = grep { $_->{'id'} == $server->{'kvm_on'} } @$servers;
	return $vhost;
	}
else {
	return &get_managed_server($server->{'kvm_on'});
	}
}

sub type_kvm_must_image
{
return 1;			# KVM instances always come from an image
}

sub type_kvm_is_virtual
{
return 1;
}

sub type_kvm_can_transfer
{
my ($server) = @_;
return $server->{'kvm_mount'} && !$server->{'nohost'} ||	# Via host
       $server->{'status'} eq 'nowebmin' ||	# Can transfer if SSH is up
       $server->{'status'} eq 'downwebmin' ||
       $server->{'status'} eq 'nowebminlogin' ||
       $server->{'status'} eq 'novirt' ||
       $server->{'status'} eq 'virt';
}

# Can change the password if totally down, or can SSH in
sub type_kvm_can_password
{
my ($server) = @_;
return $server->{'status'} ne 'nohost' &&
       $server->{'status'} ne 'nossh' &&
       $server->{'status'} ne 'nosshlogin';
}

# Can reset, if the host is up
sub type_kvm_can_reset
{
my ($server) = @_;
return $server->{'status'} ne 'nohost';
}

# Returns links for creating and adding kvms (if this system supports
# them, or remote systems do)
sub type_kvm_create_links
{
my @vhosts = grep { $_->{'kvm_host'} } &list_managed_servers();
my @rv;
if (@vhosts) {
	push(@rv, { 'create' => 0,
		    'desc' => $text{'kvm_addlink'} });
	my @images = &list_server_images('kvm');
	if (@images) {
		push(@rv, { 'create' => 1,
			    'desc' => $text{'kvm_createlink'} });
		}
	}
return @rv;
}

# Returns a link to the page list kvm-capable systems
sub type_kvm_global_links
{
return ( { 'link' => 'list_kvms.cgi',
	   'icon' => 'images/kvms.gif',
	   'title' => $text{'kvms_title'},
	   'cat' => 'hosts' } );
}

# can_host_kvm(&server)
# Returns 1 if some server is of a type that we can do KVM hosting on
sub can_host_kvm
{
my ($server) = @_;
return $server->{'manager'} eq 'this' || $server->{'manager'} eq 'real';
}

# type_kvm_add_form()
# Returns inputs for adding an existing KVM instance. This is just a matter of
# selecting the host and the server.
sub type_kvm_add_form
{
my $rv;

# Hosting system
my @vhosts = grep { $_->{'kvm_host'} } &list_managed_servers();
$rv .= &ui_table_row($text{'add_kvmhost'},
		&ui_select("kvm_on", $vhosts[0]->{'id'},
			[ map { [ $_->{'id'}, $_->{'host'} ] } @vhosts ]));

if (@vhosts == 1) {
	# Can just show a drop-down of existing kvm instances, except those we
	# are already hosting)
	my $instances = &list_kvm_instances($vhosts[0]);
	my %already = map { $_->{'kvm_filesystem'}, $_ }
			     &list_managed_servers();
	$rv .= &ui_table_row($text{'add_kvmpid'},
	    &ui_select("kvm_pid", undef,
		[ map { [ $_->{'pid'}, $_->{'cmd'} ] }
		      grep { !$already{$_->{'filesystem'}} } @$instances] ));
	}
else {
	# Need to show kvm name field, with popup
	$rv .= &ui_table_row($text{'add_kvmpid'},
	     &ui_textbox("kvm_pid", undef, 20)." ".
	     &kvm_instance_chooser_button("kvm_pid", "kvm_on"));
	}

return $rv;
}

# type_kvm_add_parse(&server, &in)
# Parse inputs from type_kvm_add_form
sub type_kvm_add_parse
{
my ($server, $in) = @_;

# Save KVM host
$server->{'kvm_on'} = $in->{'kvm_on'};
my $vhost = &type_kvm_parent($server);

# Check and save KVM instance
my $instances = &list_kvm_instances($vhost);
$in->{'kvm_pid'} || &error($text{'add_ekvminstance'});
my ($got) = grep { $_->{'pid'} eq $in->{'kvm_pid'} } @$instances;
$got || &error(&text('add_ekvminstance2', $vhost->{'host'}));
$got->{'filesystem'} || &error($text{'add_ekvmfs'});
$server->{'kvm'} = $in->{'kvm_pid'};

# Make sure the filesystem is in usable raw format
my ($out, $ex, $err) = &execute_command_on_server($vhost, 
			"qemu-img info ".quotemeta($got->{'filesystem'}));
if ($ex || $err) {
	&error(&text('add_ekvmfile', $got->{'filesystem'}, $err || $out));
	}
elsif ($out !~ /file\s+format:\s+(\S+)/i || $1 ne "raw") {
	&error(&text('add_ekvmfile2', $got->{'filesystem'}, $1 || "unknown"));
	}

# Save KVM root disk
$server->{'kvm_filesystem'} = $got->{'filesystem'};

# Save other disks
my @drives;
foreach my $dd ("a" .. "z") {
	my $dfile = $got->{'args'}->{"hd".$dd};
	if ($dfile) {
		my $idx = ord($dd) - 97;
		push(@drives, "file=$dfile,index=$idx,media=disk");
		}
	}
if ($got->{'args'}->{'cdrom'}) {
	push(@drives, "file=$got->{'args'}->{'cdrom'},index=2,media=cdrom");
	}
my @otherdrives = ref($got->{'args'}->{'drive'}) ?
			@{$got->{'args'}->{'drive'}} :
			( $got->{'args'}->{'drive'} );
push(@drives, @otherdrives);
$server->{'kvm_drives'} = join(" ", @drives);

# Save memory
$server->{'kvm_memory'} = $got->{'args'}->{'m'} || 128;

# Save TAP network interfaces
my @nets = ref($got->{'args'}->{'net'}) ? @{$got->{'args'}->{'net'}}
					: ( $got->{'args'}->{'net'} );
$server->{'kvm_net'} = join(" ", grep { /^tap/ } @nets);
}

# type_kvm_reboot(&server)
# SSH in and reboot if possible, or kill and restart
sub type_kvm_reboot
{
my ($server) = @_;
my $vhost = &type_kvm_parent($server);
if (&can_ssh_status($server)) {
	# Try reboot command
	my ($out, $ex, $err) = &execute_command_on_server($server, "reboot");
	return $err ? $err : $ex ? $out : undef;
	}
# Just kill and restart
&type_xen_shutdown($server, 1);
return &type_xen_startup($server);
}

# type_kvm_shutdown(&server, [force])
# SSH in and shutdown, or kill
sub type_kvm_shutdown
{
my ($server, $force) = @_;
my $vhost = &type_kvm_parent($server);
if (&can_ssh_status($server) && !$force) {
	# Try poweroff command
	my ($out, $ex, $err) = &execute_command_on_server($server,
							  "poweroff -f", 30);
	return $err ? $err : $ex ? $out : undef;
	}
my $proc = &get_server_kvm_instance($server);
if ($proc) {
	# Just kill it
	my ($out, $ex, $err) = &execute_command_on_server($vhost,
					"kill $proc->{'pid'}");
	return $err ? $err : $ex ? $out : undef;
	}
return "No KVM process found!";
}

# type_kvm_startup(&server)
# Start the kvm or qemu-kvm process, and wait till it responds to ping and SSH
sub type_kvm_startup
{
my ($server) = @_;
my $vhost = &type_kvm_parent($server);
my $cmd = &get_kvm_start_command($server);
my ($pinged, $sshed);

# Create a console output file
if (!$server->{'kvm_console'}) {
	$server->{'kvm_console'} = $server->{'kvm_filesystem'};
	$server->{'kvm_console'} =~ s/([^\/]+)$//;
	$server->{'kvm_console'} .= $server->{'host'}.".console";
	}

# Run qemu-kvm to start it up, in the background
my ($out, $ex, $err) = &execute_command_on_server($vhost,
			"$cmd >$server->{'kvm_console'} 2>&1 </dev/null &");
return (0, $err) if ($err);
return (0, $out) if ($ex);

# Wait 5 seconds for it to start
my $tries = 0;
my $found = 0;
while($tries++ < 5) {
	my $proc = &get_server_kvm_instance($server);
	if ($proc) {
		$server->{'kvm'} = $proc->{'pid'};
		$found++;
		last;
		}
	sleep(1);
	$tries++;
	}

# Read the output file
my $out = &get_file_data_from_server($vhost, $server->{'kvm_console'});
if (!$found) {
	return (0, $out);
	}

# Wait up to 60 seconds for ping
my $tries = 0;
$pinged = 0;
my $ip = &get_server_ip($server);
while($tries++ < 60) {
	sleep(1);
	if (&ping_server_host($ip)) {
		$pinged = 1;
		last;
		}
	}

# Wait for SSH to come up
if ($pinged) {
	my $sshtries = 0;
	$sshed = 0;
	while($sshtries++ < 60) {
		sleep(1);
		my $ssherr;
		&open_socket($server->{'host'}, 22, SSHTEST,
			     \$ssherr);
		if (!$ssherr) {
			close(SSHTEST);
			$sshed = 1;
			last;
			}
		}
	}

# Re-check which IPs are really active
if ($sshed) {
	&compute_ip_addresses($server);
	}

# Return an error if something went wrong
if (defined($pinged) && !$pinged) {
	return (2, &text('kvm_estartping', 60));
	}
if (defined($sshed) && !$sshed) {
	return (3, &text('kvm_estartssh', 60));
	}
return (1, undef);
}

# type_kvm_get_console_output(&server)
# Returns a status code and text displayed during the KVM boot (if status is 1),
# or an error message (if 0)
sub type_kvm_get_console_output
{
my ($server) = @_;
if (!$server->{'kvm_console'}) {
	return (0, "No console messages were captured at boot time");
	}
my $vhost = &type_kvm_parent($server);
my $out = &get_file_data_from_server($vhost, $server->{'kvm_console'});
return $out ? (1, $out) : (0, "No console messages were found");
}

# type_kvm_delete(&server)
# Delete a KVM instance
sub type_kvm_delete
{
my ($server) = @_;
my $vhost = &type_kvm_parent($server);

# Force shutdown if needed
my $proc = &get_server_kvm_instance($server);
if ($proc) {
	&type_kvm_shutdown($server, 1);
	}

# Delete virtual disks
my $disks = &type_kvm_list_disks($server, 0);
if (ref($disks)) {
	foreach my $d (@$disks) {
		my @st = &stat_file_on_server($vhost, $d->{'real'});
		next if (!@st);		# Already gone
		if (!$d->{'device'} && $d->{'real'} !~ /^\/dev\//) {
			my ($out, $ex, $err) = &execute_command_on_server(
				$vhost, "rm -f ".quotemeta($d->{'real'}));
			return $err if ($err);
			return $out if ($ex);
			}
		elsif ($d->{'lv'}) {
			# Delete the logical volume
			$last_remote_error = undef;
			&remote_foreign_require($vhost, "lvm", "lvm-lib.pl");
			return $last_remote_error if ($last_remote_error);
			&remote_foreign_call($vhost, "lvm",
					     "delete_logical_volume",
					     { 'device' => $d->{'real'} });
			return "Failed to delete LV $d->{'real'} : ".
			       "$last_remote_error" if ($last_remote_error);
			}
		}
	}

# Delete boot-time entry
&type_kvm_set_atboot($server, 0);

# Delete console file
if ($server->{'kvm_console'}) {
	&delete_file_on_server($vhost, $server->{'kvm_console'});
	}

# Remove the DNS entry, if we created one
&delete_bind8_record($server->{'kvm_dns'}, $vhost->{'kvm_zone'},
		     &to_ipaddress($server->{'host'}));

return undef;
}

# get_kvm_start_command(&server)
# Returns the full command line to start a KVM instance
sub get_kvm_start_command
{
my ($server) = @_;
my $vhost = &type_kvm_parent($server);
my $cmd = &has_command_on_server($vhost, "kvm") ? "kvm" : "qemu-kvm";
$cmd .= " -name ".quotemeta($server->{'host'});

# Memory flag
$cmd .= " -m ".$server->{'kvm_memory'};

# Add disks
foreach my $d (split(/\s+/, $server->{'kvm_drives'})) {
	$cmd .= " -drive $d";
	}

# Boot from disk
$cmd .= " -boot c";

# No graphical UI
$cmd .= " -nographic";

# Accept TCP connection for console
my $inuse = &list_ports_in_use($vhost, "tcp");
if (ref($inuse)) {
	my $cport = 4444;
	while(1) {
		last if (&indexof($cport, @$inuse) < 0);
		$cport++;
		}
	$server->{'kvm_cport'} = $cport;
	$cmd .= " -serial tcp:127.0.0.1:$cport,server,nowait";
	}

# TAP networking, if enabled
foreach my $net (split(/\s+/, $server->{'kvm_net'})) {
	$cmd .= " -net $net";
	if ($net =~ /vlan=(\d+)/) {
		$cmd .= " -net nic,vlan=$1";
		}
	else {
		$cmd .= " -net nic";
		}
	}

# VNC settings
if (ref($inuse)) {
	my $vport = 5900;
	while(1) {
		last if (&indexof($vport, @$inuse) < 0);
		$vport++;
		}
	$server->{'kvm_vnc_display'} = $vport-5900;
	my $masterip = &get_server_ip(&get_managed_server(0));
	$cmd .= " -vnc ".$masterip.",".$server->{'kvm_vnc_display'};
	}

return $cmd;
}

# type_kvm_can_disks(&server)
# Returns 1, as we can manage disks for Xen instances. These are files or
# devices mapped to virtual disks in the instance.
sub type_kvm_can_disks
{
my ($server) = @_;
return $server->{'status'} ne 'nohost';
}

# type_kvm_list_disks(&server, include-mounts)
# Returns a list of hash refs, one per disk, with fields :
# real - Real file on host system, like /kvm/foo.dsk
# virt - Virtual device on instance, like /dev/sda
# device - Set to 1 if this is a real device, like /dev/md1
# size - Size in bytes, if a file
# vg - LVM volume group, if any
# lv - LVM logical volume
sub type_kvm_list_disks
{
my ($server, $mounts) = @_;
my $vhost = &type_kvm_parent($server);

# If LVM is in use, get LVs from the host system
my @lvs;
if ($server->{'kvm_filesystem_vg'}) {
	if ($main::list_logical_cache{$vhost->{'id'}}) {
		@lvs = @{$main::list_logical_cache{$vhost->{'id'}}};
		}
	else {
		&remote_foreign_require($vhost, "lvm", "lvm-lib.pl");
		@lvs = &remote_foreign_call($vhost, "lvm",
			"list_logical_volumes", $server->{'kvm_filesystem_vg'});
		$main::list_logical_cache{$vhost->{'id'}} = \@lvs;
		}
	}

# Parse disks from Cloudmin config
my $idx = -1;
my @rv;
foreach my $dstr (split(/\s+/, $server->{'kvm_drives'})) {
	$idx++;
	my %drive = map { split(/=/, $_, 2) } split(/,/, $dstr);
	next if (!$drive{'file'});
	if ($drive{'if'} eq 'scsi') {
		$dev = "sd".chr($drive{'index'}+97);
		}
	elsif ($drive{'if'} eq 'ide' || !$drive{'if'}) {
		$dev = "hd".chr($drive{'index'}+97);
		}
	else {
		# Only IDE and SCSI support, not floppies/etc
		next;
		}
	my $disk = { 'real' => $drive{'file'},
		     'virt' => "/dev/".$dev,
		     'virtdev' => $dev,
		     'drive_index' => $idx };
	$disk->{'device'} = $drive{'file'} =~ /^\/dev\// ? 1 : 0;
	if (!$disk->{'device'}) {
		my @st = &stat_file_on_server($vhost, $drive{'file'});
		$disk->{'size'} = $st[7];
		}
	if ($server->{'kvm_filesystem_vg'} &&
	    $disk->{'real'} =~ /^\/dev\/(\S+)\/(\S+)$/ &&
	    $1 eq $server->{'kvm_filesystem_vg'}) {
		# Server has root on LVM .. check if this is too
		$disk->{'vg'} = $1;
		$disk->{'lv'} = $2;
		my ($lv) = grep { $_->{'name'} eq $disk->{'lv'} } @lvs;
		if ($lv) {
			$disk->{'size'} = $lv->{'size'} * 1024;
			}
		}
	$disk->{'index'} = scalar(@rv);
	push(@rv, $disk);
	}

# If the caller asked for mounts, get them too
if ($mounts) {
	# Get fstab mounts
	my $fstab = &get_system_fstab($server);
	return $fstab if (!ref($fstab));
	foreach my $d (@rv) {
		my ($f) = grep { my $v = $d->{'virt'};
				 $_->[0] =~ /^\Q$v\E(\d*)$/ } @$fstab;
		if ($f) {
			$d->{'virt_mount'} = $f->[0];
			$d->{'mount'} = $f->[1];
			$d->{'fs'} = $f->[2];
			}
		}

	# Check if actually mounted
	if (&can_ssh_status($server)) {
		my %mounted;
		my ($out, $ex, $err) =
			&execute_command_on_server($server, "mount");
		foreach my $l (split(/\r?\n/, $out)) {
			my ($dev, $on, $mp) = split(/\s+/, $l);
			$mounted{$dev} = $mp;
			}
		foreach my $d (@rv) {
			$d->{'mounted'} = $mounted{$d->{'virt'}} ||
					  $mounted{$d->{'virt_mount'}};
			}
		}
	}

# If caller asked for disk usage, get it too if we can
if ($mounts == 2 && &can_ssh_status($server)) {
	my ($out, $ex, $err) = &execute_command_on_server(
		$server, "df -k -l || df -k");
	if (!$ex && !$err) {
		foreach my $l (split(/\r?\n/, $out)) {
			my ($fs, $size, $used, $free) = split(/\s+/, $l);
			my ($disk) = grep { $_->{'virt'} eq $fs ||
					    $_->{'virt_mount'} eq $fs } @rv;
			if ($disk) {
				$disk->{'df_size'} = $size*1024;
				$disk->{'df_used'} = $used*1024;
				$disk->{'df_free'} = $free*1024;
				}
			}
		}
	}

return \@rv;
}

# type_kvm_need_disk_reboot(&server, &disk)
# A reboot is always needed, to apply the new command line
sub type_kvm_need_disk_reboot
{
my ($server, $disk) = @_;
return $server->{'status'} eq 'down' ? 0 : 1;
}

# type_kvm_new_disk(&server, &disks, real?)
# Returns a structure for a new disk on some KVM system
sub type_kvm_new_disk
{
my ($server, $disks, $device) = @_;
my $rv = { };

# Find which device files are used
my %used;
foreach my $d (@$disks) {
	$used{$d->{'virt'}}++;
	}

# Pick a /dev/???? file that is free on the virtual system
my $n;
if ($disks->[0]->{'virt'} =~ /^(\/dev\/[sh]d)[a-z]$/) {
	# System uses whole disks! Pick a free partition on the next disk
	$prefix = $1;
	for($n='a'; $used{$prefix.$n}; $n=chr(ord($n)+1)) { }
	$prefix .= $n;
	$rv->{'virt'} = $prefix;
	}
else {
	# No idea .. just guess
	$rv->{'virt'} = "/dev/hdb";
	}
$rv->{'virt_mount'} = $rv->{'virt'}."1";

if (!$device) {
	my $vhost = &type_kvm_parent($server);
	if ($server->{'kvm_filesystem_vg'}) {
		# Create an LVM name
		$rv->{'vg'} = $server->{'kvm_filesystem_vg'};
		$rv->{'lv'} = $server->{'kvm'}."_".(scalar(@$disks)+1)."_img";
		$rv->{'real'} = "/dev/".$rv->{'vg'}."/".$rv->{'lv'};
		}
	else {
		# Pick an image file
		$rv->{'real'} = "$vhost->{'kvm_dir'}/$server->{'host'}.".
				(scalar(@$disks)+1).".img";
		}
	}
$rv->{'device'} = $device;
return $rv;
}

# type_kvm_create_disk(&server, &disk)
# Adds a new virtual disk to a KVM system's config.
# If this is a real file that doesn't exist yet, create it and optionally mkfs
# it. Also add to the /etc/fstab file, if requested.
sub type_kvm_create_disk
{
my ($server, $disk) = @_;
my $vhost = &type_kvm_parent($server);

my @st = &stat_file_on_server($vhost, $disk->{'real'});
if ($disk->{'device'} && !$disk->{'lv'}) {
	# Check if the device exists
	@st || return "Device $disk->{'real'} does not exist ".
		      "on $vhost->{'host'}";
	}
else {
	if ($disk->{'lv'}) {
		# Create the logical volume
		$last_remote_error = undef;
		&remote_foreign_require($vhost, "lvm", "lvm-lib.pl");
		my $lv = { 'name' => $disk->{'lv'},
			      'size' => int($disk->{'size'}/1024),
			      'perm' => 'rw',
			      'alloc' => 'n',
			      'vg' => $disk->{'vg'} };
		my $err = &remote_foreign_call($vhost, "lvm",
						  "create_logical_volume", $lv);
		$err ||= $last_remote_error;
		return "LVM logical volume creation failed : $err" if ($err);
		}
	elsif (!@st) {
		$disk->{'size'} || return "File $disk->{'real'} does not exist on $vhost->{'host'}, but no size to create it as was given";
		}

	# Call qemu-img to initialize it
	my $cmd = "qemu-img create -f raw ".quotemeta($disk->{'real'})." ".
				     int($disk->{'size'}/1024/1024)."M";
	my ($out, $ex, $err) = &execute_command_on_server($vhost, $cmd);
	$err = $out if ($ex);
	$err && return "Failed to create file $disk->{'real'} : $err";

	# Create partition on it
	my $fdisktemp = &transname();
	&open_tempfile(FDISK, ">$fdisktemp");
	&print_tempfile(FDISK, "n\n");	# New partition
	&print_tempfile(FDISK, "p\n");	# Primary
	&print_tempfile(FDISK, "1\n");	# First partition
	&print_tempfile(FDISK, "\n");	# Default start
	&print_tempfile(FDISK, "\n");	# Default size (whole disk)
	&print_tempfile(FDISK, "w\n");	# Write out
	&close_tempfile(FDISK);
	my $fdisktempdest = &tempname_on_server($vhost);
	my $err = &put_file_to_server($vhost, $fdisktemp, $fdisktempdest);
	$err && return "Failed to upload fdisk input file : $err";
	&unlink_file($fdisktemp);
	my $cyls = int($disk->{'size'} / 63 / 255 / 512);
	my ($out, $ex, $err) = &execute_command_on_server($vhost,
		"fdisk -u -H 255 -S 63 -C $cyls ".quotemeta($disk->{'real'}).
		" <$fdisktempdest");
	&delete_file_on_server($vhost, $fdisktempdest);
	if ($out !~ /has\s+been\s+altered/i) {
		return "Failed to create partition : ".($err || $out);
		}

	# And make a filesystem on the new partition, using a loopback device
	if (!@st && $disk->{'fs'}) {
		# Work out the size of the partition in blocks. This is needed
		# because losetup doesn't properly detect the modified size!
		my ($out, $ex, $err) = &execute_command_on_server($vhost,
			"fdisk -u -H 255 -S 63 -C $cyls -l ".
			quotemeta($disk->{'real'}));
		my $blocksize;
		if ($out =~ /\s(\d+)\s+(\d+)\s+(\d+)\s+([0-9a-f]+)/) {
			$blocksize = $3 * 1024;
			}

		# Create the filesystem
		my $o = 63*512;
		my ($out, $ex, $err) = &execute_command_on_server($vhost,
			"losetup -o $o /dev/loop9 ".quotemeta($disk->{'real'}));
		if ($ex || $err) {
			return "Failed to create loopback : ".($err || $out);
			}
		my $err = &create_device_filesystem(
			$vhost, "/dev/loop9", $disk->{'fs'}, $blocksize);
		&execute_command_on_server($vhost, "losetup -d /dev/loop9");
		$err && return "Failed to create ".uc($disk->{'fs'}).
			       " filesystem : $err";
		}
	}

# Add the disk to the KVM config
my @drives = split(/\s+/, $server->{'kvm_drives'});
my %drive = ( 'file' => $disk->{'real'},
	      'media' => 'disk' );
if ($disk->{'virt'} =~ /sd[a-z]+$/) {
	$drive{'if'} = 'scsi';
	}
else {
	$drive{'if'} = 'ide';
	}
if ($disk->{'virt'} =~ /([hs])d([a-z])$/) {
	$drive{'index'} = ord($2)-97;
	}
push(@drives, join(",", map { $_."=".$drive{$_} } keys %drive));
$server->{'kvm_drives'} = join(" ", @drives);
&save_managed_server($server);
&type_kvm_set_atboot($server, 2);

# Add to total disk size
if ($server->{'kvm_disktotal'} ne '' && (!$disk->{'device'} || $disk->{'lv'})) {
	$server->{'kvm_disktotal'} += $disk->{'size'};
	}

# Add to /etc/fstab, if a mount point was given
my $fserr;
if ($disk->{'mount'} && $server->{'status'} ne 'alive') {
	my $err = &mount_filesystem_if_needed($server);
	return "Failed to mount filesystem : $err" if ($err);
	$err = &make_dir_on_server($server, $disk->{'mount'}, 0755, 1);
	return "Failed to create mount point : $err" if ($err);
	my $fstab = &get_system_fstab($server);
	$fserr = "Failed to read fstab file : $fstab" if (!ref($fstab));
	if (!$fserr) {
		push(@$fstab, [ $disk->{'virt_mount'}, $disk->{'mount'},
				$disk->{'fs'}, 'defaults', 0, 1 ]);
		my $err = &put_system_fstab($server, $fstab);
		$fserr = "Failed to update fstab file : $err" if ($err);
		}
	&umount_filesystem_if_needed($server);
	}

return $fserr;
}

# type_kvm_delete_disk(&server, &disk)
# Removes a disk from the Xen configuration, the system's fstab file, and
# deletes the underlying config file. The disk object must come from a call
# to type_kvm_list_disks with the mount flag set to 1.
sub type_kvm_delete_disk
{
my ($server, $disk) = @_;
my $vhost = &type_kvm_parent($server);

# Actually un-mount if mounted
if (&can_ssh_status($server) && $disk->{'mounted'}) {
	my ($out, $ex, $err) = &execute_command_on_server($server,
		"umount ".$disk->{'virt'});
	if ($err || $ex) {
		return "Failed to un-mount $disk->{'virt'} : ".
		       ($err || $out);
		}
	}

# Remove from the KVM config
my @drives = split(/\s+/, $server->{'kvm_drives'});
splice(@drives, $disk->{'drive_index'}, 1);
$server->{'kvm_drives'} = join(" ", @drives);
&save_managed_server($server);
&type_kvm_set_atboot($server, 2);

# Remove from total disk size
if ($server->{'kvm_disktotal'} ne '' && (!$disk->{'device'} || $disk->{'lv'})) {
	$server->{'kvm_disktotal'} -= $disk->{'size'};
	}

# Remove from fstab
if ($server->{'status'} ne 'alive') {
	my $fstab = &get_system_fstab($server);
	return "Failed to read fstab file : $fstab" if (!ref($fstab));
	my @newfstab = grep { $_->[0] ne $disk->{'virt_mount'} } @$fstab;
	if (scalar(@newfstab) != scalar(@$fstab)) {
		my $err = &put_system_fstab($server, \@newfstab);
		$fserr = "Failed to update fstab file : $err" if ($err);
		}
	}

if (!$disk->{'device'} && $disk->{'real'} !~ /^\/dev\//) {
	# Delete the image file
	&delete_file_on_server($vhost, $disk->{'real'});
	}
elsif ($disk->{'lv'}) {
	# Delete the logical volume
	&remote_foreign_require($vhost, "lvm", "lvm-lib.pl");
	&remote_foreign_call($vhost, "lvm", "delete_logical_volume",
			     { 'device' => $disk->{'real'} });
	}

return undef;
}

# type_kvm_modify_disk(&server, &disk, &old-disk)
# Modifies the virtual device and size of a disk. Returns undef if OK, or an
# error message on failure.
# The disk objects *must* have the mount and fs fields set, if mounted.
sub type_kvm_modify_disk
{
my ($server, $disk, $olddisk) = @_;
my $vhost = &type_kvm_parent($server);
my $moderr;

# Disk resizing not supported yet
if ($disk->{'size'} != $olddisk->{'size'}) {
	return "The size of a KVM disk cannot be changed yet";
	}

# If the system is up, un-mount the disk
my $mounted = 0;
if (&can_ssh_status($server) && $olddisk->{'mounted'}) {
	my ($out, $ex, $err) = &execute_command_on_server($server,
		"umount ".$olddisk->{'virt'});
	if ($err || $ex) {
		return "Failed to un-mount $olddisk->{'virt'} : ".
		       ($err || $out);
		}
	$mounted = 1;
	}

if ($disk->{'virt'} ne $olddisk->{'virt'}) {
	# Change the virtual device, both in the Xen config file and fstab
	if ($olddisk->{'virt_mount'} =~ /(\d+)$/) {
		$disk->{'virt_mount'} = $disk->{'virt'}.$1;
		}

	# Fix disk in config
	my @drives = split(/\s+/, $server->{'kvm_drives'});
	my %drive = map { split(/=/, $_, 2) }
			split(/,/, $drives[$disk->{'drive_index'}]);
	if ($disk->{'virt'} =~ /([hs])d([a-z])$/) {
		$drive{'index'} = ord($2)-97;
		}
	$drives[$disk->{'drive_index'}] =
		join(",", map { $_."=".$drive{$_} } keys %drive);
	$server->{'kvm_drives'} = join(" ", @drives);
	&save_managed_server($server);
	&type_kvm_set_atboot($server, 2);

	# Update fstab, if in there
	if ($server->{'status'} ne 'alive') {
		my $fstab = &get_system_fstab($server);
		if (!ref($fstab)) {
			$moderr = "Failed to read fstab file : $fstab";
			}
		else {
			my ($f) = grep { $_->[0] eq $olddisk->{'virt_mount'} }
				       @$fstab;
			if ($f) {
				$f->[0] = $disk->{'virt_mount'};
				my $err = &put_system_fstab($server, $fstab);
				$moderr = "Failed to update fstab file : $err"
					if ($err);
				}
			}
		}
	}

# If it was mounted before, mount it now
if ($mounted && $disk->{'mount'}) {
	my ($out, $ex, $err) = &execute_command_on_server($server,
		"mount ".$disk->{'virt'}." ".$disk->{'mount'});
	if ($err || $ex) {
		return "Failed to mount $disk->{'virt'} : ".($err || $out);
		}
	}

return $moderr;
}

# type_kvm_list_disk_filesystems(&server)
# Returns supported filesystem types. Assumes Linux.
sub type_kvm_list_disk_filesystems
{
return ('ext3', 'ext2', 'reiserfs', 'xfs', 'jfs', 'swap');
}

# Returns 2, indicating that memory can be changed but needs a reboot
sub type_kvm_can_memory
{
return 2;
}

sub type_kvm_can_unlimited_memory
{
return 0;
}

# type_kvm_get_memory(&server)
# Returns the amount of RAM in bytes this server is granted, or undef if
# not available.
sub type_kvm_get_memory
{
my ($server) = @_;
my $proc = &get_server_kvm_instance($server);
if ($proc && $proc->{'args'}->{'m'}) {
	# Get from -m flag of running process
	return $proc->{'args'}->{'m'} * 1024 * 1024;
	}
return $server->{'kvm_memory'} * 1024 * 1024;
}

# type_kvm_save_memory(&server, ram)
# Updates the memory in the Cloudmin config, and in the boot-time script
sub type_kvm_save_memory
{
my ($server, $mem) = @_;
my $mbs = int($mem/(1024*1024));
$server->{'kvm_memory'} = $mbs;
&type_kvm_set_atboot($server, 2);
return undef;
}

# type_kvm_can_interfaces(&server)
# KVM interface management is via Webmin or via SSH, so it needs to be up.
# The return value of 2 means that interfaces can also be 'real'
sub type_kvm_can_interfaces
{
my ($server) = @_;
if (&can_ssh_status($server)) {
	# Can manage via Webmin or SSH
	return 2;
	}
elsif ($server->{'status'} eq 'down' &&
       (&redhat_server_type($server) || &debian_server_type($server))) {
	# Can manage via direct file manipulation
	return 2;
	}
else {
	# Cannot edit
	return 0;
	}
}

# Regular interface IP allocation works for KVM
sub type_kvm_can_allocate_address
{
return 1;
}

# type_kvm_list_interfaces(&server)
# Returns a list of network interfaces on the system, or an error message
sub type_kvm_list_interfaces
{
my ($server) = @_;
my $rv;
if ($server->{'status'} eq 'down') {
	# Get from network config files
	my $err = &type_kvm_mount_filesystem($server);
	return "Failed to mount filesystem : $err" if ($err);
	$rv = &list_boot_server_interfaces($server);
	&type_kvm_umount_filesystem($server);
	}
else {
	# Get active interfaces
	$rv = &list_active_server_interfaces($server);
	}
if (ref($rv)) {
	$rv = [ grep { $_->{'fullname'} =~ /^eth/ &&
			 $_->{'address'} } @$rv ];
	foreach my $iface (@$rv) {
		$iface->{'nodelete'} = 1 if ($iface->{'virtual'} eq '');
		}
	}
return $rv;
}

# type_kvm_list_parent_interfaces(&server)
# Just lists non-virtual interfaces
sub type_kvm_list_parent_interfaces
{
my ($server) = @_;
my $rv = &type_kvm_list_interfaces($server);
return [ grep { $_->{'virtual'} eq '' } @$rv ];
}

# type_kvm_create_interface(&server, &iface)
# Add and activate a virtual interface
sub type_kvm_create_interface
{
my ($server, $iface) = @_;

# Find a free interface number
my $vhost = &type_kvm_parent($server);
my $ifaces = &type_kvm_list_interfaces($server);
return $ifaces if (!ref($ifaces));
my $n = 0;
foreach my $oldiface (@$ifaces) {
	if ($oldiface->{'virtual'} >= $n &&
	    $oldiface->{'name'} eq $iface->{'name'}) {
		$n = $oldiface->{'virtual'} + 1;
		}
	}
$iface->{'virtual'} = $n;
$iface->{'fullname'} = $iface->{'name'}.":".$n;

# Allocate IP, if needed
if (!$iface->{'address'}) {
	my $cidr;
	my @kvm_iface = split(/\s+/, $vhost->{'kvm_iface'});
	my $idx = $iface->{'name'} =~ /^eth(\d+)/ ? $1 : 0;
	($iface->{'address'}, $cidr) = &allocate_ip_address(
	    $vhost->{'kvm_start'}, $vhost->{'kvm_end'}, $vhost->{'kvm_cidr'},
	    $vhost->{'kvm_gws'}, $vhost->{'kvm_ifaces'}, $kvm_iface[$idx]);
	$iface->{'address'} ||
		return &text('create_ekvmalloc', $vhost->{'host'},
			    &describe_ip_range($vhost->{'kvm_start'},
					       $vhost->{'kvm_end'},
					       $vhost->{'kvm_cidr'},
					       $vhost->{'kvm_ifaces'},
					       $kvm_iface[$idx]));
	$iface->{'netmask'} = &net::prefix_to_mask($cidr);
	}

# Compute broadcast and network
$iface->{'broadcast'} = &net::compute_broadcast($iface->{'address'},
						$iface->{'netmask'});
$iface->{'network'} = &net::compute_network($iface->{'address'},
					    $iface->{'netmask'});

# Activate now if possible
if (&can_ssh_status($server)) {
	my $err = &create_active_server_interface($server, $iface);
	return $err if ($err);
	}

# Activate at boot
my $err = &mount_filesystem_if_needed($server);
return "Failed to mount filesystem : $err" if ($err);
$err = &create_boot_server_interface($server, $iface);
&umount_filesystem_if_needed($server);
return $err if ($err);

# Add to command line?
# XXX

&add_ip_address($server, $iface->{'address'});
return undef;
}

# type_kvm_delete_interface(&server, &iface)
# Delete and de-activate a virtual interface
sub type_kvm_delete_interface
{
my ($server, $iface) = @_;

# Delete boot interface
my $err = &mount_filesystem_if_needed($server);
return "Failed to mount filesystem : $err" if ($err);
$err = &delete_boot_server_interface($server, $iface);
&umount_filesystem_if_needed($server);
return $err if ($err);

# De-activate interface if possible
if (&can_ssh_status($server)) {
	my $err = &delete_active_server_interface($server, $iface);
	return $err if ($err);
	}

&delete_ip_address($server, $iface->{'address'});
return undef;
}

# type_kvm_modify_interface(&server, &iface, &oldiface)
# Changes the active and boot-time IPs for an interface
sub type_kvm_modify_interface
{
my ($server, $iface, $oldiface) = @_;

# Modify boot interface
my $err = &mount_filesystem_if_needed($server);
return "Failed to mount filesystem : $err" if ($err);
$err = &modify_boot_server_interface($server, $iface, $oldiface);
&umount_filesystem_if_needed($server);
return $err if ($err);

# Change active interface if possible
if (&can_ssh_status($server)) {
	my $err = &modify_active_server_interface($server, $iface, $oldiface);
	return $err if ($err);
	}

&delete_ip_address($server, $oldiface->{'address'});
&add_ip_address($server, $iface->{'address'});
return undef;
}

# type_kvm_compute_disksize(&server)
# Sets a server's kvm_disktotal field to the total size of virtual disks,
# and returns it.
sub type_kvm_compute_disksize
{
my ($server) = @_;
if ($server->{'status'} ne 'nohost') {
	my $disks = &type_kvm_list_disks($server, 0);
	if (ref($disks)) {
		$server->{'kvm_disktotal'} = 0;
		foreach my $d (@$disks) {
			$server->{'kvm_disktotal'} += $d->{'size'}
				if (!$d->{'device'} || $d->{'lv'});
			}
		}
	}
return $server->{'kvm_disktotal'};
}

# type_kvm_get_disk_size(&server)
# Returns the cached amount of disk space allocated to this KVM instance
sub type_kvm_get_disk_size
{
my ($server) = @_;
if (!$server->{'kvm_disktotal'}) {
	&type_kvm_compute_disksize($server);
	}
return $server->{'kvm_disktotal'};
}

# type_kvm_get_disk_space(&server)
# Returns the amount of disk space used on the host by this Xen instance, which
# is the same as the disk allocated
sub type_kvm_get_disk_space
{
my ($server) = @_;
return &type_kvm_get_disk_size($server);
}

# type_kvm_need_mount(&server)
# Returns 1 if a mount call is needed before reading files from this system
sub type_kvm_need_mount
{
my ($server) = @_;
return $server->{'status'} eq 'down' && !$server->{'kvm_mount'};
}

# type_kvm_get_file(&server, remotefile, localfile)
# If the filesystem for this KVM instance is locally mounted, get the file
# directly from there
sub type_kvm_get_file
{
my ($server, $remotefile, $localfile) = @_;
if ($server->{'kvm_mount'}) {
	my $vhost = &type_kvm_parent($server);
	return &get_file_from_server($vhost, $server->{'kvm_mount'}.$remotefile,
					     $localfile);
	}
else {
	return 'FALLBACK';
	}
}

# type_kvm_put_file(&server, remotefile, localfile)
# If the filesystem for this KVM instance is locally mounted, write the file
# directly to there
sub type_kvm_put_file
{
my ($server, $localfile, $remotefile) = @_;
if ($server->{'kvm_mount'}) {
	my $vhost = &type_kvm_parent($server);
	return &put_file_to_server($vhost, $localfile,
				   $server->{'kvm_mount'}.$remotefile);
	}
else {
	return 'FALLBACK';
	}
}

# type_kvm_delete_file(&server, remotefile, noquote)
# If the filesystem for this KVM instance is locally mounted, delete the file
# directly from there
sub type_kvm_delete_file
{
my ($server, $remotefile, $noquote) = @_;
if ($server->{'kvm_mount'}) {
	my $vhost = &type_kvm_parent($server);
	return &delete_file_on_server($vhost,
			      $server->{'kvm_mount'}.$remotefile, $noquote);
	}
else {
	return 'FALLBACK';
	}
}

# type_kvm_checksum_file(&server, remotefile, noquote)
# If the filesystem for this KVM instance is locally mounted, checksum the file
# directly from there
sub type_kvm_checksum_file
{
my ($server, $file) = @_;
if ($server->{'kvm_mount'}) {
	my $vhost = &type_kvm_parent($server);
	return &checksum_file_on_server($vhost,
			      $server->{'kvm_mount'}.$file);
	}
else {
	return ( 'FALLBACK' );
	}
}

# type_kvm_stat_file(&server, remotefile, localfile)
# If the filesystem for this KVM instance is locally mounted, stat the file
# directly from there
sub type_kvm_stat_file
{
my ($server, $remotefile) = @_;
if ($server->{'kvm_mount'}) {
	my $vhost = &type_kvm_parent($server);
	return &stat_file_on_server($vhost, $server->{'kvm_mount'}.$remotefile);
	}
else {
	return 'FALLBACK';
	}
}

# type_kvm_make_dir(&server, dir, perms, recur)
# If the filesystem for this KVM instance is locally mounted, make the dir
# directly from there
sub type_kvm_make_dir
{
my ($server, $remotedir, $perms, $recur) = @_;
if ($server->{'kvm_mount'}) {
	my $vhost = &type_kvm_parent($server);
	return &make_dir_on_server($vhost, $server->{'kvm_mount'}.$remotedir,
				   $perms, $recur);
	}
else {
	return 'FALLBACK';
	}
}

# type_kvm_list_dir(&server, dir)
# If the filesystem for this KVM instance is locally mounted, list the dir
# directly from there
sub type_kvm_list_dir
{
my ($server, $remotedir) = @_;
if ($server->{'kvm_mount'}) {
	my $vhost = &type_kvm_parent($server);
	return &list_dir_on_server($vhost, $server->{'kvm_mount'}.$remotedir);
	}
else {
	return 'FALLBACK';
	}
}

# type_kvm_mount_filesystem(&server)
# Mounts a down KVM image's root disk image on /mnt/something, and sets
# kvm_mount in the server object
sub type_kvm_mount_filesystem
{
my ($server) = @_;
my $vhost = &type_kvm_parent($server);

# Create temp dir
my $mp = "/mnt/kvm-".$server->{'kvm'};
my $err = &make_dir_on_server($vhost, $mp, 0700, 1);
return "Failed to create mount point $mp : $err" if ($err);
my $fsfile = $server->{'kvm_filesystem'};
if (!$fsfile) {
	return &text('create_ekvmfsfile');
	}

# If we don't know which partition is the primary, try them in series
if (!$server->{'kvm_filesystem_offset'}) {
	my ($out, $ex, $err) = &execute_command_on_server($vhost,
		"fdisk -l -u ".quotemeta($fsfile));
	if ($ex || $err) {
		return &text('create_ekvmfsfdisk', $fsfile, $err || $out);
		}

	# Find Linux partitions and their offsets
	my $secsize;
	my @parts;
	foreach my $l (split(/\r?\n/, $out)) {
		if ($l =~ /=\s+(\d+)\s+bytes/i) {
			$secsize = $1;
			}
		elsif ($l =~ /\s(\d+)\s+(\d+)\s+(\d+)\s+([0-9a-f]+)\s+(\S+)/i &&
		       $4 eq '83') {
			push(@parts, $1 * $secsize);
			}
		}
	@parts || return &text('create_ekvmfslinux', $fsfile);

	# Try each offset
	foreach my $o (@parts) {
		my ($out, $ex, $err) = &execute_command_on_server($vhost,
			"mount -o loop,offset=$o ".quotemeta($fsfile)." ".
					 quotemeta($mp));
		next if ($ex || $err);
		my @st = &stat_file_on_server($vhost, "$mp/etc");
		if (@st) {
			# Found it! Leave mounted
			$server->{'kvm_mount'} = $mp;
			$server->{'kvm_filesystem_offset'} = $o;
			return undef;
			}
		else {
			# Un-mount and try next one
			&execute_command_on_server($vhost,
				"umount ".quotemeta($mp));
			}
		}
	return &text('create_ekvmfsnone', $fsfile);
	}

# Mount with the correct offset
my $o = $server->{'kvm_filesystem_offset'};
my ($out, $ex, $err) = &execute_command_on_server($vhost,
	"mount -o loop,offset=$o ".quotemeta($fsfile)." ".
				   quotemeta($mp));
return "Failed to mount $fsfile on $mp : $out" if ($ex);
$server->{'kvm_mount'} = $mp;
return undef;
}

# type_kvm_umount_filesystem(&server)
# Removes the mount for a system's disk image
sub type_kvm_umount_filesystem
{
my ($server) = @_;
my $vhost = &type_kvm_parent($server);
my ($out, $ex, $err) = &execute_command_on_server($vhost,
	"umount ".quotemeta($server->{'kvm_mount'}));
delete($server->{'kvm_mount'});
return undef;
}

# type_kvm_depends(&parent, &vserver)
# Returns 1 if the KVM instance hosted by the given parent
sub type_kvm_depends
{
my ($parent, $server) = @_;
return $server->{'kvm_on'} eq $parent->{'id'};
}

# type_kvm_check_login(&server)
# Check if the KVM instance is up, and if we can SSH in. Returns a status
# code and error message
sub type_kvm_check_login
{
my ($server) = @_;
my $vhost = &type_kvm_parent($server);
if (!$vhost) {
	return (5, "KVM host does not exist!");
	}
if ($vhost->{'status'} eq 'down' ||
    $vhost->{'status'} eq 'nossh' ||
    $vhost->{'status'} eq 'nohost' ||
    $vhost->{'status'} eq 'nosshlogin') {
	return (5, "KVM host $vhost->{'host'} is down");
	}
my $proc = &get_server_kvm_instance($server);
if (!$proc) {
	return (6, "KVM instance is down");
	}

# Tell check_server_ssh_login that we need to SSH
return ( );
}

# type_kvm_post_refresh(&server, regenerate)
# Called after a refresh to compute total disk size, if needed
sub type_kvm_post_refresh
{
my ($server, $regen) = @_;
if ($server->{'kvm_disktotal'} eq '' || $regen) {
	&type_kvm_compute_disksize($server);
	}
}

# type_kvm_post_host_refresh(&server)
# Called after a KVM host system is refreshed, to maybe get LVM info
sub type_kvm_post_host_refresh
{
my ($server) = @_;

# If using LVM, see how much space is free on the VG
if ($server->{'kvm_vg'} &&
    ($server->{'status'} eq 'virt' || $server->{'status'} eq 'novirt')) {
	&remote_foreign_require($server, "lvm", "lvm-lib.pl");
	my ($vg) = grep { $_->{'name'} eq $server->{'kvm_vg'} }
		   &remote_foreign_call($server, "lvm", "list_volume_groups");
	if ($vg) {
		$server->{'kvm_vg_total'} =
			$vg->{'pe_total'}*$vg->{'pe_size'}*1024;
		$server->{'kvm_vg_used'} =
			$vg->{'pe_alloc'}*$vg->{'pe_size'}*1024;
		$server->{'kvm_vg_free'} = $server->{'kvm_vg_total'} -
					   $server->{'kvm_vg_used'};
		}
	}
elsif (!$server->{'kvm_vg'}) {
	delete($server->{'kvm_vg_total'});
	delete($server->{'kvm_vg_used'});
	delete($server->{'kvm_vg_free'});
	}
}

# type_kvm_get_atboot(&server)
# Returns 1 if some some KVM instance is started at boot time, by looking
# for a line that starts it in /etc/init.d/cloudmin-kvm or /etc/rc.local
sub type_kvm_get_atboot
{
my ($server) = @_;
my $vhost = &type_kvm_parent($server);
my $bfile;
if (&stat_file_on_server($vhost, "/etc/init.d")) {
	# Use init script
	$bfile = "/etc/init.d/cloudmin-kvm";
	}
else {
	$bfile = "/etc/rc.local";
	}
my $data = &get_file_data_from_server($vhost, $bfile);
foreach my $l (split(/\r?\n/, $data)) {
	my $kvm = &parse_kvm_start_command($l);
	if ($kvm && $kvm->{'filesystem'} eq $server->{'kvm_filesystem'}) {
		return 1;
		}
	}
return 0;
}

# type_kvm_set_atboot(&server, 0=no, 1=yes, 2=update-if-there)
# Enable some KVM system at boot time, by adding a line to run it to
# /etc/init.d/cloudmin-kvm or /etc/rc.local
sub type_kvm_set_atboot
{
my ($server, $atboot) = @_;
my $vhost = &type_kvm_parent($server);
my $cmd = &get_kvm_start_command($server).
	  " >>/var/log/cloudmin-kvm.log 2>&1 </dev/null &";
my $temp = &transname();
if (&stat_file_on_server($vhost, "/etc/init.d")) {
	# Insert into init script
	my $bfile = "/etc/init.d/cloudmin-kvm";
	if (&stat_file_on_server($vhost, $bfile)) {
		# File already exists
		my $err = &get_file_from_server($vhost, $bfile, $temp);
		return "Failed to read $bfile : $err" if ($err);
		}
	else {
		# Use template init script
		&copy_source_dest("$module_root_directory/cloudmin-kvm-init",
				  $temp);
		}

	# Check if already in startup script
	my $lref = &read_file_lines($temp);
	my $lnum;
	for(my $i=0; $i<@$lref; $i++) {
		my $kvm = &parse_kvm_start_command($lref->[$i]);
		if ($kvm &&
		    $kvm->{'filesystem'} eq $server->{'kvm_filesystem'}) {
			$lnum = $i;
			last;
			}
		}

	if ($atboot == 1 && !defined($lnum)) {
		# Insert startup line into script
		for(my $i=0; $i<@$lref; $i++) {
			if ($lref->[$i] =~ /^(\s*);;/ ||
			    $lref->[$i] =~ /^(\s*)RETVAL=/) {
				# Found end of start section .. add it
				splice(@$lref, $i, 0, $1.$cmd);
				last;
				}
			}
		}
	elsif ($atboot == 0 && defined($lnum)) {
		# Delete line from script
		splice(@$lref, $lnum, 1);
		}
	elsif ($atboot == 2 && defined($lnum)) {
		# Update line in script
		$lref->[$lnum] =~ s/\S.*$//;
		$lref->[$lnum] .= $cmd;
		}
	&flush_file_lines($temp);
	$err = &put_file_to_server($vhost, $temp, $bfile);
	return "Failed to save $bfile : $err" if ($err);

	# Make sure it is started at boot
	my ($out, $ex, $err) = &execute_command_on_server($vhost,
	    "chkconfig cloudmin-kvm on || update-rc.d cloudmin-kvm defaults");
	return $err ? $err : $ex ? $out : undef;
	}
else {
	# Add to end of rc.local file
	my $bfile = "/etc/rc.local";
	my $err = &get_file_from_server($vhost, $bfile, $temp);
	return $err if ($err);

	# Check if already in rc.local file
	my $lref = &read_file_lines($temp);
	my $lnum;
	for(my $i=0; $i<@$lref; $i++) {
		my $kvm = &parse_kvm_start_command($lref->[$i]);
		if ($kvm &&
		    $kvm->{'filesystem'} eq $server->{'kvm_filesystem'}) {
			$lnum = $i;
			last;
			}
		}

	# Add or remove if needed
	if ($atboot == 1 && !defined($lnum)) {
		# Add at end
		push(@$lref, $cmd);
		}
	elsif ($atboot == 0 && defined($lnum)) {
		# Remove from script
		splice(@$lref, $lnum, 1);
		}
	elsif ($atboot == 2 && defined($lnum)) {
		# Update if there
		$lref->[$lnum] = $cmd;
		}
	&flush_file_lines($temp);
	$err = &put_file_to_server($vhost, $temp, $bfile);
	return $err;
	}
}

# type_kvm_create_image(&server, &image, tempdir, [nomunge])
# Convert a KVM system into an image file, which is really just the KVM disk.
# Outputs text, and returns 0 on failure.
sub type_kvm_create_image
{
my ($server, $image, $tempdir, $nomunge) = @_;
my $vhost = &type_kvm_parent($server);

# Mount the disk image
&$first_print($text{'mkimage_kvmmount'});
my $fsfile = $server->{'kvm_filesystem'};
my $err = &type_kvm_mount_filesystem($server);
if ($err) {
	&$second_print(&text('create_exenmount', $err));
	return 0;
	}
&$second_print(&text('create_xenmounted', "<tt>$server->{'kvm_mount'}</tt>"));

if ($nomunge != 1) {
	# Munge some or all files
	my ($mok, $munged) = &munge_all_files($server, 0, $nomunge == 2);
	return 0 if (!$mok);
	$server->{'munged'} = $munged;
	}

# Un-mount
&$first_print($text{'mkimage_kvmumount'});
&type_kvm_umount_filesystem($server);
&$second_print($text{'create_done'});

# Get the size of the raw disk
my $disks = &type_kvm_list_disks($server, 0);
my $rawsize;
if (ref($disks)) {
	my ($d) = grep { $_->{'real'} eq $fsfile } @$disks;
	if ($d) {
		$rawsize = $d->{'size'};
		}
	}
if (!$rawsize) {
	my @st = &stat_file_on_server($vhost, $fsfile);
	$rawsize = $st[7];
	}
$image->{'rawsize'} = $rawsize;

if (!$image->{'nocompress'}) {
	# Compress disk image to a temp file
	&$first_print($text{'mkimage_xengzip'});
	my $gzfile = $image->{'id'}.".ext3.gz";
	my ($out, $ex, $err) = &execute_command_on_server($vhost,
	    ($server->{'kvm_filesystem_lv'} ?
		"dd if=".quotemeta($fsfile)." bs=32768 | gzip -c" :
		"gzip -c ".quotemeta($fsfile)).
	    " >".quotemeta("$tempdir/$gzfile"));
	if ($ex) {
		&$second_print(&text('mkimage_ekvmgzip', "<pre>$out</pre>"));
		}
	else {
		&$second_print($text{'create_done'});
		$image->{'files'} = $gzfile;
		}
	}
else {
	# Just use the image file as-is
	&$first_print($text{'mkimage_xengzip2'});
	my $imgfile = $image->{'id'}.".ext3";
	my ($out, $ex, $err) = &execute_command_on_server($vhost,
		$server->{'kvm_filesystem_lv'} ?
			"dd if=".quotemeta($fsfile).
			  " of=".quotemeta("$tempdir/$imgfile")." bs=32768" :
			"ln -s ".quotemeta($fsfile)." ".
			  quotemeta("$tempdir/$imgfile"));
	if ($ex) {
		&$second_print(&text('mkimage_ekvmlink', "<pre>$out</pre>"));
		}
	else {
		&$second_print($text{'create_done'});
		$image->{'files'} = $imgfile;
		}
	}

return 1;
}

# type_kvm_cleanup_image(&server, &image, tempdir)
# Delete all temp files created on the host system for an image, and reverse
# any munge processes that were done to prepare the imaged system.
sub type_kvm_cleanup_image
{
my ($server, $image, $tempdir) = @_;
my $vhost = &type_kvm_parent($server);

# Remove compressed image
&$first_print($text{'mkimage_xendelete'});
my $gzfile = $image->{'id'}.".ext3.gz";
my ($out, $ex, $err) = &execute_command_on_server($vhost,
				"rm -f ".quotemeta("$tempdir/$gzfile"));
$err = $out if ($ex);
if ($err) {
	&$second_print(&text('mkimage_exendelete', $out));
	return 0;
	}
else {
	&$second_print($text{'create_done'});
	}

# Re-mount KVM filesystem
&$first_print($text{'mkimage_kvmmount'});
my $err = &type_kvm_mount_filesystem($server);
if ($err) {
	&$second_print(&text('create_ekvmmount', $err));
	return 0;
	}
&$second_print(&text('create_xenmounted', "<tt>$server->{'kvm_mount'}</tt>"));

# Undo all munged files
&unmunge_all_files($server, $server->{'munged'});
delete($server->{'munged'});

# Un-mount KVM filesystem
&$first_print($text{'mkimage_kvmumount'});
&type_kvm_umount_filesystem($server);
&$second_print($text{'create_done'});

return 1;
}

# check_kvm_host_software(&server)
# Checks if some system has the KVM software installed, and the kernel
# patch needed to use it.
sub check_kvm_host_software
{
my ($server) = @_;

# Check if linux
my ($out, $ex, $err) = &execute_command_on_server($server, "uname");
return $text{'kvm_elinux'} if ($out !~ /linux/i);

# Check commands
my $full = &has_command_on_server($server, "qemu-kvm");
if (!$full) {
	$full = &has_command_on_server($server, "kvm");
	}
return &text('kvm_ewhich2', "<tt>qemu-kvm</tt>", "<tt>kvm</tt>") if (!$full);
&has_command_on_server($server, "qemu-img") ||
	return &text('kvm_ewhich', "<tt>qemu-img</tt>");

# Check CPU
my ($out, $ex, $err) = &execute_command_on_server($server,
	"cat /proc/cpuinfo");
if ($out !~ /flags\s*:\s*.*(vmx|svm)/) {
	return $text{'kvm_ecpu'};
	}

# Check kernel
my ($out, $ex, $err) = &execute_command_on_server($server,
				"test -e /dev/kvm");
return $text{'kvm_ekernel'} if ($ex);

return undef;
}

# type_kvm_open_shell(&server)
# Runs SSH to connect to a remote system. Returns an error message
# (or undef if OK), and a file handle.
sub type_kvm_open_shell
{
my ($server) = @_;
my ($out, $ex, $err, $status, $fh, $fpid) =
	&execute_command_on_server($server, "/bin/sh", 0, 1);
return $err ? ($err, undef) : $ex ? ($out, undef) : (undef, $fh);
}

# type_kvm_get_dns_name(&server)
# Returns a system's DNS name and zone name
sub type_kvm_get_dns_name
{
my $vhost = &get_parent_server($server);
return ( $server->{'kvm_dns'}, $vhost->{'kvm_zone'} );
}

# list_kvm_host_bridges(&vhost)
# Returns the list of names of bridges on some KVM host system. Tries brctl 
# show first, then ifconfig
sub list_kvm_host_bridges
{
my ($vhost) = @_;
my @rv;
my ($out, $ex, $err) = &execute_command_on_server($vhost, "brctl show");
if (!$ex && !$err) {
	foreach my $l (split(/\r?\n/, $out)) {
		if ($l !~ /^bridge\s+name/ && $l =~ /^(\S+)/) {
			push(@rv, $1);
			}
		}
	}
if (!@rv) {
	my $ifaces = &list_active_server_interfaces($vhost);
	if (ref($ifaces)) {
		@rv = map { $_->{'fullname'} }
			  grep { $_->{'fullname'} =~ /^br/ &&
				 $_->{'virtual'} eq '' } @$ifaces;
		}
	}
return @rv;
}

# list_kvm_instances(&vhost)
# Returns a list of running KVM processes as an array ref, or an error message
sub list_kvm_instances
{
my ($vhost) = @_;
my $procs = &list_processes_on_server($vhost);
return $procs if (!ref($procs));
my @rv;
foreach my $p (@$procs) {
	my $kvm = &parse_kvm_start_command($p->{'args'});
	if ($kvm) {
		$kvm->{'pid'} = $p->{'pid'};
		push(@rv, $kvm);
		}
	}
return \@rv;
}

# parse_kvm_start_command(command-line)
# Converts a KVM command line into a hash ref with details of the flags
sub parse_kvm_start_command
{
my ($line) = @_;
if ($line =~ /^\s*(\S+\/|)(qemu-kvm|kvm)\s+(.*)/) {
	# Found a possible KVM line .. parse the args
	my ($cmd, $args) = ($2, $3);
	my @w = &split_quoted_string($args);
	my $ah = { };
	my $kvm = { 'args' => $ah,
		    'binary' => $cmd,
		    'cmd' => $line };
	my $lastarg;
	while(@w) {
		my $a = shift(@w);
		if ($a =~ /^\-+(\S+)$/) {
			# Start of a new arg
			$lastarg = $1;
			if ($ah->{$lastarg}) {
				# Already seen .. convert to array
				$ah->{$lastarg} = [ $ah->{$lastarg} ];
				}
			if (ref($ah->{$lastarg})) {
				# Add to array
				push(@{$ah->{$lastarg}}, "");
				}
			else {
				# Start of a single value
				$ah->{$lastarg} = "";
				}
			}
		else {
			# Value for an arg
			if (ref($ah->{$lastarg})) {
				# Add to end of list
				my $v = $ah->{$lastarg};
				$v[@$v-1] .= " " if ($v[@$v-1]);
				$v[@$v-1] .= $a;
				}
			else {
				# Add to single value
				$ah->{$lastarg} .= " "
					if ($ah->{$lastarg});
				$ah->{$lastarg} .= $a;
				}
			}
		}

	# Work out main drive
	if ($ah->{'hda'}) {
		$kvm->{'filesystem'} = $ah->{'hda'};
		}
	elsif ($ah->{'drive'}) {
		# Lowest-index disk set with -drive flag
		my @d = ref($ah->{'drive'}) ? @{$ah->{'drive'}}
					    : ( $ah->{'drive'} );
		my $lowindex = 9999;
		foreach my $d (@d) {
			my %dinfo = map { split(/=/, $_) }
					split(/,/, $d);
			if ($dinfo{'file'} &&
			    $dinfo{'media'} ne 'cdrom' &&
			    $dinfo{'index'} < $lowindex) {
				$kvm->{'filesystem'} = $dinfo{'file'};
				$lowindex = $dinfo{'index'};
				}
			}
		}

	if ($kvm->{'filesystem'} && $kvm->{'filesystem'} !~ /^\//) {
		# Relative path used .. normalize
		my $cwd = &get_kvm_process_dir($vhost, $p->{'pid'});
		if ($cwd) {
			$kvm->{'filesystem'} =
				$cwd."/".$kvm->{'filesystem'};
			}
		}
	return $kvm;
	}
return undef;
}

# get_server_kvm_instance(&server)
# Returns details of the KVM process for some managed system
sub get_server_kvm_instance
{
my ($server) = @_;
my $vhost = &get_parent_server($server);
my $procs = &list_kvm_instances($vhost);
return undef if (!$procs);
my ($proc) = grep { $_->{'filesystem'} eq $server->{'kvm_filesystem'} } @$procs;
return $proc;
}

# get_kvm_process_dir(&vhost, pid)
# Find the curent directory of some kvm process, useful for resolving relative
# disk paths.
sub get_kvm_process_dir
{
my ($vhost, $pid) = @_;
my ($out, $ex, $err) = &execute_command_on_server($vhost,
				"readlink /proc/$pid/cwd");
if (!$ex && !$err) {
	$out =~ s/\r|\n//g;
	return $out;
	}
return undef;
}

# kvm_instance_chooser_button(instance-field, host-field)
# Returns HTML for a popup window for selecting a running KVM instance
sub kvm_instance_chooser_button
{
my ($ifield, $hfield) = @_;
return "<input type=button onClick='ifield = form.$ifield; chooser = window.open(\"kvm_chooser.cgi?host=\"+escape(form.$hfield.value), \"chooser\", \"toolbar=no,menubar=no,scrollbar=no,width=600,height=300\"); chooser.ifield = ifield; window.ifield = ifield' value=\"...\">\n";
}

1;

