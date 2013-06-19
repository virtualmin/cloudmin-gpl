# Functions for managing iSCSI servers and clients

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
if ($info->{'general'}->{'version'} < 1.605) {
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

# Is Webmin up to date?
my $info = &get_server_collected($server);
if ($info->{'general'}->{'version'} < 1.605) {
	return $text{'iscsi_cnoversion'};
	}

# Is module installed?
if (!&remote_foreign_check($server, "iscsi-client")) {
	return $text{'iscsi_cnomod'};
	}

# Is module working?
&remote_foreign_require($server, "iscsi-client");
my $err = &remote_foreign_call($server, "iscsi-client", "check_config");
if ($err) {
	return &text('iscsi_cnoclient', $err);
	}

# Is iscsi automatic startup enabled?
my $conf = &remote_foreign_call($server, "iscsi-client", "get_iscsi_config");
my ($startup) = grep { $_->{'name'} eq 'node.startup' } @$conf;
if (!$startup || $startup->{'value'} ne 'automatic') {
	return $text{'iscsi_cnostartup'};
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
my $id = $disk->{'iscsi_server'};
$id = $vhost->{$server->{'manager'}.'_iscsi'} if ($id eq '');
$id = $server->{$server->{'manager'}.'_filesystem_iscsi'} if ($id eq '');
$id eq '' && return "Host system $vhost->{'host'} is not configured ".
		    "to use iSCSI";
my $iscsiserver = &get_managed_server($id);
$iscsiserver || return "iSCSI server with ID $id does not exist!";
my $mod = $iscsiserver->{'iscsi_module'};
$mod || return "System $iscsiserver->{'host'} is no longer an iSCSI server";
$last_remote_error = undef;
&remote_foreign_require($iscsiserver, $mod);
$last_remote_error && return "Error loading $mod : $last_remote_error";

# If the system has no iSCSI login yet, generate one
if (!$server->{'iscsi_user'}) {
	$server->{'iscsi_user'} = $server->{'host'};
	$server->{'iscsi_pass'} = &generate_random_password(12);
	}

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
&remote_foreign_require($vhost, "iscsi-client");
$last_remote_error &&
	return "Error loading iSCSI client module : $last_remote_error";
my $ip = &get_server_ip($iscsiserver);
my $targets = &remote_foreign_call($vhost, "iscsi-client",
				   "list_iscsi_targets", $ip);
ref($targets) || return "Failed to list targets on $iscsiserver->{'host'} ".
			"from $vhost->{'host'} : $targets";

# Create the disk file or LV
my $dir = $iscsiserver->{'iscsi_base_dir'};
my $vg = $iscsiserver->{'iscsi_base_vg'};
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
	if ($mod eq "iscsi-server") {
		# Add 1M to handle overhead needed by netbsd iscsi server
		$lv->{'size'} += 1024;
		}
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
$disk->{'iscsi_real'} = $real;

# Export via iSCSI
my $targetname;
if ($mod eq "iscsi-server") {
	# Get iSCSI server configuration
	my $conf = &remote_foreign_call($iscsiserver, $mod, "get_iscsi_config");
	$last_remote_error &&
		return "Failed to get config : $last_remote_error";

	# Work out the target name
	my $target = { 'type' => 'target' };
	if ($disk->{'iscsi_target'} =~ /target(\d+)$/) {
		$target->{'num'} = $1;
		}
	else {
		$target->{'num'} = &remote_foreign_call($iscsiserver, $mod,
                                        "find_free_num", $conf, 'target');
		}
	$targetname = $target->{'type'}.$target->{'num'};
	my ($rtarget) = grep { $_->{'target'} eq $targetname } @$targets;
	$rtarget && return "Target $targetname is already being exported!";

	# Get iSCSI users
	my @users =  &remote_foreign_call($iscsiserver, $mod,
					  "list_iscsi_users");
	$last_remote_error &&
		return "Failed to list users : $last_remote_error";

	# Add an extent
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

	# Update the target object with the extent, and then create it
	$target->{'export'} = 'extent'.$extent->{'num'};
	$target->{'flags'} = 'rw';
	$target->{'network'} = '0/0';
	&remote_foreign_call($iscsiserver, $mod, "save_directive", $conf,
			     undef, $target);
	$last_remote_error &&
		return "Failed to create target : $last_remote_error";
	&remote_foreign_call($iscsiserver, $mod, "flush_file_lines");
	$last_remote_error &&
		return "Failed to flush file : $last_remote_error";

	# Add or update the user
	my ($user) = grep { $_->{'user'} eq $server->{'iscsi_user'} } @users;
	if (!$user) {
		# Create the user
		$user = { 'user' => $server->{'iscsi_user'},
			  'pass' => $server->{'iscsi_pass'},
			  'mode' => 'chap' };
		&remote_foreign_call($iscsiserver, $mod,
				     "create_iscsi_user", $user);
		}
	elsif ($user->{'pass'} ne $server->{'iscsi_pass'}) {
		# Fix password
		$user->{'pass'} = $server->{'iscsi_pass'};
		&remote_foreign_call($iscsiserver, $mod,
				     "modify_iscsi_user", $user);
		}

	# Apply the config
	my $err = &remote_foreign_call($iscsiserver, $mod,
				       "restart_iscsi_server");
	$err ||= $last_remote_error;
	return "Failed to apply iSCSI server configuration : $err" if ($err);
	}
elsif ($mod eq "iscsi-target") {
	# Add a target
	my $pconf = &remote_foreign_call($iscsiserver, $mod,
					 "get_iscsi_config_parent");
	$last_remote_error &&
		return "Failed to get config : $last_remote_error";
	my $conf = $pconf->{'members'};
	my $host = &remote_foreign_call($iscsiserver, $mod,
					"find_host_name", $conf) ||
		   &remote_foreign_call($iscsiserver, $mod,
					"generate_host_name");
	$last_remote_error &&
		return "Failed to get iSCSI hostname : $last_remote_error";
	$targetname = $disk->{'iscsi_target'} || $suffix;
	my ($rtarget) = grep { $_->{'target'} eq $targetname } @$targets;
	$rtarget && return "Target $targetname is already being exported!";
	$target = { 'name' => 'Target',
		    'value' => $host.":".$targetname,
                    'members' => [ ] };
	my $type = $real =~ /^\/dev\// ? 'blockio' : 'fileio';
	$type = "fileio";
	push(@{$target->{'members'}},
	     { 'name' => 'Lun',
	       'value' => '1 Type='.$type.',Path='.$real });
	push(@{$target->{'members'}},
	     { 'name' => 'IncomingUser',
	       'value' => $server->{'iscsi_user'}.' '.$server->{'iscsi_pass'}});
	&remote_foreign_call($iscsiserver, $mod,
		"save_directive", $conf, $pconf, [ ], [ $target ]);
	$last_remote_error &&
		return "Failed to create target : $last_remote_error";
	&remote_foreign_call($iscsiserver, $mod, "flush_file_lines");
	$last_remote_error &&
		return "Failed to flush file : $last_remote_error";

	# Apply the config
	my $err = &remote_foreign_call($iscsiserver, $mod,
				       "restart_iscsi_server");
	$err ||= $last_remote_error;
	return "Failed to apply iSCSI server configuration : $err" if ($err);

	$disk->{'iscsi_name'} = $host;
	}
$disk->{'iscsi_target'} = $targetname;

# Wait for server to restart fully
sleep(10);

# Get list of available targets on host from server
my $targets = &remote_foreign_call($vhost, "iscsi-client",
				   "list_iscsi_targets", $ip);
ref($targets) || return "Failed to list targets on $iscsiserver->{'host'} ".
			"from $vhost->{'host'} : $targets";
my ($rtarget) = grep { $_->{'target'} eq $targetname } @$targets;
if (!$rtarget) {
	&delete_iscsi_disk($server, $disk);
	return "Expected target $targetname is not shared by ".
	       $iscsiserver->{'host'};
	}

# Connect from host system
my $err = &remote_foreign_call($vhost, "iscsi-client",
		"create_iscsi_connection", $ip, 3260, undef, $rtarget,
		"CHAP", $server->{'iscsi_user'}, $server->{'iscsi_pass'});
if ($err) {
	&delete_iscsi_disk($server, $disk);
	return "iSCSI connection failed : $err";
	}
$disk->{'iscsi_ip'} = $ip;
$disk->{'iscsi_port'} = 3260;

# Set real path in disk object
my $conns = &remote_foreign_call($vhost, "iscsi-client",
				 "list_iscsi_connections");
my ($conn) = grep { $_->{'ip'} eq $ip &&
		    $_->{'name'} eq $rtarget->{'name'} &&
		    $_->{'target'} eq $targetname } @$conns;
if (!$conn) {
	$disk->{'iscsi_connect'} = -1;
	&delete_iscsi_disk($server, $disk);
	return "No iSCSI connection to $ip for ".
	       "$rtarget->{'name'}:$targetname found on $vhost->{'host'}";
	}
$conn->{'scsilun'} = 1 if ($conn->{'scsilun'} eq '');
$disk->{'real'} = $conn->{'longdevice'} ||
		  "/dev/disk/by-path/ip-$conn->{'ip'}:$conn->{'port'}-".
		  "iscsi-$conn->{'name'}:$conn->{'target'}-lun-$conn->{'scsilun'}";

# Wait 10 seconds for disk device to appear
my @st;
for(my $i=0; $i<10; $i++) {
	@st = &stat_file_on_server($vhost, $disk->{'real'});
	last if (@st);
	sleep(1);
	}

# Fail if disk isn't available
if (!@st) {
	$disk->{'iscsi_connect'} = -1;
	&delete_iscsi_disk($server, $disk);
	return "Expected iSCSI disk device $disk->{'real'} does not exist ".
	       "on host system $vhost->{'host'}";
	}
foreach my $f ("ip", "port", "name", "target") {
	$disk->{'iscsi_'.$f} = $conn->{$f};
	}
$disk->{'iscsi_lun'} = $conn->{'scsilun'};
$disk->{'iscsi_server'} = $iscsiserver->{'id'};
$disk->{'iscsi_connect'} = 1;

return undef;
}

# delete_iscsi_disk(&server, &disk)
# On the iSCSI server for the given VM's host, un-export and delete the given
# disk. Returns undef on success, or an error message on failure.
sub delete_iscsi_disk
{
my ($server, $disk) = @_;

# Get the host system and thus the iSCSI server
my $vhost = &get_parent_server($server);
$vhost || return "No host system found!";
my $id = $disk->{'iscsi_server'};
$id = $vhost->{$server->{'manager'}.'_iscsi'} if ($id eq '');
$id = $server->{$server->{'manager'}.'_filesystem_iscsi'} if ($id eq '');
$id eq '' && return "Host system $vhost->{'host'} is not configured ".
		    "to use iSCSI";
my $iscsiserver = &get_managed_server($id);
$iscsiserver || return "iSCSI server with ID $id does not exist!";
my $mod = $iscsiserver->{'iscsi_module'};
$mod || return "System $iscsiserver->{'host'} is no longer an iSCSI server";
$last_remote_error = undef;
&remote_foreign_require($iscsiserver, $mod);
$last_remote_error && return "Error loading $mod : $last_remote_error";

# Disconnect from the host system
&remote_foreign_require($vhost, "iscsi-client");
$last_remote_error && return "Error loading iscsi-client : $last_remote_error";
my $conn = { 'name' => $disk->{'iscsi_name'},
	     'target' => $disk->{'iscsi_target'},
	     'ip' => $disk->{'iscsi_ip'},
	     'port' => $disk->{'iscsi_port'} };
if ($disk->{'iscsi_connect'}) {
	my $err = &remote_foreign_call($vhost, "iscsi-client",
				       "delete_iscsi_connection", $conn);
	$err ||= $last_remote_error;
	if ($disk->{'iscsi_connect'} > 0) {
		$err && return "Failed to disconnect iSCSI connection : $err";
		}
	}

# Find and remove the target
my $real;
if ($mod eq "iscsi-server") {
	# Remove the target
	my $conf = &remote_foreign_call($iscsiserver, $mod, "get_iscsi_config");
	$last_remote_error &&
		return "Failed to get config : $last_remote_error";
	$disk->{'iscsi_target'} =~ /^target(\d+)$/ ||
		return "iSCSI target is not in targetN format";
	my $num = $1;
	my ($target) = grep { $_->{'type'} eq 'target' &&
			      $_->{'num'} eq $num } @$conf;
	$target || return "No target named $disk->{'iscsi_target'} found";
	&remote_foreign_call($iscsiserver, $mod, "save_directive",
			     $conf, $target, undef);
	$last_remote_error &&
		return "Failed to delete target : $last_remote_error";

	# Remove the extent
	$target->{'export'} =~ /^extent(\d+)$/ ||
		return "iSCSI extent is not in extentN format";
	my $num = $1;
	my ($extent) = grep { $_->{'type'} eq 'extent' &&
			      $_->{'num'} eq $num } @$conf;
	$extent || return "No extent named $target->{'export'} found";
	$real = $extent->{'device'};
	&remote_foreign_call($iscsiserver, $mod, "save_directive",
			     $conf, $extent, undef);
	$last_remote_error &&
		return "Failed to delete extent : $last_remote_error";

	# Apply the config
	my $err = &remote_foreign_call($iscsiserver, $mod,
				       "restart_iscsi_server");
	$err ||= $last_remote_error;
	return "Failed to apply iSCSI server configuration : $err" if ($err);
	}
elsif ($mod eq "iscsi-target") {
	# Remove the target
	my $pconf = &remote_foreign_call($iscsiserver, $mod,
					 "get_iscsi_config_parent");
	$last_remote_error &&
		return "Failed to get config : $last_remote_error";
	my $conf = $pconf->{'members'};
	my $targetname = $disk->{'iscsi_name'}.":".$disk->{'iscsi_target'};
	my ($target) = grep { $_->{'name'} eq 'Target' &&
			      $_->{'value'} eq $targetname } @$conf;
	$target || return "No target named $targetname found";
	my ($lun) = grep { $_->{'name'} eq 'Lun' } @{$target->{'members'}};
	if ($lun && $lun->{'value'} =~ /Path=([^,]+)/) {
		$real = $1;
		}
	&remote_foreign_call($iscsiserver, $mod,
                "save_directive", $conf, $pconf, [ $target ], [ ]);
	$last_remote_error &&
		return "Failed to delete target : $last_remote_error";
	&remote_foreign_call($iscsiserver, $mod, "flush_file_lines");
	$last_remote_error &&
		return "Failed to flush file : $last_remote_error";

	# Apply the config
	my $err = &remote_foreign_call($iscsiserver, $mod,
				       "restart_iscsi_server");
	$err ||= $last_remote_error;
	return "Failed to apply iSCSI server configuration : $err" if ($err);
	}
else {
	return "Unknown module $mod";
	}

# Remove the LV or real file
if ($real =~ /^\/dev\/([^\/]+)\/([^\/]+)$/) {
	# Delete LV
	my ($vg, $lv) = ($1, $2);
	&remote_foreign_require($iscsiserver, "lvm");
        $last_remote_error &&
                return "Error loading LVM module : $last_remote_error";
	my $err = &remote_foreign_call($iscsiserver, "lvm",
			"delete_logical_volume", { 'device' => $real });
	return "Failed to delete LV $real : $err" if ($err);
	}
elsif ($real !~ /^\/dev\//) {
	# Delete regular file
	my $err = &delete_file_on_server($iscsiserver, $real);
	return "Failed to delete $real : $err" if ($err);
	}

return undef;
}

# modify_iscsi_disk(&server, &disk, &old-disk)
# Apply a size change to an iSCSI disk
sub modify_iscsi_disk
{
my ($server, $disk, $olddisk) = @_;

# Check if anything needs to change
if ($disk->{'size'} == $olddisk->{'size'}) {
	return undef;
	}

# Get the host system and thus the iSCSI server
my $vhost = &get_parent_server($server);
$vhost || return "No host system found!";
my $id = $disk->{'iscsi_server'};
$id = $vhost->{$server->{'manager'}.'_iscsi'} if ($id eq '');
$id = $server->{$server->{'manager'}.'_filesystem_iscsi'} if ($id eq '');
$id eq '' && return "Host system $vhost->{'host'} is not configured ".
		    "to use iSCSI";
my $iscsiserver = &get_managed_server($id);
$iscsiserver || return "iSCSI server with ID $id does not exist!";
my $mod = $iscsiserver->{'iscsi_module'};
$mod || return "System $iscsiserver->{'host'} is no longer an iSCSI server";
$last_remote_error = undef;
&remote_foreign_require($iscsiserver, $mod);
$last_remote_error && return "Error loading $mod : $last_remote_error";

# Find the target, and from it the underlying file
my $real;
my ($conf, $extent);	# For iscsi-server module
if ($mod eq "iscsi-server") {
	# Find the target
	$conf = &remote_foreign_call($iscsiserver, $mod, "get_iscsi_config");
	$last_remote_error &&
		return "Failed to get config : $last_remote_error";
	$disk->{'iscsi_target'} =~ /^target(\d+)$/ ||
		return "iSCSI target is not in targetN format";
	my $num = $1;
	my ($target) = grep { $_->{'type'} eq 'target' &&
			      $_->{'num'} eq $num } @$conf;
	$target || return "No target named $disk->{'iscsi_target'} found";

	# Find the extent
	$target->{'export'} =~ /^extent(\d+)$/ ||
		return "iSCSI extent is not in extentN format";
	my $num = $1;
	($extent) = grep { $_->{'type'} eq 'extent' &&
			   $_->{'num'} eq $num } @$conf;
	$extent || return "No extent named $target->{'export'} found";
	$real = $extent->{'device'};
	}
elsif ($mod eq "iscsi-target") {
	# Find the target
	my $pconf = &remote_foreign_call($iscsiserver, $mod,
					 "get_iscsi_config_parent");
	$last_remote_error &&
		return "Failed to get config : $last_remote_error";
	my $conf = $pconf->{'members'};
	my $targetname = $disk->{'iscsi_name'}.":".$disk->{'iscsi_target'};
	my ($target) = grep { $_->{'name'} eq 'Target' &&
			      $_->{'value'} eq $targetname } @$conf;
	$target || return "No target named $targetname found";
	my ($lun) = grep { $_->{'name'} eq 'Lun' } @{$target->{'members'}};
	if ($lun && $lun->{'value'} =~ /Path=([^,]+)/) {
		$real = $1;
		}
	}
else {
	return "Unknown module $mod";
	}

# Disconnect from the host system
&remote_foreign_require($vhost, "iscsi-client");
$last_remote_error && return "Error loading iscsi-client : $last_remote_error";
my $conn = { 'name' => $disk->{'iscsi_name'},
	     'target' => $disk->{'iscsi_target'},
	     'ip' => $disk->{'iscsi_ip'},
	     'port' => $disk->{'iscsi_port'} };
if ($disk->{'iscsi_connect'}) {
	my $err = &remote_foreign_call($vhost, "iscsi-client",
				       "delete_iscsi_connection", $conn);
	$err ||= $last_remote_error;
	$err && return "Failed to disconnect iSCSI connection : $err";
	}

# Resize the LV or file
my $resizeerr;
if ($real =~ /^\/dev\/([^\/]+)\/([^\/]+)$/) {
	# Expand or reduce the LV size
	my ($out, $ex, $err);
	my $wantsize = int($disk->{'size'}/1024);
	if ($mod eq "iscsi-server") {
		# For netbsd iscsi server overhead
		$wantsize += 1024;
		}
	if ($disk->{'size'} > $olddisk->{'size'}) {
		($out, $ex, $err) = &execute_command_on_server($iscsiserver,
			"lvextend -L".$wantsize."k ".
			quotemeta($real));
		}
	elsif ($disk->{'size'} < $olddisk->{'size'}) {
		($out, $ex, $err) = &execute_command_on_server($iscsiserver,
			"lvreduce -f -L".$wantsize."k ".
			quotemeta($real));
		}
	$resizeerr = $err ? $err : $ex ? $out : undef;
	}
elsif ($real !~ /^\/dev\//) {
	# Append to or truncate the regular file
	if ($disk->{'size'} > $olddisk->{'size'}) {
		# Expand by appending null bytes
		($out, $ex, $err) = &execute_command_on_server($iscsiserver,
			&dd_command("/dev/zero", undef,
				    $disk->{'size'}-$olddisk->{'size'}).
			" >>".quotemeta($real));
		}
	elsif ($disk->{'size'} < $olddisk->{'size'}) {
		# Truncate by copying the first part into a separate file
		($out, $ex, $err) = &execute_command_on_server($iscsiserver,
			&dd_command($real, $real.".tmp", $disk->{'size'}).
			" && ".
			"mv ".quotemeta($real.".tmp")." ".quotemeta($real));
		}
	$resizeerr = $err ? $err : $ex ? $out : undef;
	}

if (!$resizeerr) {
	# Change the extent size, for the iscsi-server module
	if ($mod eq "iscsi-server") {
		$extent->{'size'} = $disk->{'size'};
		&remote_foreign_call($iscsiserver, $mod, "save_directive",
				     $conf, $extent, $extent);
		$last_remote_error &&
			return "Failed to delete extent : $last_remote_error";
		}

	# Apply iSCSI server configuration
	if ($mod eq "iscsi-server") {
		# Apply the config
		my $err = &remote_foreign_call($iscsiserver, $mod,
					       "restart_iscsi_server");
		$err ||= $last_remote_error;
		return "Failed to apply iSCSI server configuration : $err"
			if ($err);
		}
	elsif ($mod eq "iscsi-target") {
		# Apply the config
		my $err = &remote_foreign_call($iscsiserver, $mod,
					       "restart_iscsi_server");
		$err ||= $last_remote_error;
		return "Failed to apply iSCSI server configuration : $err"
			if ($err);
		}
	}

# Re-connect on the host system
if ($disk->{'iscsi_connect'}) {
	my $err = &remote_foreign_call($vhost, "iscsi-client",
		"create_iscsi_connection", $disk->{'iscsi_ip'}, 3260, undef,
		$conn, "CHAP", $server->{'iscsi_user'},$server->{'iscsi_pass'});
	$disk->{'iscsi_connect'} = 0 if ($err);
	return "iSCSI connection failed : $err" if ($err);
	}

# Wait 10 seconds for disk device to re-appear
my @st;
for(my $i=0; $i<10; $i++) {
	@st = &stat_file_on_server($vhost, $disk->{'real'});
	last if (@st);
	sleep(1);
	}

return $resizeerr;
}

# connect_iscsi_disk(&server, &disk)
# Re-establish the connection from a host system to the iSCSI server for some
# disk
sub connect_iscsi_disk
{
my ($server, $disk) = @_;

# Get the host system
my $vhost = &get_parent_server($server);
$vhost || return "No host system found!";
my $id = $disk->{'iscsi_server'};
$id = $vhost->{$server->{'manager'}.'_iscsi'} if ($id eq '');
$id = $server->{$server->{'manager'}.'_filesystem_iscsi'} if ($id eq '');
$id eq '' && return "Host system $vhost->{'host'} is not configured ".
		    "to use iSCSI";
$last_remote_error = undef;
&remote_foreign_require($vhost, "iscsi-client");
$last_remote_error && return "Error loading iscsi-client : $last_remote_error";

# Make the connection
my $conn = { 'name' => $disk->{'iscsi_name'},
	     'target' => $disk->{'iscsi_target'},
	     'ip' => $disk->{'iscsi_ip'},
	     'port' => $disk->{'iscsi_port'} };
my $err = &remote_foreign_call($vhost, "iscsi-client",
	"create_iscsi_connection", $disk->{'iscsi_ip'}, 3260, undef, $conn,
	"CHAP", $server->{'iscsi_user'}, $server->{'iscsi_pass'});
$err ||= $last_remote_error;
$disk->{'iscsi_connect'} = 1 if (!$err);
return $err;
}

# disconnect_iscsi_disk(&server, &disk)
# Break the connection from a host system to the iSCSI server for some disk
sub disconnect_iscsi_disk
{
my ($server, $disk) = @_;

# Get the host system
my $vhost = &get_parent_server($server);
$vhost || return "No host system found!";
my $id = $disk->{'iscsi_server'};
$id = $vhost->{$server->{'manager'}.'_iscsi'} if ($id eq '');
$id = $server->{$server->{'manager'}.'_filesystem_iscsi'} if ($id eq '');
$id eq '' && return "Host system $vhost->{'host'} is not configured ".
		    "to use iSCSI";
$last_remote_error = undef;
&remote_foreign_require($vhost, "iscsi-client");
$last_remote_error && return "Error loading iscsi-client : $last_remote_error";

# Make the connection
my $conn = { 'name' => $disk->{'iscsi_name'},
	     'target' => $disk->{'iscsi_target'},
	     'ip' => $disk->{'iscsi_ip'},
	     'port' => $disk->{'iscsi_port'} };
my $err = &remote_foreign_call($vhost, "iscsi-client",
			       "delete_iscsi_connection", $conn);
$err ||= $last_remote_error;
$disk->{'iscsi_connect'} = 0 if (!$err);
return $err;
}

# get_iscsi_disk_space(&iscsiserver)
# Returns the free and total disk space on an iSCSI server
sub get_iscsi_disk_space
{
my ($iscsiserver) = @_;
if ($get_iscsi_disk_space_cache{$iscsiserver->{'id'}}) {
	return @{$get_iscsi_disk_space_cache{$iscsiserver->{'id'}}};
	}
my $vg = $iscsiserver->{'iscsi_base_vg'};
my $dir = $iscsiserver->{'iscsi_base_dir'};
my @rv;
if ($vg) {
	# Get size and free space on LVM volume group
	&remote_foreign_require($iscsiserver, "lvm");
	my @vgs = &remote_foreign_call($iscsiserver, "lvm",
				       "list_volume_groups");
	my ($v) = grep { $_->{'name'} eq $vg } @vgs;
	if ($v) {
		my $total = $v->{'pe_total'}*$v->{'pe_size'}*1024;
		my $used = $v->{'pe_alloc'}*$v->{'pe_size'}*1024;
		@rv = ( $total - $used, $total );
		}
	}
elsif ($dir) {
	# Get free space on filesystem containing directory
	my ($out, $ex, $err) = &execute_command_on_server(
		$iscsiserver, "df -k ".quotemeta($dir));
	if (!$ex && !$err && $out =~ /\s(\d+)\s+(\d+)\s+(\d+)/) {
		@rv = ( $3*1024, $1*1024 );
		}
	}
if (@rv) {
	$get_iscsi_disk_space_cache{$iscsiserver->{'id'}} = \@rv;
	}
return @rv;
}

# get_iscsi_disk_info(&iscsiserver, &disk)
# Given a disk object, find the underlying file and return a hash ref with
# information about it (if possible). Otherwise return an error message if 
# something went wrong, or undef if the disk file doesn't exist.
sub get_iscsi_disk_info
{
my ($iscsiserver, $disk) = @_;

my $mod = $iscsiserver->{'iscsi_module'};
$mod || return "System $iscsiserver->{'host'} is no longer an iSCSI server";
$last_remote_error = undef;
&remote_foreign_require($iscsiserver, $mod);
$last_remote_error && return "Error loading $mod : $last_remote_error";

# Find the target, and from it the underlying file
my $real;
if ($mod eq "iscsi-server") {
	# Find the target
	my $conf = &remote_foreign_call($iscsiserver, $mod, "get_iscsi_config");
	$last_remote_error &&
		return "Failed to get config : $last_remote_error";
	$disk->{'iscsi_target'} =~ /^target(\d+)$/ ||
		return "iSCSI target is not in targetN format";
	my $num = $1;
	my ($target) = grep { $_->{'type'} eq 'target' &&
			      $_->{'num'} eq $num } @$conf;
	$target || return "No target named $disk->{'iscsi_target'} found";

	# Find the extent
	$target->{'export'} =~ /^extent(\d+)$/ ||
		return "iSCSI extent is not in extentN format";
	my $num = $1;
	my ($extent) = grep { $_->{'type'} eq 'extent' &&
			      $_->{'num'} eq $num } @$conf;
	$extent || return "No extent named $target->{'export'} found";
	$real = $extent->{'device'};
	}
elsif ($mod eq "iscsi-target") {
	# Find the target
	my $pconf = &remote_foreign_call($iscsiserver, $mod,
					 "get_iscsi_config_parent");
	$last_remote_error &&
		return "Failed to get config : $last_remote_error";
	my $conf = $pconf->{'members'};
	my $targetname = $disk->{'iscsi_name'}.":".$disk->{'iscsi_target'};
	my ($target) = grep { $_->{'name'} eq 'Target' &&
			      $_->{'value'} eq $targetname } @$conf;
	$target || return "No target named $targetname found";
	my ($lun) = grep { $_->{'name'} eq 'Lun' } @{$target->{'members'}};
	if ($lun && $lun->{'value'} =~ /Path=([^,]+)/) {
		$real = $1;
		}
	}
else {
	return "Unknown module $mod";
	}

my $idisk = { 'real' => $real };
if ($real =~ /^\/dev\/([^\/]+)\/([^\/]+)$/) {
	# Get the LV size
	$idisk->{'type'} = 'lvm';
	$idisk->{'vg'} = $1;
	$idisk->{'lv'} = $2;
	&remote_foreign_require($iscsiserver, "lvm");
	$last_remote_error &&
		return "Error loading LVM module : $last_remote_error";
	my @lvs = &remote_foreign_call($iscsiserver, "lvm",
				       "list_logical_volumes", $idisk->{'vg'});
	my ($lv) = grep { $_->{'name'} eq $idisk->{'lv'} } @lvs;
	$lv || return undef;
	$idisk->{'size'} = $lv->{'size'} * 1024;
	if ($mod eq "iscsi-server") {
		# Take away overhead
		$idisk->{'size'} -= (1024*1024);
		}
	}
elsif ($real !~ /^\/dev\//) {
	# Get the file size
	$idisk->{'type'} = 'file';
	my @st = &stat_file_on_server($iscsiserver, $real);
	return undef if (!@st);
	return $st[0] if (@st == 1);
	$idisk->{'size'} = $st[7];
	}
else {
	return "$real is a device, not a file or LV";
	}
return $idisk;
}

# clone_iscsi_disk(&srcserver, &dstserver, &srcdisk, &dstdisk)
# Copy the contents of one iSCSI disk to another. Returns undef on success, or
# an error message on failure.
sub clone_iscsi_disk
{
my ($srcserver, $dstserver, $srcdisk, $dstdisk) = @_;

# Get the iSCSI server
my $srcvhost = &get_parent_server($srcserver);
$srcvhost || return "No host system found for $srcserver->{'host'}!";
my $srcid = $srcdisk->{'iscsi_server'};
$srcid = $vhost->{$server->{'manager'}.'_iscsi'} if ($srcid eq '');
$srcid = $srcserver->{$srcserver->{'manager'}.'_filesystem_iscsi'}
	if ($id eq '');
my $dstvhost = &get_parent_server($dstserver);
$dstvhost || return "No host system found for $dstserver->{'host'}!";
my $dstid = $dstdisk->{'iscsi_server'};
$dstid = $vhost->{$dstserver->{'manager'}.'_iscsi'} if ($dstid eq '');
$dstid = $dstserver->{$dstserver->{'manager'}.'_filesystem_iscsi'}
	if ($id eq '');
$srcid eq $dstid || return "The source and destination systems do not use the ".
			   "same iSCSI server";
my $iscsiserver = &get_managed_server($srcid);
$iscsiserver || return "iSCSI server with ID $srcid does not exist!";

# Get the underlying disks
my $srcinfo = &get_iscsi_disk_info($iscsiserver, $srcdisk);
$srcinfo || return "No iSCSI disk information found for source";
ref($srcinfo) || return "Failed to get iSCSI disk information for ".
			"source : $srcinfo";
my $dstinfo = &get_iscsi_disk_info($iscsiserver, $dstdisk);
$dstinfo || return "No iSCSI disk information found for dest";
ref($dstinfo) || return "Failed to get iSCSI disk information for ".
			"dest : $dstinfo";

# Copy the data
my $err;
if ($srcinfo->{'type'} eq 'file') {
	$err = &transfer_file_between_servers(
		$iscsiserver, $iscsiserver,
		$srcinfo->{'real'}, $dstinfo->{'real'},
		0, 1);
	}
else {
	$err = &transfer_file_between_servers(
		$iscsiserver, $iscsiserver,
		$srcinfo->{'real'}, $dstinfo->{'real'},
		1, 1, 
		int($srcdisk->{'size'}/(1024*1024))*1024*1024);
	}
return $err;
}

1;
