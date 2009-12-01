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
							  "poweroff -f");
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

# Run qemu-kvm to start it up, in the background
my $temp = &tempname_on_server($vhost);
my ($out, $ex, $err) = &execute_command_on_server($vhost,
				"$cmd >$temp 2>&1 </dev/null &");
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
my $out = &get_file_data_from_server($vhost, $temp);
&delete_file_on_server($vhost, $temp);
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
my $conf = &get_kvm_config($server, 1);
return "Failed to get KVM config file" if (!ref($conf));

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
# XXX

# Parse disks in Xen config
my $disks = &kvm_find_value("disk", $conf);
my @rv;
foreach my $d (@$disks) {
	if ($d =~ /^(file|phy|tap:aio):(\S+),(\S+),(\S+)$/) {
		# A regular file
		my $disk = { 'real' => $2,
			     'virt' => "/dev/$3",
			     'virtdev' => $3,
			     'suffix' => $1,
			     'mode' => $4, };
		$disk->{'device'} = $1 eq "phy";
		if (!$disk->{'device'}) {
			my @st = &stat_file_on_server($vhost, "$2");
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
			$d->{'mounted'} = $mounted{$d->{'virt'}};
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
			my ($disk) = grep { $_->{'virt'} eq $fs } @rv;
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
my $err = &type_kvm_mount_filesystem($server);
if ($err) {
	&$second_print(&text('create_ekvmmount', $err));
	return 0;
	}
&$second_print(&text('create_kvmmounted', "<tt>$server->{'kvm_mount'}</tt>"));

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
# XXX
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
	&$first_print($text{'mkimage_kvmgzip'});
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
&$second_print(&text('create_kvmmounted', "<tt>$server->{'kvm_mount'}</tt>"));

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

