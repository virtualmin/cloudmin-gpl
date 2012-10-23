# Functions for managing iSCSI servers and clients

# supports_iscsi()
# Returns 1 if iSCSI configuration is supported on this Cloudmin install
sub supports_iscsi
{
return &indexof("kvm", @virtual_server_management_types) >= 0 ||
       &indexof("xen", @virtual_server_management_types) >= 0;
}

# list_iscsi_target_servers()
# Returns a list of managed systems that are setup as an iSCSI server
sub list_iscsi_target_servers
{
return grep { $_->{'iscsi_module'} } &list_managed_servers();
}

# list_possible_iscsi_target_servers()
# Returns physical systems only
sub list_possible_iscsi_target_servers
{
return grep { $_->{'manager'} eq 'real' ||
	      $_->{'manager'} eq 'this' } &list_managed_servers();
}

# check_iscsi_server(&server)
# If a system can be an iSCSI server, return 1 and the Webmin module to use.
# Otherwise return 0 and an error message explaining why.
sub check_iscsi_server
{
my ($server) = @_;
if (!&can_ssh_status($server)) {
	return (0, $text{'iscsi_nossh'});
	}
if ($server->{'status'} ne 'virt' && $server->{'status'} ne 'novirt') {
	return (0, $text{'iscsi_nowebmin'});
	}
my $info = &get_server_collected($server);
if ($info->{'general'}->{'version'} < 1.600) {
	return (0, $text{'iscsi_noversion'});
	}
my $mod;
foreach my $m ("iscsi-target", "iscsi-server") {
	next if (!&remote_foreign_check($server, $m));
	&remote_foreign_require($server, $m);
	next if (!&remote_foreign_call($server, $m, "foreign_installed", $m));
	$mod = $m;
	last;
	}
if (!$mod) {
	return (0, $text{'iscsi_nomod'});
	}
return (1, $mod);
}

# check_iscsi_client(&server)
# Returns undef if some system can be an iSCSI client, 0 if not
sub check_iscsi_client
{
my ($server) = @_;
if (!&can_ssh_status($server)) {
	return $text{'iscsi_cnossh'};
	}
if ($server->{'status'} ne 'virt' && $server->{'status'} ne 'novirt') {
	return $text{'iscsi_cnowebmin'};
	}
my $info = &get_server_collected($server);
if ($info->{'general'}->{'version'} < 1.600) {
	return $text{'iscsi_cnoversion'};
	}
if (!&remote_foreign_check($server, "iscsi-client")) {
	return $text{'iscsi_cnomod'};
	}
&remote_foreign_require($server, "iscsi-client");
if (!&remote_foreign_call($server, "iscsi-client", "foreign_installed",
			  "iscsi-client")) {
	return $text{'iscsi_cnoclient'};
	}
return undef;
}

# create_iscsi_disk(&server, &disk)
# On the iSCSI server for the given VM's host, create and export the given disk.
# Returns undef on success, or an error message on failure.
sub create_iscsi_disk
{
my ($server, $disk) = @_;

# Get the host system and thus the iSCSI server and connect
my $vhost = &get_parent_server($server);
$vhost || return "No host system found!";
my $id = $vhost->{$server->{'manager'}.'_iscsi'};
$id eq '' && return "Host system $vhost->{'host'} is not configured ".
		    "to use iSCSI";
my $scsiserver = &get_managed_server($id);
$scsiserver || return "iSCSI server with ID $id does not exist!";
my $mod = $scsiserver->{'iscsi_module'};
$mod || return "System $scsiserver->{'host'} is no longer an iSCSI server";
$last_remote_error = undef;
&remote_foreign_require($iscsiserver, $mod);
$last_remote_error && return "Error loading $mod : $last_remote_error";

# Make sure the iSCSI server is running
if ($mod eq "iscsi-target") {
	&remote_foreign_call($iscsiserver, $mod, "is_iscsi_target_running") ||
		return "iSCSI server is not running on $iscsiserver->{'host'}";
	}
elsif ($mod eq "iscsi-server") {
	&remote_foreign_call($iscsiserver, $mod, "is_iscsi_server_running") ||
		return "iSCSI server is not running on $iscsiserver->{'host'}";
	}
else {
	return "Unknown module $mod";
	}

# Try a test query of targets from the vhost
$last_remote_error = undef;
&remote_foreign_require($vhost, "iscsi-cient");
$last_remote_error &&
	return "Error loading iSCSI client module : $last_remote_error";
my $ip = &get_server_ip($iscsiserver);
my $targets = &remote_foreign_call($vhost, "iscsi-client",
				   "list_iscsi_targets", $ip);
ref($targets) || return "Failed to list targets on $iscsiserver->{'host'} ".
			"from $vhost->{'host'} : $targets";

# Create the disk file or LV
my $dir = $vhost->{'iscsi_base_dir'};
my $vg = $vhost->{'iscsi_base_vg'};
$server->{'iscsi_disk_count'} ||= 0;
my $real;
my $suffix = $server->{'host'}."_".$server->{'iscsi_disk_count'}."_img";
if ($vg) {
	# Create a logical volume
	&remote_foreign_require($iscsiserver, "lvm");
	$last_remote_error &&
		return "Error loading LVM module : $last_remote_error";
	my $lv = { 'name' => $suffix,
		   'size' => $disk->{'size'} / 1024,
		   'perm' => 'rw',
		   'alloc' => 'n',
		   'vg' => $vg };
	my $err = &remote_foreign_call($iscsiserver, "lvm",
				       "create_logical_volume", $lv);
	$err ||= $last_remote_error;
	return "LVM logical volume creation failed : $err" if ($err);

	# Zero out first 32k
	$real = "/dev/$lv->{'vg'}/$lv->{'name'}";
	my $cmd = &dd_command("/dev/zero", $real, 32768);
	my ($out, $ex, $err) = &execute_command_on_server(
					$iscsiserver, $cmd);
	$err = $out if ($ex);
	$err && return "Failed to zero out $real : $err";
	}
else {
	# Create an empty file
	$real = $dir."/".$suffix;
	my $cmd = &dd_command("/dev/zero", $real, $disk->{'size'});
	my ($out, $ex, $err) = &execute_command_on_server($iscsiserver, $cmd);
	$err = $out if ($ex);
	$err && return "Failed to create file $real : $err";
	}
$server->{'iscsi_disk_count'}++;

# Export via iSCSI
my $targetname;
if ($mod eq "iscsi-server") {
	# Add an extent
	my $conf = &remote_foreign_call($iscsiserver, $mod, "get_iscsi_config");
	my $extent = { 'num' => &remote_foreign_call($iscsiserver, $mod,
					"find_free_num", $conf, 'extent'),
		       'type' => 'extent' };
	$extent->{'device'} = $real;
	$extent->{'start'} = 0;
	$extent->{'size'} = $disk->{'size'};
	&remote_foreign_call($iscsiserver, $mod, "save_directive", $conf,
			     undef, $extent);
	$last_remote_error &&
		return "Failed to create extent : $last_remote_error";

	# Add a target for the extent
	my $target = { 'num' => &remote_foreign_call($iscsiserver, $mod,
					"find_free_num", $conf, 'target'),
		       'type' => 'target' };
	$target->{'export'} = 'extent'.$extent->{'num'};
	$target->{'flags'} = 'rw';
	$target->{'network'} = 'any';
	&remote_foreign_call($iscsiserver, $mod, "save_directive", $conf,
			     undef, $target);
	$last_remote_error &&
		return "Failed to create target : $last_remote_error";

	# Apply the config
	my $err = &remote_foreign_call($iscsiserver, $mod,
				       "restart_iscsi_server");
	return "Failed to apply iSCSI server configuration : $err" if ($err);

	$targetname = $target->{'export'};
	}
elsif ($mod eq "iscsi-target") {
	# Add a target
	my $pconf = &remote_foreign_call($iscsiserver, $mod,
					 "get_iscsi_config_parent");
	my $conf = $pconf->{'members'};
	my $host = &remote_foreign_call($iscsiserver, $mod,
					"find_host_name", $conf) ||
		   &remote_foreign_call($iscsiserver, $mod,
					"generate_host_name");
	$target = { 'name' => 'Target',
		    'value' => $host.":".$suffix,
                    'members' => [ ] };
	push(@{$target->{'members'}},
	     { 'name' => 'Lun',
	       'value' => '1 Path='.$real });
	&remote_foreign_call($iscsiserver, $mod,
		"save_directive", $conf, $pconf, [ ], [ $target ]);
	&remote_foreign_call($iscsiserver, $mod, "flush_file_lines");

	# Apply the config
	my $err = &remote_foreign_call($iscsiserver, $mod,
				       "restart_iscsi_server");
	return "Failed to apply iSCSI server configuration : $err" if ($err);

	$targetname = $target->{'value'};
	}

# Get list of available targets on host from server
my $targets = &remote_foreign_call($vhost, "iscsi-client",
				   "list_iscsi_targets", $ip);
ref($targets) || return "Failed to list targets on $iscsiserver->{'host'} ".
			"from $vhost->{'host'} : $targets";
my ($rtarget) = grep { $_->{'target'} eq $targetname } @$targets;
$rtarget || return "Expected target $targetname is not shared by ".
		   $iscsiserver->{'host'};

# Connect from host system
# XXX clean up disk if failed?
my $err = &remote_foreign_call($vhost, "iscsi-cient", $ip, 3260, undef,
			       $rtarget);
return "iSCSI connection failed : $err" if ($err);

# Set real path in disk object
my $conns = &remote_foreign_call($vhost, "iscsi-client",
				 "list_iscsi_connections");
my ($conn) = grep { $_->{'ip'} eq $ip &&
		    $_->{'name'} eq $rtarget->{'name'} &&
		    $_->{'target'} eq $targetname } @$conns;
$conn || return "No iSCSI connection to $ip for ".
		"$rtarget->{'name'}:$targetname found on $vhost->{'host'}";
$disk->{'real'} = $conn->{'longdevice'} ||
		  "/dev/disk/by-path/ip-$conn->{'ip'}:$conn->{'port'}-".
		  "iscsi-$conn->{'name'}:$conn->{'target'}-lun-1";
foreach my $f ("ip", "port", "name", "target") {
	$disk->{'iscsi_'.$f} = $conn->{$f};
	}
$disk->{'iscsi_lun'} = $conn->{'scsilun'};
$disk->{'iscsi_server'} = $iscsiserver->{'id'};

return undef;
}

1;
