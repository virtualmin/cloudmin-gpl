# Functions for server management by Cloudmin. This library can be pre-loaded.

# Work out where other libraries are, and load them
$server_manager_root = $module_root_directory;
if (!$server_manager_root) {
        foreach my $i (keys %INC) {
                if ($i =~ /^(.*)\/server-manager-lib-funcs.pl$/) {
                        $server_manager_root = $1;
                        }
                }
        }
if (!$server_manager_root) {
        $0 =~ /^(.*)\//;
        $server_manager_root = "$1/server-manager";
        }

foreach my $lib ("images", "newfeatures", "owners", "login", "domainname",
		 "commands", "filesystem", "history", "json", "dns",
		 "bw", "usage", "backups", "locations", "vsync", "alerts",
		 "repl", "scheduled", "dhcp") {
        do "$server_manager_root/$lib-lib.pl";
        if ($@ && -r "$server_manager_root/$lib-lib.pl") {
                print STDERR "failed to load $lib-lib.pl : $@\n";
                }
	}
eval "use Net::Amazon::EC2;";		# Fails if no S3 type
use Time::Local;
use POSIX;
use Socket;
push(@INC, $server_manager_root);

# Load type-specific library functions
@possible_server_management_types = ( "real",
				      "xen",
				      "kvm",
				      "citrix",
				      "vserver",
				      "zones",
				      "openvz",
				      "ec2",
				      "this",
				    );
foreach my $smt (@possible_server_management_types) {
	if (-r $server_manager_root."/".$smt."-type-lib.pl") {
		do $server_manager_root."/".$smt."-type-lib.pl";
		}
	}

# list_managed_servers()
# Returns a list of all servers managed by this module. These are actually
# just a subset of those from the Webmin Servers Index module
sub list_managed_servers
{
my @rv = grep { $_->{'module'} eq $module_name } &servers::list_servers();
@rv = grep { $server_management_types{$_->{'manager'}} } @rv;
@rv = sort { $a->{'host'} cmp $b->{'host'} } @rv;

if ($config{'show_this'}) {
	# Magically add this system to the list
	my $this = &get_this_managed_server();
	splice(@rv, 0, 0, $this);
	}

# Fill in missing details
foreach my $s (@rv) {
	&complete_managed_server($s);
	}

return @rv;
}

# get_managed_server(id)
# Returns the hash ref for one Cloudmin system
sub get_managed_server
{
my ($id) = @_;
my $rv;
if ($id eq '0') {
	$rv = $config{'show_this'} ? &get_this_managed_server() : undef;
	}
else {
	$rv = &servers::get_server($id);
	}
return undef if (!$rv);
&complete_managed_server($rv);
return $rv;
}

# get_this_managed_server()
# Returns a hash ref for this system
sub get_this_managed_server
{
# Magically add this system to the list
my $this = &servers::this_server();
$this->{'manager'} = 'this';
$this->{'host'} = &get_system_hostname();
$this->{'desc'} = $text{'this_this'};
&read_file($this_server_status, $this);
splice(@rv, 0, 0, $this);

# If this system can host Xen and we are in Xen-only mode, allow it to
# be a host, and set some useful defaults for IP allocation
if ($module_info{'onehost'} eq 'xen' &&
    $server_management_types{'xen'} &&
    ($config{'xen_checked'} || !&check_xen_host_software($this))) {
	$this->{'xen_host'} = 1;
	my $eth0 = &first_ethernet_iface();
	($this->{'xen_start'}, $this->{'xen_end'}) = &first_ethernet_range();
	$this->{'xen_cidr'} = &net::mask_to_prefix($eth0->{'netmask'});
	$this->{'xen_dir'} = "/xen";
	$this->{'xen_zone'} = $config{'xen_zone'};

	# Save flag indicating that we have already checked out Xen
	# on this machine, as doing so can be slow
	$config{'xen_checked'} = 1;
	&save_module_config();
	}
return $this;
}

# get_managed_server_by(key, value)
# Returns a list of servers which have a field matching some search key
sub get_managed_server_by
{
my ($key, $value) = @_;
my @rv;
if ($key eq "id") {
	my $s = &get_managed_server($value);
	push(@rv, $s) if ($s);
	}
else {
	@rv = grep { $_->{$key} eq $value } &list_managed_servers();
	}
return wantarray ? @rv : $rv[0];
}

# list_managed_server_files(&server)
# Returns a list of files associated with some server
sub list_managed_server_files
{
my ($server) = @_;
my @rv = ( $server->{'file'},
	   $server_collected_dir.'/'.$server->{'id'},
	   $server_domains_dir.'/'.$server->{'id'},
	   $usage_data_dir.'/'.$server->{'id'},
	   glob($historic_info_dir.'/'.$server->{'id'}.'/*'),
	 );
return grep { -r $_ } @rv;
}

# complete_managed_server(&server)
# Fill in missing details for some virtual system
sub complete_managed_server
{
my ($s) = @_;

# Assume EC2 security group is default
if ($s->{'manager'} eq 'ec2' && !$s->{'ec2_sgroup'}) {
	$s->{'ec2_sgroup'} = $ec2_security_group;
	}

# Set short hostname
my $shost = $s->{'host'};
if ($config{'name_max'} && length($shost) > $config{'name_max'}+3) {
	if ($config{'name_mode'}) {
		# Cut off chars at end, replace with ..
		$shost = substr($shost, 0, $config{'name_max'})."...";
		}
	else {
		# Show first and last max/2 chars, with ... between
		my $h = int($config{'name_max'} / 2);
		$shost = substr($shost, 0, $h)."...".substr($shost, -$h);
		}
	}
$s->{'short_host'} = $shost;

# Fill in creation time with module install time if missing
if (!$s->{'created'}) {
	if ($s->{'id'} =~ /^(\d{10})/) {
		$s->{'created'} = $1;
		}
	else {
		# Assume created at module install time
		my %itimes;
		&read_file($install_times_file, \%itimes);
		my @vers = sort { $a <=> $b } (keys %itimes);
		if (@vers) {
			$s->{'created'} = $itimes{$vers[0]};
			}
		}
	}

# For a Xen host with no gateways set, assume first IP range uses old
# single default gateway
if ($s->{'xen_host'} && !$s->{'xen_gws'} && $s->{'xen_gw'}) {
	$s->{'xen_gws'} = $s->{'xen_gw'} || '*';
	delete($s->{'xen_gw'});
	}

# For a Xen host with a MAC address, copy it to the mac field
if ($s->{'xen_mac'}) {
	$s->{'mac'} = $s->{'xen_mac'};
	}

# Fill in 'ip' convenience field
my $ip = &get_server_ip($s);
$ip ||= &to_ipaddress($s->{'host'});
$ip ||= $s->{'host'};
$s->{'ip'} = $ip;
}

# list_managed_servers_sorted([force-mode])
# Returns servers list, with sorting and possibly 'indent' fields
sub list_managed_servers_sorted
{
my ($mode) = @_;
my @rv = &list_managed_servers();
foreach my $s (@rv) {
	$s->{'indent'} = 0;
	}
if (!defined($mode)) {
	$mode = $config{'sort_mode'};
	}
if ($mode == 0) {
	# By hostname
	@rv = sort { $a->{'host'} cmp $b->{'host'} } @rv;
	}
elsif ($mode == 1) {
	# Under host systems
	my @newrv;
	@rv = sort { $a->{'host'} cmp $b->{'host'} } @rv;
	foreach my $s (grep { $_->{'manager'} eq 'this' ||
			      $_->{'manager'} eq 'real' ||
			      $_->{'manager'} eq 'ec2' } @rv) {
		push(@newrv, $s);
		foreach my $cs (&list_child_servers($s, \@rv)) {
			$cs->{'indent'} = 1;
			$cs->{'indent_host'} = $s->{'id'};
			push(@newrv, $cs);
			}
		}
	@rv = @newrv;
	}
elsif ($mode == 2) {
	# By description
	@rv = sort { lc($a->{'desc'}) cmp lc($b->{'desc'}) } @rv;
	}
return @rv;
}

# list_available_managed_servers_sorted()
# Returns a sorted list of servers this user can see. Remove indents if the
# user can't see the host system.
sub list_available_managed_servers_sorted
{
my @rv = grep { &can_action($_) } &list_managed_servers_sorted();
my %got = map { $_->{'id'}, $_ } @rv;
foreach my $s (@rv) {
	if ($s->{'indent_host'} && !$got{$s->{'indent_host'}}) {
		$s->{'indent'} = 0;
		}
	}
return @rv;
}

# list_available_managed_servers()
# Returns a list of servers this user can see
sub list_available_managed_servers
{
return grep { &can_action($_) } &list_managed_servers();
}

# Returns a unique ID for a new Cloudmin server
sub server_id
{
return time().$$.($main::server_id_count++);
}

# get_server_ip(&server)
# Returns the IP address (or addresses in an array context) for a system
sub get_server_ip
{
my ($server) = @_;
my $resolvedip = &to_ipaddress($server->{'host'});
my @ips;
if ($server->{'manager'} ne 'this' &&
    $server->{'manager'} ne 'real') {
	# Use IPs from interfaces for non-virtual systems
	@ips = split(/\s+/, $server->{'ip_addresses'});
	}
if (!@ips) {
	@ips = ( $resolvedip );
	}
if (&indexof($resolvedip, @ips) >= 0 && scalar(@ips) > 1) {
	# Always use IP that hostname resolves to first
	@ips = ( $resolvedip, ( grep { $_ ne $resolvedip } @ips ) );
	}
return wantarray ? @ips : $ips[0];
}

# first_ethernet_iface()
# Returns the object for the first active ethernet interface
sub first_ethernet_iface
{
foreach my $a (&net::active_interfaces()) {
	if ($a->{'up'} && $a->{'virtual'} eq '' &&
	    (&net::iface_type($a->{'name'}) =~ /ethernet/i ||
	     $a->{'name'} =~ /^bond/)) {
		return $a;
		}
	}
return undef;
}

# first_ethernet_range()
# Returns the starting and ending IPs for the network that the first
# ethernet interface is on
sub first_ethernet_range
{
my $eth0 = &first_ethernet_iface();
if (!$eth0) {
	# Fake it
	$eth0 = { 'address' => &to_ipaddress(&get_system_hostname()) ||
			       '127.0.0.1',
		  'netmask' => '255.255.255.0' };
	}
my $ipnum = &net::ip_to_integer($eth0->{'address'});
my $netnum = &net::ip_to_integer($eth0->{'netmask'});
my $netstart = ($ipnum & $netnum) + 1;
my $netsize = ~$netnum;
my $netend = ($ipnum & $netnum) + $netsize - 1;
return ( &net::integer_to_ip($netstart),
	 &net::integer_to_ip($netend) );
}

# save_managed_server(&server)
# Create or update a managed server object. It will be added to both this
# module and Webmin Servers Index
sub save_managed_server
{
my ($server) = @_;
if ($server->{'id'} eq '0') {
	# Special case - saving info about this system
	my %this = ( 'status' => $server->{'status'},
			'statustime' => $server->{'statustime'},
			'status_msg' => $server->{'status_msg'},
			'group' => $server->{'group'},
			'virtualmin_checked' => $server->{'virtualmin_checked'},
			'virtualmin_err' => $server->{'virtualmin_err'},
			'virtualmin_poss' => $server->{'virtualmin_poss'},
			'virtualmin_domains' => $server->{'virtualmin_domains'},
			'virtualmin_serial' => $server->{'virtualmin_serial'},
			'virtualmin_key' => $server->{'virtualmin_key'},
			'backup_default' => $server->{'backup_default'},
			'all_poss' => $server->{'all_poss'},
			'location' => $server->{'location'},
		      );
	# Save all Cloudmin type-specific details
	foreach my $t (@server_management_types, 'zone') {
		foreach my $k (keys %$server) {
			if ($k =~ /^\Q$t\E_/) {
				$this{$k} = $server->{$k};
				}
			}
		}
	&write_file($this_server_status, \%this);
	}
else {
	my $newserver;
	if (!$server->{'id'}) {
		my ($same) = grep { $_->{'host'} eq $server->{'host'} }
				     &servers::list_servers();
		$server->{'id'} = $same ? $same->{'id'} : time();
		$newserver = 1;
		}
	$server->{'module'} = $module_name;
	my $changed = 1;
	if (!$newserver) {
		# Check if actually changed, don't write out to disk if not.
		# This prevents un-necessary replication.
		my $oldserver = &servers::get_server($server->{'id'});
		my @diffs = grep { $_ ne 'statustime' }
				&hash_ref_differences($server, $oldserver);
		$changed = scalar(@diffs);
		}
	if ($changed) {
		&servers::save_server($server);
		}
	}
}

# delete_managed_server(&server, [keep-info])
# Remove a managed server object
sub delete_managed_server
{
my ($server, $keep) = @_;
&clear_ssh_host_key($server);
&delete_console_user($server);
if ($server->{'id'}) {
	&servers::delete_server($server->{'id'});
	}
if (!$keep) {
	&unlink_file("$server_domains_dir/$server->{'id'}");
	&unlink_file("$server_collected_dir/$server->{'id'}");
	&unlink_file("$shell_previous_dir/$server->{'id'}");
	&unlink_file("$historic_info_dir/$server->{'id'}");
	if (defined(&delete_bandwidth)) {
		&delete_bandwidth($server);
		}
	if (defined($usage_data_dir)) {
		&unlink_file("$usage_data_dir/$server->{'id'}");
		}
	}

if (defined(&list_system_owners)) {
	# Remove from any owners
	foreach my $o (&list_system_owners()) {
		my @os = split(/\s+/, $o->{'acl'}->{'servers'});
		my @newos = grep { $_ ne $server->{'id'} } @os;
		if (scalar(@os) != scalar(@newos)) {
			$o->{'acl'}->{'servers'} = join(' ', @newos);
			&save_system_owner($o, $o);
			}
		}
	}

# Remove from any domain syncs
foreach my $vsync (&list_virtualmin_syncs()) {
	if ($vsync->{'src'} eq $server->{'id'}) {
		&delete_virtualmin_sync($vsync);
		}
	}

# Delete any scheduled changes for this system
foreach my $sched (&list_scheduled_changes()) {
	if ($sched->{'server'} eq $server->{'id'}) {
		&save_scheduled_change($server, $sched->{'type'},
				       $sched->{'id'}, undef);
		}
	}
}

# find_managed_servers(all, &hostnames, &groupnames, &managers, &types, &owners)
# Finds all servers matching some selection criteria. In 'all' mode, only
# servers the user is allowed to access are returned.
sub find_managed_servers
{
my ($all, $hosts, $groups, $managers, $types, $owners) = @_;
my @rv;
my %wantgroups = map { lc($_), 1 } @$groups;
my %wantowned;
foreach my $oname (@$owners) {
	my $o = &get_system_owner($oname);
	if ($o) {
		foreach my $sid (split(/\s+/, $o->{'acl'}->{'servers'})) {
			$wantowned{$sid}++;
			}
		}
	}
foreach my $s (&list_managed_servers()) {
	my ($ingroup) = grep { $wantgroup{lc($_)} }
				split(/\t/, $s->{'group'});
	if (($all && &can_action($s)) ||
	    $ingroup ||
	    &indexoflc($s->{'host'}, @$hosts) >= 0 ||
	    &indexoflc($s->{'manager'}, @$managers) >= 0 ||
	    &indexoflc($s->{'type'}, @$types) >= 0 ||
	    $wantowned{$s->{'id'}}) {
		push(@rv, $s);
		}
	}
return @rv;
}

# describe_os(os)
# Converts an OS code as used by the 'servers' module into a name
sub describe_os
{
my ($t) = @_;
my ($type) = grep { $_->[0] eq $t } @servers::server_types;
return $type->[1];
}

# describe_status(&server, [withcolor], [withdomains])
# Returns a string describing the status of some server (down, nossh,
# nologin, nowebmin, nowebminlogin, novirt, virt)
sub describe_status
{
my ($s, $withcol, $withdoms) = @_;
my %cmap = map { $_->[0], $_->[1] } @server_statuses;
my $msg = $text{'status_'.$s->{'status'}} || $text{'status_unknown'};
if ($s->{'status'} eq 'virt' && $withdoms && $s->{'virtualmin_domains'}) {
	if ($withdoms == 1) {
		$msg .= " (".&text('status_doms',
				   $s->{'virtualmin_domains'}).")";
		}
	elsif ($withdoms == 2) {
		$msg .= " ($s->{'virtualmin_domains'})";
		}
	}
if ($withcol) {
	my $col = $cmap{$s->{'status'}};
	if ($col) {
		$msg = "<font color=#$col>$msg</font>";
		}
	}
if ($s->{'status'} eq 'virt' && $s->{'virtualmin_error'}) {
	# Add config errors warning
	if ($withcol) {
		$msg .= " - <font color=#ff0000>$text{'status_errs'}</font>";
		}
	else {
		$msg .= " - $text{'status_errs'}";
		}
	}
return $msg;
}

# describe_disk(&disk)
# Returns a human-readable string describing the real location of a disk
sub describe_disk
{
my ($d) = @_;
if ($d->{'storage'}) {
	# Citrix storage
	return &text('disks_storage', "<i>$d->{'storage'}</i>",
				      "<tt>$d->{'real'}</tt>");
	}
elsif ($d->{'device'} && defined(&mount::device_name)) {
	# Real or LVM device
	return &mount::device_name($d->{'real'});
	}
else {
	# Regular file
	return "<tt>$d->{'real'}</tt>";
	}
}

# can_ssh_status(&server)
# Return 1 if Cloudmin can run commands on a system via SSH
sub can_ssh_status
{
my ($server) = @_;
return $server->{'status'} eq 'virt' || $server->{'status'} eq 'novirt' ||
       $server->{'status'} eq 'nowebmin' ||
       $server->{'status'} eq 'nowebminlogin' ||
       $server->{'status'} eq 'downwebmin';
}

# can_webmin_status(&server)
# Return 1 if Cloudmin can use Webmin on a system
sub can_webmin_status
{
my ($server) = @_;
return $server->{'status'} eq 'virt' || $server->{'status'} eq 'novirt';
}

# list_ssh_keys()
# Returns a list of SSH keys used to login to servers
sub list_ssh_keys
{
my @rv;
opendir(DIR, $ssh_keys_dir);
foreach my $f (readdir(DIR)) {
	next if ($f !~ /^(\S+)\.info$/i);
	my %key;
	&read_file("$ssh_keys_dir/$f", \%key);
	$key{'keydata'} = &read_file_contents($key{'file'});
	push(@rv, \%key);
	}
closedir(DIR);
return @rv;
}

# save_ssh_key(&key)
# Creates or updates an SSH key
sub save_ssh_key
{
my ($key) = @_;
if (!-d $ssh_keys_dir) {
	&make_dir($ssh_keys_dir, 0700);
	}
if (!$key->{'id'}) {
	# New, need to choose an ID
	$key->{'id'} = time();
	if (!$key->{'file'}) {
		# No file specified .. so this is a generated key
		$key->{'file'} = "$ssh_keys_dir/$key->{'id'}.key";
		$key->{'external'} = 0;
		}
	else {
		# Key is in existing file
		$key->{'external'} = 1;
		}
	}
my %nodata = %$key;
delete($nodata{'keydata'});
&lock_file("$ssh_keys_dir/$key->{'id'}.info");
&write_file("$ssh_keys_dir/$key->{'id'}.info", \%nodata);
&unlock_file("$ssh_keys_dir/$key->{'id'}.info");
if (!$key->{'external'}) {
	&open_lock_tempfile(DATA, ">$key->{'file'}");
	&print_tempfile(DATA, $key->{'keydata'});
	&close_tempfile(DATA);
	&set_ownership_permissions(undef, undef, 0600, $key->{'file'});
	}
}

# delete_ssh_key(&key)
# Removes a known SSH key
sub delete_ssh_key
{
my ($key) = @_;
&unlink_logged("$ssh_keys_dir/$key->{'id'}.info");
if (!$key->{'external'}) {
	&unlink_logged($key->{'file'});
	}
}

# generate_public_key(&key)
# Returns the public key string for some key
sub generate_public_key
{
my ($key) = @_;
if ($key->{'public'}) {
	# Already public, can just return text (minus trailing whitespace)
	my $rv = $key->{'keydata'};
	$rv =~ s/\s+$//;
	return $rv;
	}
my $qp = quotemeta($key->{'file'});
my $out = &backquote_command("ssh-keygen -y -f $qp 2>/dev/null");
if ($out =~ /((\d+)\s+(\d+)\s+(\d+))$/) {
	# Version 1
	return $1;
	}
elsif ($out =~ /((\S+)\s+([A-Za-z0-9\/=\+]+))$/) {
	# Version 2
	return $1;
	}
else {
	return undef;
	}
}

# check_ssh_key_data(text)
# Returns 1 if the text looks like an SSH 1 key, 2 for an SSH version 2 key,
# 0 otherwise
sub check_ssh_key_data
{
my ($text) = @_;
if ($text =~ /-----BEGIN\s+(RSA|DSA)\s+PRIVATE\s+KEY-----\n([A-Za-z0-9\+\/=\n]+)-----END\s+(\S+)\s+PRIVATE\s+KEY-----/ && $1 eq $3) {
	return 2;
	}
elsif ($text =~ /^SSH\s+PRIVATE\s+KEY\s+FILE/) {
	return 1;
	}
else {
	return 0;
	}
}

# check_ssh_public_key_data(text)
# Returns 1 if the text looks like an SSH 1 key, 2 for an SSH version 2 key,
# 0 otherwise
sub check_ssh_public_key_data
{
my ($text) = @_;
my @lines = split(/\r?\n/, $text);
#return 0 if (@lines != 1);
if ($text =~ /^(ssh-rsa|ssh-dss)\s+(\S+)\s+(\S+)\r?\n/) {
	return 2;
	}
elsif ($text =~ /^(\d+)\s+(\d+)\s+(\d+)\s+(\S+)\r?\n/) {
	return 1;
	}
return 0;
}

# generate_ssh_key()
# Create a new SSH private key, in the default format
sub generate_ssh_key
{
my $temp = &transname();
my $out = &backquote_command("ssh-keygen -f $temp -N '' 2>&1");
if ($? || !-r $temp) {
	&error("<tt>$out</tt>");
	}
my $data = &read_file_contents($temp);
unlink($temp, $temp.".pub");
return $data;
}

# wrap_long_line(text, cols)
# If any lines in text are longer than cols, wrap them onto the next line.
# Returns the resulting wrapped text as a single string.
sub wrap_long_line
{
my ($text, $cols) = @_;
my @lines = split(/\r?\n/, $text);
my @rv;
foreach my $text (@lines) {
	while($text) {
		my $l = substr($text, 0, $cols);
		$text = substr($text, $cols);
		push(@rv, $l);
		}
	}
return join("\n", @rv)."\n";
}

# ssh_key_menu(name, [for-type], [value])
# Returns a menu for selecting an SSH key
sub ssh_key_menu
{
my ($name, $type, $value) = @_;
my @keys = sort { $a->{'desc'} cmp $b->{'desc'} }
		grep { !$_->{'public'} } &list_ssh_keys();
my @allkeys = @keys;
if ($type) {
	# Limit to keys suitable for this server type
	my $kfunc = "type_${type}_ssh_key_grep";
	if (defined(&$kfunc)) {
		@keys = grep { &$kfunc($_) } @keys;
		}
	}
if (@keys) {
	return &ui_select($name, $value,
		[ map { [ $_->{'id'}, $_->{'desc'} ] } @keys ]);
	}
else {
	my $msg = @keys == @allkeys ? $text{'add_nokeys'}
				       : $text{'add_nokeys2'};
	return &ui_select($name, undef,
		[ [ undef, $text{'add_nokeys'} ] ]);
	}
}

sub cleanup_key_data
{
my ($text) = @_;
$text =~ s/\r//g;
$text =~ s/^\s*//g;
$text =~ s/\s*$/\n/g;
return $text;
}

# check_server_ssh_login(&server)
# Checks if some system can be contacted via SSH, with the login details
# set in the server object. Returns a status code (0=OK, 1=No connect, 2=No
# login, 3=Unknown error, 4=Timeout, 5=Host down, 6=Virtual system down,
# 7=user is not root, 8=Paused) and an error message, the Webmin root directory
# (if installed), the Webmin port, the Webmin SSL flag, and the actual hostname.
sub check_server_ssh_login
{
my ($server) = @_;

# Check if the server type has its own login check function, and if so
# call it
my $sfunc = "type_".$server->{'manager'}."_check_login";
if (defined(&$sfunc)) {
	# Type has defined it's own function for checking the status
	my @rv = &$sfunc($server);
	return @rv if (scalar(@rv));
	}

# Need to really SSH
my $cmd = &build_ssh_command($server, 1);
my $timeout = int($config{'ssh_timeout'}) || 30;
$cmd .= " 'grep ^root= /etc/webmin/miniserv.conf ; grep ^port= /etc/webmin/miniserv.conf ; grep ^ssl= /etc/webmin/miniserv.conf ; id -a ; echo OK ; hostname'";
my ($status, $out) = &run_ssh_command($cmd, $server->{'ssh_pass'}, $timeout);
if ($status == 0) {
	# Connected OK .. check the output to see if we have Webmin
	if ($out !~ /OK/) {
		# Could not run commands
		return (3, $out, undef);
		}
	elsif ($out =~ /uid=(\d+)/ && $1 != 0) {
		# Not root!
		return (7, $out, undef);
		}
	else {
		# Check Webmin location
		my $root = $out =~ /root=(\S+)/ ? $1 : 0;
		my $port = $out =~ /port=(\S+)/ ? $1 : 0;
		my $ssl = $out =~ /ssl=(\S+)/ ? $1 : 0;
		if ($root && $ssl) {
			# Webmin wants SSL .. but can we really provide it?
			if (!$server->{'has_net_ssleay'}) {
				my $pp = &get_file_data_from_server($server,
						"/etc/webmin/perl-path");
				chop($pp);
				$pp ||= "perl";
				my ($sout, $sex) =
				    &execute_command_on_server(
					$server, "$pp -e 'use Net::SSLeay'");
				if ($sex) {
					$ssl = 0;	# Missing Perl module
					}
				else {
					# Cache this, as once it is installed
					# it is unlikely to disappear
					$server->{'has_net_ssleay'} = 1;
					}
				}
			}
		my $hostname;
		if ($out =~ /OK\r?\n(\S+)\r?\n/) {
			# Parse out hostname
			$hostname = $1;
			}
		return (0, $out, $root, $port, $ssl, $hostname);
		}
	}
else {
	return ($status, $out, undef);
	}
}

# check_server_webmin_login(&server)
# Checks if Webmin is running on some system, and can be contacted via RPC
# with the login details given. Returns a status code (0=OK, 1=No connect, 2=No
# login, 3=Other error, 4=Timeout), an error message, and the remote OS code
# and real OS type
sub check_server_webmin_login
{
my ($server) = @_;
my $fast_try = 0;
if (!defined($server->{'fast'})) {
	# Try fast mode first
	$fast_try = 1;
	$server->{'fast'} = 1;
	}
my $rfc;
eval {
	local $SIG{'ALRM'} = sub { die "timeout\n" };
	local $main::error_must_die = 1;
	alarm(20);
	$last_remote_error = undef;
	$rfc = &remote_foreign_config($server, "");
	alarm(0);
	};
if ($last_remote_error) {
	my $ec = $last_remote_error =~ /Login\s+to\s+RPC/ ? 2 : 1;
	return ($ec, $last_remote_error);
	}
if ($@) {
	if ($@ =~ /timeout|Connection refused/i) {
		# A fast mode failure will look like a timeout or connection
		# refused .. try in slow mode, if we don't know yet
		if ($fast_try) {
			$server->{'fast'} = 0;
			return &check_server_webmin_login($server);
			}
		return (4, "Webmin failed to complete in 20 seconds");
		}
	else {
		return (3, $@);
		}
	}
return (0, undef, $rfc->{'os_type'}, $rfc->{'real_os_type'});
}

# run_ssh_command(command, password, timeout, [leave-open])
# Attempts to run some ssh or scp command, giving it a password if needed.
# Returns 0 on success, 1 if the connection fails, 2 if the password is wrong,
# or 3 for some other error, 4 for timeout, and the output.
# If the leave-open parameter is given, the loop stops when that message is
# read, and the still-open file descriptor is returned
sub run_ssh_command
{
my ($cmd, $pass, $timeout, $leave) = @_;
my ($wrong_password, $got_login, $connect_failed, $given_password,
    $hostkey_failed);
my $out;
my $ex;
my ($fh, $fpid);
eval {
	local $SIG{'ALRM'} = sub { die "timeout\n" };
	local $main::error_must_die = 1;
	if ($timeout) {
		alarm($timeout);
		}
	($fh, $fpid) = &proc::pty_process_exec($cmd);
	while(1) {
		my $rv = &wait_for($fh, "password:", "yes\\/no", "(^|\\n)\\s*Permission denied.*\n", "ssh: connect.*\n", "REMOTE HOST IDENTIFICATION", ".*\n", $leave ? ( $leave ) : ( ));
		if ($rv == 0) {
			syswrite($fh, "$pass\n");
			$given_password++;
			}
		elsif ($rv == 1) {
			syswrite($fh, "yes\n");
			}
		elsif ($rv == 2) {
			$wrong_password++;
			$out .= $wait_for_input;
			last;
			}
		elsif ($rv == 3) {
			$connect_failed++;
			$out .= $wait_for_input;
			}
		elsif ($rv == 4) {
			$hostkey_failed++;
			$out .= $wait_for_input;
			}
		elsif ($rv == 6) {
			# Hit leave-open message
			last;
			}
		elsif ($rv < 0) {
			last;
			}
		else {
			$out .= $wait_for_input;
			}
		}
	alarm(0);
	if (!$leave) {
		close($fh);
		waitpid($fpid, 0);
		$ex = $?;
		}
	};
&additional_log('exec', undef, $cmd);
if ($@) {
	if ($@ =~ /timeout/) {
		return (4, "SSH failed to complete in $timeout seconds");
		}
	else {
		return (3, $@);
		}
	}
$out =~ s/^\s*\r?\n//;	# Remove empty line at start
if ($wrong_password || $given_password >= 3) {
	return (2, $out);
	}
if ($hostkey_failed) {
	if ($out =~ /Offending\s+key\s+in\s+(\S+):(\d+)/) {
		return (1, "Invalid host key in $1 at line $2");
		}
	else {
		return (1, "Invalid host key");
		}
	}
if ($connect_failed) {
	return (1, $out);
	}
if ($ex) {
	return (3, $out);
	}
return (0, $out, $fh, $fpid);
}

# execute_command_on_server(&server, command, [timeout], [leave-open])
# Runs some command on a managed system (most likely via SSH), and returns
# the output, exit status and error message if it could not be run.
# If the leave-open parameter is set, the command is left running and a file
# handle for talking to it is returned.
sub execute_command_on_server
{
my ($server, $cmd, $timeout, $leave) = @_;
my $efunc = "type_".$server->{'manager'}."_execute_command";
if (defined(&$efunc)) {
	# Use type-specific function call
	return &$efunc(@_);
	}
elsif ($server->{'ssh_nologin'}) {
	# Cannot run commands
	return (undef, undef, "SSH logins are not available");
	}
else {
	# Just run via SSH
	my $sshcmd = &build_ssh_command($server);
	if ($leave) {
		$sshcmd .= " -t";	# Force allocation of pty
		$cmd = "echo SERVER_MANAGER_LOGIN_DONE ; $cmd";
		}
	$sshcmd .= " ".quotemeta($cmd);
	my ($status, $out, $fh, $fpid) =
	    &run_ssh_command($sshcmd, $server->{'ssh_pass'}, $timeout,
			     $leave ? "SERVER_MANAGER_LOGIN_DONE" : undef);
	if ($status == 0) {
		return ($out, 0, undef, $status, $fh, $fpid);
		}
	elsif ($status == 3) {
		return ($out || "Connection failed\n", 1, undef, $status);
		}
	else {
		return ($out, undef, $text{'status_'.$status}, $status);
		}
	}
}

# get_file_from_server(&server, remotefile, localfile, device-file, force-ssh)
# Transfers a file from the given server to this system. May use scp or some
# type-specific method
sub get_file_from_server
{
my ($server, $remotefile, $localfile, $device, $forcessh) = @_;
my $gfunc = "type_".$server->{'manager'}."_get_file";
if (defined(&$gfunc) && !$forcessh) {
	# Use type-specific function call
	my $rv = &$gfunc(@_);
	return $rv if ($rv ne 'FALLBACK');	# Type-specific function has
						# asked to fallback to scp
	}
if ($server->{'ssh_nologin'}) {
	return "SSH logins are not available";
	}

if ($device) {
	# Run dd on the server and capture output
	my $sshcmd = &build_ssh_command($server);
	$sshcmd .= " dd if=".quotemeta($remotefile)." bs=32768 |".
		   " dd of=".quotemeta($localfile)." bs=32768";
	my ($status, $out) =
		&run_ssh_command($sshcmd, $server->{'ssh_pass'});
	return $status ? $out : undef;
	}
else {
	# Just scp down
	my $sshcmd = "scp -r -p";
	$sshcmd .= " -o Protocol=".$server->{'ssh_protocol'};
	if ($server->{'key'}) {
		my ($key) = grep { $_->{'id'} == $server->{'key'} }
				    &list_ssh_keys();
		$sshcmd .= " -i ".quotemeta($key->{'file'});
		}
	if ($server->{'ssh_port'}) {
		$sshcmd .= " -P ".$server->{'ssh_port'};
		}
	$sshcmd .= " $server->{'ssh_user'}\@$server->{'ip'}:".
		   quotemeta($remotefile)." ".quotemeta($localfile);
	my ($status, $out) =
		&run_ssh_command($sshcmd, $server->{'ssh_pass'});
	return $status ? $out : undef;
	}
}

# mount_filesystem_if_needed(&server)
# Mount a virtual system's filesystem if needed to access files
sub mount_filesystem_if_needed
{
my ($server) = @_;
if ($mounted_filesystem{$server->{'id'}}) {
	# Already mounted, so just up the count
	$mounted_filesystem{$server->{'id'}}++;
	}
else {
	# Mount if needed
	my $nfunc = "type_".$server->{'manager'}."_need_mount";
	if (defined(&$nfunc) && &$nfunc($server)) {
		my $mfunc = "type_".$server->{'manager'}."_mount_filesystem";
		my $err = &$mfunc($server);
		return $err if ($err);
		$mounted_filesystem{$server->{'id'}}++;
		}
	}
return undef;
}

# umount_filesystem_if_needed(&server)
# If a filesystem was mounted, un-mount it now
sub umount_filesystem_if_needed
{
my ($server) = @_; 
$mounted_filesystem{$server->{'id'}}--;
if ($mounted_filesystem{$server->{'id'}} == 0) {
	my $ufunc = "type_".$server->{'manager'}."_umount_filesystem";
	return &$ufunc($server);
	}
return undef;
}

# build_ssh_command(&server, [no-quiet], [extra-ssh-args])
# Returns the base of an SSH comand for logging into some system
sub build_ssh_command
{
my ($server, $loud, $extra) = @_;
my $sshcmd = "ssh".($loud ? "" : " -q")." -x -".$server->{'ssh_protocol'};
if ($server->{'key'}) {
	my ($key) = grep { $_->{'id'} == $server->{'key'} }
			    &list_ssh_keys();
	$sshcmd .= " -i ".quotemeta($key->{'file'});
	}
if ($server->{'ssh_port'}) {
	$sshcmd .= " -p ".$server->{'ssh_port'};
	}
$sshcmd .= " ".$extra if ($extra);
$sshcmd .= " $server->{'ssh_user'}\@$server->{'ip'}";
return $sshcmd;
}

# clear_ssh_host_key(&server)
# Remove the key for some system from .ssh/known_hosts on the Cloudmin master
sub clear_ssh_host_key
{
my ($server) = @_;
my $ip = &get_server_ip($server);
my @uinfo = getpwnam("root");
foreach my $f ("$uinfo[7]/.ssh/known_hosts",
	       "$uinfo[7]/.ssh/known_hosts2",
	       "$ENV{'HOME'}/.ssh/known_hosts",
	       "$ENV{'HOME'}/.ssh/known_hosts2") {
	next if (!-r $f);
	&lock_file($f);
	my $lref = &read_file_lines($f);
	for(my $i=0; $i<@$lref; $i++) {
		my @w = split(/\s+/, $lref->[$i]);
		my @h = split(/,/, $w[0]);
		if (&indexof($server->{'host'}, @h) >= 0 ||
		    &indexof($ip, @h) >= 0 ||
		    &indexof($server->{'ip'}, @h) >= 0) {
			splice(@$lref, $i--, 1);
			}
		}
	&flush_file_lines($f);
	&unlock_file($f);
	}
return undef;
}

# clear_remote_ssh_host_key(&server, &source-server)
# Remove the key for some system from .ssh/known_hosts on some other system
sub clear_remote_ssh_host_key
{
my ($server, $srcserver) = @_;
if ($srcserver->{'id'} eq '0') {
	return &clear_ssh_host_key($server);
	}
else {
	my $ip = &get_server_ip($server);
	foreach my $f ("/.ssh/known_hosts",
		       "/.ssh/known_hosts2",
		       "/root/.ssh/known_hosts",
		       "/root/.ssh/known_hosts2") {
		my $data = &get_file_data_from_server($srcserver, $f);
		next if (!$data);
		my @lines = split(/\n/, $data);
		my $changed;
		for(my $i=0; $i<@lines; $i++) {
			my @w = split(/\s+/, $lines[$i]);
			my @h = split(/,/, $w[0]);
			if (&indexof($server->{'host'}, @h) >= 0 ||
			    &indexof($ip, @h) >= 0 ||
			    &indexof($server->{'ip'}, @h) >= 0) {
				splice(@lines, $i--, 1);
				$changed++;
				}
			}
		if ($changed) {
			$data = join("\n", @lines)."\n";
			my $err = &put_file_data_to_server($srcserver,
							   $data, $f);
			return $err if ($err);
			}
		}
	return undef;
	}
}

# get_file_data_from_server(&server, remotefile, force-ssh)
# Returns the contents of some file
sub get_file_data_from_server
{
my ($server, $remotefile, $forcessh) = @_;
my $temp = &transname();
my $err = &get_file_from_server($server, $remotefile, $temp, 0, $forcessh);
return undef if ($err);
my $data = &read_file_contents($temp);
&unlink_file($temp);
return $data;
}

# put_file_to_server(&server, localfile, remotefile, device-file, force-ssh)
# Transfers a file from this system to the given server. May use scp or some
# type-specific method
sub put_file_to_server
{
my ($server, $localfile, $remotefile, $device, $forcessh) = @_;
my $pfunc = "type_".$server->{'manager'}."_put_file";
if (defined(&$pfunc) && !$forcessh) {
	# Use type-specific function call
	my $rv = &$pfunc(@_);
	return $rv if ($rv ne 'FALLBACK');	# Type-specific function has
						# asked to fallback to scp
	}
if ($server->{'ssh_nologin'}) {
	return "SSH logins are not available";
	}

if ($device) {
	# Run dd piped into SSH
	my $sshcmd = &build_ssh_command($server);
	$sshcmd .= " dd of=".quotemeta($remotefile)." bs=32768";
	$sshcmd = "dd if=".quotemeta($localfile)." bs=32768 | ".$sshcmd;
	my ($status, $out) =
		&run_ssh_command($sshcmd, $server->{'ssh_pass'});
	return $status ? $out : undef;
	}
else {
	# Just scp up
	my $sshcmd = "scp -r -p";
	$sshcmd .= " -o Protocol=".$server->{'ssh_protocol'};
	if ($server->{'key'}) {
		my ($key) = grep { $_->{'id'} == $server->{'key'} }
				    &list_ssh_keys();
		$sshcmd .= " -i ".quotemeta($key->{'file'});
		}
	if ($server->{'ssh_port'}) {
		$sshcmd .= " -P ".$server->{'ssh_port'};
		}
	$sshcmd .= " ".quotemeta($localfile).
		   " $server->{'ssh_user'}\@$server->{'ip'}:".
		   quotemeta($remotefile);
	my ($status, $out) = &run_ssh_command($sshcmd,$server->{'ssh_pass'});
	return $status ? $out : undef;
	}
}

# put_file_data_to_server(&server, data, remotefile, force-ssh)
# Writes the given data to some remote file. Returns an error message on failure
# or undef on success.
sub put_file_data_to_server
{
my ($server, $data, $remotefile, $forcessh) = @_;
my $temp = &transname();
&open_tempfile(TEMP, ">$temp", 0, 1);
&print_tempfile(TEMP, $data);
&close_tempfile(TEMP);
my $err = &put_file_to_server($server, $temp, $remotefile, 0, $forcessh);
&unlink_file($temp);
return $err;
}

# put_multiple_files_to_server(&server, &localfiles, remotedir, force-ssh)
# Transfers files from this system to the given server. May use scp or some
# type-specific method
sub put_multiple_files_to_server
{
my ($server, $localfiles, $remotedir, $forcessh) = @_;
my $pfunc = "type_".$server->{'manager'}."_put_multiple_files";
if (defined(&$pfunc) && !$forcessh) {
	# Use type-specific function call
	my $rv = &$pfunc(@_);
	return $rv if ($rv ne 'FALLBACK');	# Type-specific function has
						# asked to fallback to scp
	}
if ($server->{'ssh_nologin'}) {
	return "SSH logins are not available";
	}

# Build and run scp command
my $sshcmd = "scp -r -p";
$sshcmd .= " -o Protocol=".$server->{'ssh_protocol'};
if ($server->{'key'}) {
	my ($key) = grep { $_->{'id'} == $server->{'key'} }
			    &list_ssh_keys();
	$sshcmd .= " -i ".quotemeta($key->{'file'});
	}
if ($server->{'ssh_port'}) {
	$sshcmd .= " -P ".$server->{'ssh_port'};
	}
$sshcmd .= " ".join(" ", map { quotemeta($_) } @$localfiles).
	   " $server->{'ssh_user'}\@$server->{'ip'}:".
	   quotemeta($remotedir)."/";
my ($status, $out) = &run_ssh_command($sshcmd, $server->{'ssh_pass'});
return $status ? $out : undef;
}

# transfer_file_between_servers(&source-server, &dest-server,
#				source-file, dest-file,
#				[device-file?], [checksum?], [checksum-size])
# Copy a file from one system to another, directly if possible. Returns undef
# if OK, or an error message on failure.
sub transfer_file_between_servers
{
my ($srcserver, $destserver, $src, $dest, $device, $checksum, $checksize) = @_;
my $rv;
my ($srccs_ok, $srccs);

# Get checksum on source system, if possible
if ($checksum) {
	($srccs_ok, $srccs) = &checksum_file_on_server($srcserver, $src,
						       $checksize);
	}

if ($srcserver->{'id'} eq $destserver->{'id'}) {
	# Self to self - just copy
	my ($out, $ex, $err) = &execute_command_on_server($srcserver,
		$device ?
		  "dd if=".quotemeta($src)." of=".quotemeta($dest)." bs=32768" :
		  "cp ".quotemeta($src)." ".quotemeta($dest));
	$rv = $err ? $err : $ex ? $out : undef;
	}
elsif ($srcserver->{'id'} == 0) {
	# Copying from Cloudmin master - just upload
	$rv = &put_file_to_server($destserver, $src, $dest, $device);
	}
elsif ($destserver->{'id'} == 0) {
	# Copying to Cloudmin master - just download
	$rv = &get_file_from_server($srcserver, $src, $dest, $device);
	}
else {
	# Both are remote! First try scp on source to dest
	# First build scp command
	if ($destserver->{'ssh_nologin'}) {
		return "SSH logins on target system are not available";
		}

	my $keytemp;
	if ($destserver->{'key'}) {
		# A key is needed - copy it to the source system
		my ($key) = grep { $_->{'id'} == $destserver->{'key'} }
				    &list_ssh_keys();
		$keytemp = $key->{'file'};
		$keytemp =~ s/^.*[\\\/]//;
		$keytemp = "/tmp/$keytemp";
		&put_file_to_server($srcserver, $key->{'file'}, $keytemp);
		}

	my $sshcmd;
	if ($device) {
		# Use dd piped into SSH
		$sshcmd = "dd if=".quotemeta($src)." bs=32768 | ssh -q -x";
		$sshcmd .= " -".$destserver->{'ssh_protocol'};
		if ($keytemp) {
			$sshcmd .= " -i ".quotemeta($keytemp);
			}
		if ($destserver->{'ssh_port'}) {
			$sshcmd .= " -p ".$destserver->{'ssh_port'};
			}
		$sshcmd .= " $destserver->{'ssh_user'}\@$destserver->{'ip'}";
		$sshcmd .= " dd of=".quotemeta($dest)." bs=32768";
		}
	else {
		# Can use scp
		$sshcmd = "scp -r -p";
		$sshcmd .= " -o Protocol=".$destserver->{'ssh_protocol'};
		if ($keytemp) {
			$sshcmd .= " -i ".quotemeta($keytemp);
			}
		if ($destserver->{'ssh_port'}) {
			$sshcmd .= " -P ".$destserver->{'ssh_port'};
			}
		$sshcmd .= " ".quotemeta($src);
		$sshcmd .= " $destserver->{'ssh_user'}\@$destserver->{'ip'}:".
			   quotemeta($dest);
		}
	if ($keytemp) {
		$sshcmd .= " ; rm -f ".quotemeta($keytemp);
		}

	# Then execute on the source system
	my ($out, $ex, $err, $status, $fh, $fpid) =
		&execute_command_on_server($srcserver, $sshcmd, undef, 1);
	if (!$err && !$ex) {
		# Started OK .. wait for a password prompt
		$out = undef;
		my ($given_password, $wrong_password, $connect_failed);
		while(1) {
			my $wrv = &wait_for($fh, "password:", "yes\\/no", "(^|\\n)\\s*Permission denied.*\n", "ssh: connect.*\n", ".*\n");
			if ($wrv == 0) {
				syswrite($fh, "$destserver->{'ssh_pass'}\n");
				$given_password++;
				}
			elsif ($wrv == 1) {
				syswrite($fh, "yes\n");
				}
			elsif ($wrv == 2) {
				$wrong_password++;
				$out .= $wait_for_input;
				last;
				}
			elsif ($wrv == 3) {
				$connect_failed++;
				$out .= $wait_for_input;
				}
			elsif ($wrv < 0) {
				last;
				}
			else {
				$out .= $wait_for_input;
				}
			}
		close($fh);
		waitpid($fpid, 0);
		$ex = $?;

		# Check if it worked
		if (!$wrong_password && $given_password < 3 &&
		    !$connect_failed && !$ex) {
			# Looks like it did!
			$rv = undef;
			}
		else {
			# Failed .. record error
			$out =~ s/^\s*\r?\n//;	# Remove empty line at start
			$rv = $out || "SSH failed";
			}
		}
	else {
		$rv = "Direct scp failed : ".($err || $out);
		}
	if ($keytemp) {
		&delete_file_on_server($srcserver, $keytemp);
		}

	if ($rv) {
		# Fall back to fetching to master and uploading
		my $temp = &transname();
		$rv = undef;
		my $err = &get_file_from_server(
				$srcserver, $src, $temp, $device);
		$rv = undef;
		$rv = "Download to Cloudmin master failed : $err" if ($err);
		$err = &put_file_to_server($destserver, $temp, $dest, $device);
		&unlink_file($temp);
		$rv = "Upload from Cloudmin master failed : $err" if ($err);
		}
	}

# Checksum on target
if (!$rv && $srccs_ok && &has_command_on_server($destserver, "md5sum")) {
	my ($destcs_ok, $destcs) = &checksum_file_on_server($destserver, $dest,
							    $checksize);
	if (!$destcs_ok) {
		$rv = "Failed to checksum file on destination system : $destcs";
		}
	elsif ($srccs ne $destcs) {
		$rv = "Checksum mismatch after file transfer : $srccs != $destcs";
		}
	}

return $rv;
}

# pipe_command_to_server(&source-server, &dest-server,source-command, dest-file)
# Run a command on some system and pipe the output to a file on a remote system,
# using SSH.
sub pipe_command_to_server
{
my ($srcserver, $destserver, $srccmd, $dest) = @_;

if ($srcserver->{'id'} eq $destserver->{'id'}) {
	# Self to self - just run the command outputting to the file
	my ($out, $ex, $err) = &execute_command_on_server($srcserver,
		"( ($srccmd) ; echo EXIT_STATUS: \$? 1>&2 ) | ".
		"dd of=".quotemeta($dest)." bs=32768");
	if ($out =~ /EXIT_STATUS:\s+(\d+)/ && $1) {
		# Catch death of dd command in pipeline
		return $out;
		}
	$rv = $err ? $err : $ex ? $out : undef;
	}
elsif ($srcserver->{'id'} == 0) {
	# Copying from Cloudmin master - run command piped into SSH
	my $sshcmd = &build_ssh_command($destserver);
	$sshcmd = "( ( $srccmd ) ; echo EXIT_STATUS: \$? 1>&2 ) | ".
		  $sshcmd." ".quotemeta("dd of=$dest bs=32768");
	my ($status, $out) = &run_ssh_command($sshcmd,
					      $destserver->{'ssh_pass'});
	if ($out =~ /EXIT_STATUS:\s+(\d+)/ && $1) {
		# Catch death of source command in pipeline
		return $out;
		}
	return $status ? $text{'status_'.$status} : undef;
	}
elsif ($destserver->{'id'} == 0) {
	# Copying to Cloudmin master - run SSH command outputting to file
	my $sshcmd = &build_ssh_command($srcserver);
	$sshcmd = "( $sshcmd ".quotemeta($srccmd)." ; ".
		  "  echo EXIT_STATUS: \$? 1>&2 ) ".
		  "| dd of=".quotemeta($dest)." bs=32768";
	my ($status, $out) = &run_ssh_command($sshcmd,
					      $srcserver->{'ssh_pass'});
	if ($out =~ /EXIT_STATUS:\s+(\d+)/ && $1) {
		# Catch death of SSH in pipeline
		return $out;
		}
	return $status ? $text{'status_'.$status} : undef;
	}
else {
	# Both are remote. Run command piping into SSH into destination
	my $rv;
	my $keytemp;
	if ($destserver->{'key'}) {
		# A key is needed - copy it to the source system
		my ($key) = grep { $_->{'id'} == $destserver->{'key'} }
				    &list_ssh_keys();
		$keytemp = $key->{'file'};
		$keytemp =~ s/^.*[\\\/]//;
		$keytemp = "/tmp/$keytemp";
		&put_file_to_server($srcserver, $key->{'file'}, $keytemp);
		}

	# Build SSH command
	$sshcmd = $srccmd." | ssh -q -x";
	$sshcmd .= " -".$destserver->{'ssh_protocol'};
	if ($keytemp) {
		$sshcmd .= " -i ".quotemeta($keytemp);
		}
	if ($destserver->{'ssh_port'}) {
		$sshcmd .= " -p ".$destserver->{'ssh_port'};
		}
	$sshcmd .= " $destserver->{'ssh_user'}\@$destserver->{'ip'}";
	$sshcmd .= " dd of=".quotemeta($dest)." bs=32768";
	if ($keytemp) {
		$sshcmd .= " ; rm -f ".quotemeta($keytemp);
		}

	# Then execute on the source system
	my ($out, $ex, $err, $status, $fh, $fpid) =
		&execute_command_on_server($srcserver, $sshcmd, undef, 1);
	if (!$err && !$ex) {
		# Started OK .. wait for a password prompt
		$out = undef;
		my ($given_password, $wrong_password, $connect_failed);
		$wait_for_input = undef;
		while(1) {
			my $wrv = &wait_for($fh, "password:", "yes\\/no", "(^|\\n)\\s*Permission denied.*\n", "ssh: connect.*\n", ".*\n");
			if ($wrv == 0) {
				syswrite($fh, "$destserver->{'ssh_pass'}\n");
				$given_password++;
				}
			elsif ($wrv == 1) {
				syswrite($fh, "yes\n");
				}
			elsif ($wrv == 2) {
				$wrong_password++;
				$out .= $wait_for_input;
				last;
				}
			elsif ($wrv == 3) {
				$connect_failed++;
				$out .= $wait_for_input;
				}
			elsif ($wrv < 0) {
				last;
				}
			else {
				$out .= $wait_for_input;
				}
			}
		close($fh);
		waitpid($fpid, 0);
		$ex = $?;

		# Check if it worked
		if (!$wrong_password && $given_password < 3 &&
		    !$connect_failed && !$ex) {
			# Looks like it did!
			$rv = undef;
			}
		else {
			# Failed .. record error
			$out =~ s/^\s*\r?\n//;	# Remove empty line at start
			$rv = $out || "SSH failed";
			}
		}
	else {
		$rv = "SSH transfer failed : ".($err || $out);
		}
	if ($keytemp) {
		&delete_file_on_server($srcserver, $keytemp);
		}
	return $rv;
	}
}

# pipe_command_from_server(&source-server, &dest-server,
# 			   dest-command, source-file)
# Run a command on some system whose input is the contents of a file on some
# other system, using SSH.
sub pipe_command_from_server
{
my ($srcserver, $destserver, $destcmd, $src) = @_;
if ($srcserver->{'id'} eq $destserver->{'id'}) {
	# Self to self - just run the command inputting from the file
	my ($out, $ex, $err) = &execute_command_on_server($srcserver,
		"(dd if=".quotemeta($src)." bs=32768 ; ".
		" echo EXIT_STATUS: \$? 1>&2) | ($destcmd)");
	if ($out =~ /EXIT_STATUS:\s+(\d+)/ && $1) {
		# Catch death of dd command in pipeline
		return $out;
		}
	$rv = $err ? $err : $ex ? $out : undef;
	}
elsif ($srcserver->{'id'} == 0) {
	# Copying from Cloudmin master - run command with SSH piped in
	my $sshcmd = &build_ssh_command($destserver);
	$sshcmd = "(dd if=".quotemeta($src)." bs=32768 ; ".
		  " echo EXIT_STATUS: \$? 1>&2) | ".
		  $sshcmd." ".quotemeta($destcmd);
	my ($status, $out) = &run_ssh_command(
				$sshcmd, $destserver->{'ssh_pass'});
	if ($out =~ /EXIT_STATUS:\s+(\d+)/ && $1) {
		# Catch death of dd command in pipeline
		return $out;
		}
	return $status ? $text{'status_'.$status} : undef;
	}
elsif ($destserver->{'id'} == 0) {
	# Copying to Cloudmin master - run SSH command outputting file piped
	# into command
	my $sshcmd = &build_ssh_command($srcserver);
	$sshcmd = "( $sshcmd dd if=".quotemeta($src)." bs=32768 ; ".
		  " echo EXIT_STATUS: \$? 1>&2) | ".$destcmd;
	my ($status, $out) = &run_ssh_command($sshcmd,
					      $srcserver->{'ssh_pass'});
	if ($out =~ /EXIT_STATUS:\s+(\d+)/ && $1) {
		# Catch death of dd command via SSH in pipeline
		return $out;
		}
	return $status ? $text{'status_'.$status} : undef;
	}
else {
	# Both are remote. Run command on the source system which is an SSH 
	# to the dest, with the file as input.
	my $rv;
	my $keytemp;
	if ($destserver->{'key'}) {
		# A key is needed - copy it to the source system
		my ($key) = grep { $_->{'id'} == $destserver->{'key'} }
				    &list_ssh_keys();
		$keytemp = $key->{'file'};
		$keytemp =~ s/^.*[\\\/]//;
		$keytemp = "/tmp/$keytemp";
		&put_file_to_server($srcserver, $key->{'file'}, $keytemp);
		}

	# Build SSH command
	$sshcmd = "dd if=".quotemeta($src)." bs=32768 | ssh -q -x";
	$sshcmd .= " -".$destserver->{'ssh_protocol'};
	if ($keytemp) {
		$sshcmd .= " -i ".quotemeta($keytemp);
		}
	if ($destserver->{'ssh_port'}) {
		$sshcmd .= " -p ".$destserver->{'ssh_port'};
		}
	$sshcmd .= " $destserver->{'ssh_user'}\@$destserver->{'ip'}";
	$sshcmd .= " ".quotemeta($destcmd);
	if ($keytemp) {
		$sshcmd .= " ; rm -f ".quotemeta($keytemp);
		}

	# Then execute on the source system
	my ($out, $ex, $err, $status, $fh, $fpid) =
		&execute_command_on_server($srcserver, $sshcmd, undef, 1);
	if (!$err && !$ex) {
		# Started OK .. wait for a password prompt
		$out = undef;
		my ($given_password, $wrong_password, $connect_failed);
		while(1) {
			my $wrv = &wait_for($fh, "password:", "yes\\/no", "(^|\\n)\\s*Permission denied.*\n", "ssh: connect.*\n", ".*\n");
			if ($wrv == 0) {
				syswrite($fh, "$destserver->{'ssh_pass'}\n");
				$given_password++;
				}
			elsif ($wrv == 1) {
				syswrite($fh, "yes\n");
				}
			elsif ($wrv == 2) {
				$wrong_password++;
				$out .= $wait_for_input;
				last;
				}
			elsif ($wrv == 3) {
				$connect_failed++;
				$out .= $wait_for_input;
				}
			elsif ($wrv < 0) {
				last;
				}
			else {
				$out .= $wait_for_input;
				}
			}
		close($fh);
		waitpid($fpid, 0);
		$ex = $?;

		# Check if it worked
		if (!$wrong_password && $given_password < 3 &&
		    !$connect_failed && !$ex) {
			# Looks like it did!
			$rv = undef;
			}
		else {
			# Failed .. record error
			$out =~ s/^\s*\r?\n//;	# Remove empty line at start
			$rv = $out || "SSH failed";
			}
		}
	else {
		$rv = "SSH transfer failed : ".($err || $out);
		}
	if ($keytemp) {
		&delete_file_on_server($srcserver, $keytemp);
		}
	return $rv;
	}

}

# delete_file_on_server(&server, remotefile, [no-quote])
# Deletes a file on a managed server. Returns undef on success, or an error
# message on failure.
sub delete_file_on_server
{
my ($server, $remotefile, $noquote) = @_;
my $dfunc = "type_".$server->{'manager'}."_delete_file";
if (defined(&$dfunc)) {
	# Use type-specific function call
	my $rv = &$dfunc(@_);
	return $rv if ($rv ne 'FALLBACK');	# Type-specific function has
						# asked to fallback to scp
	}

# Just run rm via SSH
my ($out, $ex, $err) = &execute_command_on_server($server,
				"rm -rf ".($noquote ? $remotefile
						    : quotemeta($remotefile)));
return $err ? $err : $ex ? $out : undef;
}

# stat_file_on_server(&server, remotefile)
# Returns the stat structure for a file on a server.
# If something failed, returns a 1-element array containing the error.
# If the file doesn't exist, returns an empty array.
sub stat_file_on_server
{
my ($server, $remotefile) = @_;
my $gfunc = "type_".$server->{'manager'}."_stat_file";
if (defined(&$gfunc)) {
	# Use type-specific function call
	my @rv = &$gfunc(@_);
	return @rv if ($rv[0] ne 'FALLBACK');
	}

if ($server->{'status'} eq 'virt' || $server->{'status'} eq 'novirt') {
	# If the remote system has Webmin, ask it to stat. If this fails, fall
	# back to using SSH
	$last_remote_error = undef;
	&remote_foreign_require($server, "webmin", "webmin-lib.pl");
	if (!$last_remote_error) {
		my $st = &remote_eval($server, "webmin",
				      "[ stat('$remotefile') ]");
		return @$st if ($st);
		}
	}

# Use stat command, perl, or in worst case ls -l
my ($out, $ex, $err) = &execute_command_on_server($server,
	"stat -t ".quotemeta($remotefile));
return ( $err ) if ($err);
if ($out =~ /No such file/i) {
	return ( );
	}
elsif (!$ex && $out =~ /^\Q$remotefile\E\s/) {
	# Parse stat command output
	my @w = split(/\s+/, $out);
	my @st;
	$st[0] = hex($w[6]);		# Device
	$st[1] = $w[7];			# Inode
	$st[2] = hex($w[3]);		# Permissions
	$st[3] = $w[8];			# Links
	$st[4] = $w[4];			# UID
	$st[5] = $w[5];			# GID
	$st[6] = undef;			# Rdev .. don't know
	$st[7] = $w[1];			# Size
	$st[8] = $w[11];		# Last access time
	$st[9] = $w[12];		# Modify time
	$st[10] = $w[13];		# Inode change time
	$st[11] = $w[14];		# Block size
	$st[12] = $w[2];		# Number of blocks
	return @st;
	}

# Next try perl, with script as an input file as passing a complex
# command via -e doesn't work
my $cmdtemp = &tempname_on_server($server);
my $err = &put_file_data_to_server($server,
		'print join(":", stat($ARGV[0]))."\n"', $cmdtemp);
if (!$err) {
	my ($out, $ex, $err) = &execute_command_on_server($server,
		"perl $cmdtemp ".quotemeta($remotefile));
	&delete_file_on_server($server, $cmdtemp);
	return ( $err ) if ($err);
	if (!$ex) {
		$out =~ s/\r|\n//g;
		return split(/:/, $out);
		}
	}

# Finally, use ls .. which gives less info :-(
my ($out, $ex, $err) = &execute_command_on_server($server,
	"ls -ldn ".quotemeta($remotefile));
return ( $err ) if ($err);
if ($out =~ /No such file/i) {
	return ( );
	}
elsif ($ex || $out !~ /\s\Q$remotefile\E$/) {
	return ( "ls -ldn $remotefile failed : $out" );
	}
else {
	# Parse ls command output
	my @now = localtime(time());
	my @w = split(/\s+/, $out);
	my @st;
	$st[3] = $w[1];			# Links
	$st[4] = $w[2];			# UID
	$st[5] = $w[3];			# GID
	$st[7] = $w[4];			# Size
	if ($w[7] =~ /^(\d+):(\d+)$/) {
		# Time is month day hour:minute
		my @tm = ( 0, $2, $1, $w[6],
			      &month_to_number($w[5]), $now[5] );
		$st[8] = $st[9] = $st[10] = timelocal(@tm);
		}
	elsif ($w[7] =~ /^\d+$/) {
		# Time is month day year
		my @tm = ( 0, 0, 0, $w[6],
			      &month_to_number($w[5]), $w[7]-1900 );
		$st[8] = $st[9] = $st[10] = timelocal(@tm);
		}
	$st[2] = 0;			# Permissions
	my @p = reverse(split(//, $w[0]));
	for(my $i=0; $i<9; $i++) {
		if ($p[$i] ne '-') {
			$st[2] += (1<<$i);
			}
		}
	return @st;
	}
}

# has_command_on_server(&server, command)
# Returns the full path to some command, or undef if missing
sub has_command_on_server
{
my ($server, $cmd) = @_;
my ($out, $ex, $err) = &execute_command_on_server($server, "which $cmd");
if ($ex || $out =~ /no\s+\Q$cmd\E\s+in/) {
	# Failed .. but maybe we don't even have the which command??
	if ($out =~ /which:\s+command\s+not\s+found/i) {
		if ($cmd =~ /^\//) {
			# Full path given, so just look for it
			my (undef, $tex, undef) = &execute_command_on_server(
				$server, "test -x $cmd");
			if (!$tex) {
				$out = $cmd;
				}
			else {
				return undef;
				}
			}
		else {
			# Search PATH manually
			($out, $ex, $err) = &execute_command_on_server($server,
				"for p in `echo \$PATH | sed -e 's/:/ /g'`; do if [ -r \"\$p/$cmd\" ]; then echo \"\$p/$cmd\"; fi; done");
			if ($out !~ /^\S+\/\Q$cmd\E/) {
				# That failed too :(
				return undef;
				}
			}
		}
	else {
		return undef;
		}
	}
$out =~ s/\r|\n//g;
return $out;
}

# checksum_file_on_server(&server, file, [data-size])
# Performs an MD5 checksum of a file on some system. Returns 1 and the checksum
# on success, or 0 and an error message on failure. If a size is given, only
# that many bytes are checksummed.
sub checksum_file_on_server
{
my ($server, $file, $size) = @_;
my $dfunc = "type_".$server->{'manager'}."_checksum_file";
if (defined(&$dfunc)) {
	# Use type-specific function call
	my @rv = &$dfunc(@_);
	return @rv if ($rv[0] ne 'FALLBACK');	# Type-specific function has
						# asked to fallback to ssh
	}

# Run md5sum via SSH
my $cmd;
if ($size) {
	my $count = int($size / 32768);
	$cmd = "dd if=".quotemeta($file).
	       " bs=32768 count=$count 2>/dev/null | md5sum -";
	}
else {
	$cmd = "md5sum ".quotemeta($file);
	}
my ($out, $ex, $err) = &execute_command_on_server($server, $cmd);
if ($err) {
	return (0, $err);
	}
elsif ($ex) {
	return (0, $out);
	}
elsif ($out =~ /^([0-9a-f]+)\s+/) {
	return (1, $1);
	}
else {
	return (0, "Unknown md5sum output : $out");
	}
}

# make_dir_on_server(&server, dir, perms, [recursive])
# Creates a directory on a remote system. Returns an error message on failure,
# undef on success.
sub make_dir_on_server
{
my ($server, $dir, $perms, $recur) = @_;
my $dfunc = "type_".$server->{'manager'}."_make_dir";
if (defined(&$dfunc)) {
	# Use type-specific function call
	my $rv = &$dfunc(@_);
	return $rv if ($rv ne 'FALLBACK');	# Type-specific function has
						# asked to fallback to ssh
	}

# Run mkdir via SSH
my $operms = sprintf("%o", $perms);
my ($out, $ex, $err) = &execute_command_on_server($server,
	"mkdir ".
	($perms ? " -m ".quotemeta($operms) : "").
	($recur ? " -p" : "")." ".
	quotemeta($dir));
return $err ? $err : $ex ? $out : undef;
}

# list_dir_on_server(&server, dir)
# Lists the contents of a directory on a remote system. Returns an array ref
# of filenames (except . and ..) on success, or an error message on failure.
sub list_dir_on_server
{
my ($server, $dir) = @_;
my $dfunc = "type_".$server->{'manager'}."_list_dir";
if (defined(&$dfunc)) {
	# Use type-specific function call
	my $rv = &$dfunc(@_);
	return $rv if ($rv ne 'FALLBACK');	# Type-specific function has
						# asked to fallback to ssh
	}

# Run ls via SSH
my ($out, $ex, $err) = &execute_command_on_server($server,
	"ls -a ".quotemeta($dir));
return $err if ($err);
return $out if ($ex);
my @rv = grep { $_ ne "." && $_ ne ".." } split(/\r?\n/, $out);
return \@rv;
}

# disk_usage_on_server(&server, dir)
# Returns the size of a directory in bytes, or an error message.
sub disk_usage_on_server
{
my ($server, $dir) = @_;
my $dfunc = "type_".$server->{'manager'}."_disk_usage";
if (defined(&$dfunc)) {
	# Use type-specific function call
	my $rv = &$dfunc(@_);
	return $rv if ($rv ne 'FALLBACK');	# Type-specific function has
						# asked to fallback to ssh
	}

# Run du via SSH
my ($out, $ex, $err) = &execute_command_on_server($server,
	"du -sk ".quotemeta($dir));
return $err if ($err);
return $out if ($ex);
return $out =~ /^(\d+)\s/ ? $1*1024 : "Unknown du output : $out";
}

# shared_dir_on_servers(&server1, &server2, dir)
# Checks if some directory is shared between two machines (ie. via NFS)
sub shared_dir_on_servers
{
my ($server1, $server2, $dir) = @_;
my $movecheck = $dir."/cloudmin-move-test.txt";
my $randstr = time().$$;
&put_file_data_to_server($server1, $randstr, $movecheck);
my $randback = &get_file_data_from_server($server2, $movecheck);
&delete_file_on_server($server1, $movecheck);
return $randback eq $randstr;
}

# list_processes_on_server(&server)
# Returns a list of running processes, in a format similar to
# proc::list_processes. Only the pid, user and args are guaranteed though.
# Return an array ref on success, or an error string on failure.
sub list_processes_on_server
{
my ($server) = @_;
my @procs;
if ($server->{'status'} eq 'virt' || $server->{'status'} eq 'novirt') {
	# Can call Webmin
	$last_remote_error = undef;
	&remote_foreign_require($server, "proc", "proc-lib.pl");
	if (!$last_remote_error) {
		@procs = &remote_foreign_call($server, "proc","list_processes");
		}
	if (!$last_remote_error) {
		return \@procs;
		}
	}
# Fall back to ps command, trying various options
my ($out, $ex, $err);
foreach my $cmd (
	[ "ps --cols 2048 -e -o pid,user,args", 3, [ 0, 1, 2 ] ],  # Linux
	[ "ps -e -o pid,user,args", 3, [ 0, 1, 2 ] ],		   # Solaris
	) {
	($out, $ex, $err) = &execute_command_on_server($server,$cmd->[0]);
	if (!$ex && !$err) {
		foreach my $l (split(/\r?\n/, $out)) {
			my %p;
			$l =~ s/^\s+//;
			my @w = split(/\s+/, $l, $cmd->[1]);
			$p{'pid'} = $w[$cmd->[2]->[0]];
			$p{'user'} = $w[$cmd->[2]->[1]];
			$p{'args'} = $w[$cmd->[2]->[2]];
			push(@procs, \%p);
			}
		return \@procs;
		}
	}
my $msg = $err || $out;
return "Failed to list processes : $msg";
}

sub remote_error_handler
{
$last_remote_error = join("", @_);
$server_manager::last_remote_error = $last_remote_error;
}

sub nice_error_status
{
my ($status) = @_;
return $text{'status_'.int($status)};
}

# os_to_server_type(os-code, real-os-type)
# Returns an OS type as used by the Webmin Servers Index module
sub os_to_server_type
{
my ($os, $realos) = @_;
my $type = 'unknown';
foreach my $s (@servers::server_types) {
	if ($s->[2] && $os =~ /^$s->[2]$/ || $s->[3] && $realos =~ /$s->[3]/) {
		$type = $s->[0];
		last;
		}
	}
return $type;
}

# ping_server_host(hostname|ip, [force_timeout])
# Returns 1 if some host responds to a ping in 2 seconds
sub ping_server_host
{
my ($host, $force_timeout) = @_;
my $timeout = $force_timeout || $ping_host_timeout;
my $pingcmd = $gconfig{'os_type'} =~ /-linux$/ ? "ping -c 1" : "ping";
my ($out, $timed_out) = &backquote_with_timeout(
	$pingcmd." ".$host." 2>&1", $timeout, 1);
return !$timed_out && !$? ? 1 : 0;
}

# wait_for_ping(&server, [timeout])
# Wait for some number of seconds for a system to be pingable. Returns 1 if OK,
# 0 if failed.
sub wait_for_ping
{
my ($server, $timeout) = @_;
$timeout ||= 60;
my $ip = &get_server_ip($server);
my $pingstart = time();
while(time() - $pingstart < $timeout) {
	sleep(1);
	if (&ping_server_host($ip)) {
		return 1;
		}
	}
return 0;
}

# wait_for_ssh(&server, [timeout])
# Wait for some number of seconds for a system to be contactable on the SSH
# port. Returns 1 if OK, 0 if failed.
sub wait_for_ssh
{
my ($server, $timeout) = @_;
$timeout ||= 60;
my $ip = &get_server_ip($server);
my $sshstart = time();
while(time() - $sshstart < 60) {
	sleep(1);
	my $ssherr;
	eval {
		local $SIG{'ALRM'} = sub { die "timeout" };
		alarm(5);
		&open_socket($ip, $server->{'ssh_port'} || 22, SSHTEST,
			     \$ssherr);
		close(SSHTEST);
		alarm(0);
		};
	if (!$ssherr && !$@) {
		return 1;
		}
	}
return 0;
}

# check_server_status(&server, [re-generate-collected], [skip-info], [time])
# Checks the status of a managed server, and updates the server object. Checks
# SSH login, Webmin login, Virtualmin status, number of domains, memory, disk
# and CPU load.
sub check_server_status
{
my ($server, $regen, $skipinfo, $time) = @_;

# Check if a status update is already happening
if (&test_lock_server($server)) {
	# Already locked .. wait till free, and get new status from file
	my $c = 0;
	while(&test_lock_server($server)) {
		sleep(1);
		$c++;
		if ($c > 120) {
			# Too slow!
			&error("Pending status update for $server->{'host'} ".
			       "took more than 2 minutes");
			}
		}
	my ($newserver) = grep { $_->{'id'} eq $server->{'id'} }
				  &list_managed_servers();
	foreach my $k ('statustime', 'status', 'status_msg') {
		$server->{$k} = $newserver->{$k};
		}
	return $server->{'status'} eq 'virt' ||
	       $server->{'status'} eq 'novirt';
	}
else {
	# Lock to prevent concurrent access
	&obtain_lock_server($server);
	}

# Do a quick ping, if this is a non-virtual system.
# Don't ping if the virtual system type (ie Xen) has it's own function to 
# detect status though, unless SSH logins are disabled
$server->{'statustime'} = time();
$server->{'status_hostkey'} = 0;
my $clfunc = "type_".$server->{'manager'}."_check_login";
my $ping = &ping_server_host($server->{'ip'});

# If SSH logins are disabled, go no further
if ($server->{'ssh_nologin'}) {
	my $status;
	if (defined(&$clfunc)) {
		# Call the Xen status function, which can provide more info
		# on why it is down
		($status) = &$clfunc($server);
		}
	if (!$status) {
		# Only if the Xen status function didn't report any further
		# error do we use the result of the ping
		$server->{'status'} = $ping ? "alive" : "noping";
		$server->{'status_msg'} = $ping ? undef : "Ping failed";
		&save_server_collected($server, undef);
		goto DONECHECK;
		}
	}

# Check if we can login
my $rv = 0;
my ($status, $err, $webminroot, $webminport, $webminssl, $hostname) =
	&check_server_ssh_login($server);
$err =~ s/\r?\n/ /g;
if ($status == 2) {
	# Could not login via SSH
	$server->{'status'} = 'nosshlogin';
	$server->{'status_msg'} = $err;
	goto DONECHECK;
	}
elsif ($status == 7) {
	# SSH login is not root
	$server->{'status'} = 'nosshlogin';
	$server->{'status_msg'} = "User does not have root access";
	goto DONECHECK;
	}
elsif ($status == 8) {
	# Intentionally paused
	$server->{'status'} = 'paused';
	$server->{'status_msg'} = 'Virtual system suspended';
	goto DONECHECK;
	}
elsif ($status == 5) {
	# Hosting system is down
	$server->{'status'} = 'nohost';
	$server->{'status_msg'} = $err;
	goto DONECHECK;
	}
elsif ($status == 6) {
	# Virtual system down
	$server->{'status'} = 'down';
	$server->{'status_msg'} = $err;
	goto DONECHECK;
	}
elsif ($status && !$ping && !defined(&$clfunc)) {
	# Could not SSH or ping, so assume totally down (for real systems)
	$server->{'status'} = 'down';
	$server->{'status_msg'} = $err;
	goto DONECHECK;
	}
elsif ($status && !$ping) {
	# Could not SSH or ping, but this is a virtual system which is
	# supposedly up.
	$server->{'status'} = 'noping';
	$server->{'status_msg'} = $err;
	goto DONECHECK;
	}
elsif ($status) {
	# Could not SSH, but can ping or the virtual system reports that
	# it should be up
	$server->{'status'} = 'nossh';
	$server->{'status_msg'} = $err;
	$server->{'status_hostkey'} = $err =~ /Invalid\s+host\s+key/i ? 1 : 0;
	goto DONECHECK;
	}

# Fix up Webmin port and SSL flag to reflect reality, if we don't know them
if ($webminport && $server->{'id'} != 0) {
	if ($server->{'port'} eq '') {
		$server->{'port'} = $webminport;
		}
	if ($server->{'ssl'} eq '') {
		$server->{'ssl'} = $webminssl;
		}
	if (!$server->{'user'} && !$server->{'no_webmin_login'}) {
		# SSH says we have Webmin, but we don't know the login! Most
		# likely it was installed behind our back, so assume login is
		# same as root.
		$server->{'user'} = $server->{'ssh_user'} || 'root';
		$server->{'pass'} = $server->{'ssh_pass'};
		$server->{'ssh_pass_same'} = $server->{'ssh_pass'} ? 1 : 0;
		}
	}

# Save the hostname, if we got it
if ($hostname) {
	$server->{'unix_hostname'} = $hostname;
	}

if ($regen) {
	# Force re-generation of all info
	delete($server->{'virtualmin_poss'});
	delete($server->{'all_poss'});
	&save_server_collected($server, undef);
	}

# If we have a Webmin login, try it
my ($got_memory, $got_disk, $got_kernel, $got_io, $got_kernel);
if ($server->{'user'} || $server->{'id'} == 0) {
	my ($status, $err, $ostype, $real_ostype) =
		&check_server_webmin_login($server);
	if ($status == 2) {
		# Webmin replied, but it rejected our login
		$server->{'status'} = 'nowebminlogin';
		$server->{'status_msg'} = $err;
		goto DONECHECK;
		}
	elsif ($status) {
		# Could not login to Webmin .. which may be because it is down,
		# un-contactable, or not installed
		$server->{'status'} = $webminroot ? 'downwebmin' : 'nowebmin';
		$server->{'status_msg'} = $err;
		goto DONECHECK;
		}

	# Webmin is OK! Check for Virtualmin
	my $info;
	my $webmin_timeout = int($config{'webmin_timeout'}) || 60;
	$webmin_timeout *= 3 if ($regen);
	eval {
		local $SIG{'ALRM'} = sub { die "timeout\n" };
		local $main::error_must_die = 1;
		alarm($webmin_timeout);
		$server->{'status_msg'} = undef;
		if (&remote_foreign_check($server, "virtual-server") &&
		    !$server->{'novirtualmin'}) {
			# Get and save remote Virtualmin domains
			$server->{'status'} = 'virt';
			goto SKIPINFO if ($skipinfo);
			&remote_foreign_require($server, "virtual-server",
						"virtual-server-lib.pl");
			alarm($webmin_timeout * 3);	# Give this longer,
							# as connect worked
			my @doms = &remote_foreign_call($server,
					"virtual-server", "list_domains");
			&save_server_domains($server, \@doms);

			# Get and save collected status info
			$info = &remote_foreign_call($server, "virtual-server",
			     $regen ? "collect_system_info"
				    : "get_collected_info");
			$info->{'minfo'} = &remote_eval($server,
				"virtual_server", "\\\%module_info");
			$info->{'config'} = &remote_foreign_config(
				$server, "virtual-server");
			if (&remote_eval($server, "virtual_server",
				      "defined(\&list_available_features)")) {
				$info->{'features'} = [
					&remote_foreign_call($server,
					"virtual-server",
					"list_available_features") ];
				}
			$info->{'template'} = &remote_foreign_call($server,
					"virtual-server", "get_template", 0);
			$info->{'defip'} = &remote_foreign_call($server,
					"virtual-server", "get_default_ip");
			$got_memory = 1;
			$got_disk = 1;
			if ($info->{'kernel'}) {
				$got_kernel = 1;
				}
			if ($info->{'io'}) {
				$got_io = 1;
				}
			if ($info->{'cpu'}) {
				$got_cpu = 1;
				}

			# Get and save serial number
			delete($info->{'serial'});
			if ($info->{'minfo'}->{'version'} !~ /gpl/) {
				my $serial = &remote_eval($server,
					"virtual_server",
					"\&read_env_file(\$virtualmin_license_file, \\\%serial); return \\\%serial");
				if ($serial->{'SerialNumber'} ne 'GPL') {
				    $info->{'serial'} =
					{ 'serial' => $serial->{'SerialNumber'},
					  'key' => $serial->{'LicenseKey'} };
				    my $lstatus = &remote_eval($server,
					"virtual_server",
					"\&read_env_file(\$licence_status, \\\%lstatus); return \\\%lstatus");
				    if ($lstatus && ref($lstatus)) {
					$info->{'serial'}->{'expiry'} =
						$lstatus->{'expiry'};
					}
				    }
				}

			# Perform a config check, if we haven't done an OK
			# one yet. This may be slow, so reset the timeout.
			if (!$server->{'virtualmin_checked'}) {
				alarm($webmin_timeout * 3);
				&check_virtualmin_config($server, 1);
				}

			# Cache number of domains, updates and licence
			$server->{'virtualmin_domains'} = scalar(@doms);
			$server->{'virtualmin_poss'} =
				scalar(@{$info->{'poss'}});
			if ($info->{'allposs'}) {
				$server->{'all_poss'} =
					scalar(@{$info->{'allposs'}});
				}
			if ($info->{'serial'}) {
				$server->{'virtualmin_serial'} =
					$info->{'serial'}->{'serial'};
				$server->{'virtualmin_key'} =
					$info->{'serial'}->{'key'};
				}
			else {
				delete($server->{'virtualmin_serial'});
				delete($server->{'virtualmin_key'});
				}
			}
		elsif (&remote_foreign_check($server, "system-status")) {
			# Get info from new Webmin status module
			&save_server_domains($server, [ ]);
			$server->{'status'} = 'novirt';
			goto SKIPINFO if ($skipinfo);
			&remote_foreign_require($server, "system-status",
						"system-status-lib.pl");
			$info = &remote_foreign_call($server, "system-status",
			     $regen ? "collect_system_info"
				    : "get_collected_info");
			if ($info->{'kernel'}) {
				$got_kernel = 1;
				}
			if (&remote_foreign_check($server, "security-updates")){
				# System has security-updates module, probably
				# because it runs Cloudmin. Fetch updates that
				# are specific to Cloudmin.
				&remote_foreign_require($server,
					"security-updates",
					"security-updates-lib.pl");
				my @poss = &remote_foreign_call($server,
					"security-updates",
					"list_possible_updates", 2);
				$info->{'allposs'} = $info->{'poss'};
				$server->{'all_poss'} =
					scalar(@{$info->{'allposs'}});
				$info->{'poss'} = \@poss;
				$server->{'virtualmin_poss'} =
					scalar(@{$info->{'poss'}});
				}
			else {
				$server->{'all_poss'} =
					scalar(@{$info->{'poss'}});
				delete($server->{'virtualmin_poss'});
				}
			}
		else {
			# Doesn't have Virtualmin
			&save_server_domains($server, [ ]);
			$server->{'status'} = 'novirt';
			$server->{'status_msg'} = undef;
			delete($server->{'virtualmin_domains'});
			delete($server->{'virtualmin_poss'});
			delete($server->{'all_poss'});
			goto SKIPINFO if ($skipinfo);
			$info = { };

			# Make some direct Webmin calls to get info, starting
			# with memory total and used
			if (&remote_foreign_check("proc")) {
				&remote_foreign_require($server, "proc",
					"proc-lib.pl");
				if (&remote_eval($server, "proc",
					'defined(&get_cpu_info)')) {
					my @load = &remote_foreign_call(
					    $server, "proc", "get_cpu_info");
					if (@load) {
						$info->{'load'} = \@load;
						}
					}
				if (&remote_eval($server, "proc",
					'defined(&get_memory_info)')) {
					my @mem = &remote_foreign_call(
					    $server, "proc", "get_memory_info");
					if (@mem) {
						$info->{'mem'} = \@mem;
						$got_memory = 1;
						}
					}
				}
			}

		# Get common Webmin information
		&remote_foreign_require($server, "webmin", "webmin-lib.pl");
		$info->{'general'}->{'version'} = 
			&remote_foreign_call($server, "webmin",
					     "get_webmin_version");
		$info->{'general'}->{'installtype'} = 
			&remote_foreign_call($server, "webmin",
					     "get_install_type");
		$info->{'general'}->{'theme'} =
			&remote_eval($server, "webmin", "\$current_theme");
		$info->{'general'}->{'tinfo'} =
			&remote_eval($server, "webmin",
				 "\%t=get_theme_info(\$current_theme); \\\%t");

		# Get network interfaces, as seen by the system
		my $ifunc = "type_".$server->{'manager'}."_list_interfaces";
		if (!defined(&$ifunc) &&
		    &remote_foreign_check($server, "net")) {
			&remote_foreign_require($server, "net", "net-lib.pl");
			$info->{'ifaces'} = [ &remote_foreign_call(
				$server, "net", "active_interfaces") ];
			}

		# Get Webmin config dir, if not known yet
		if (!$server->{'webmin_config_directory'}) {
			$server->{'webmin_config_directory'} =
			  &remote_eval($server, "webmin", "\$config_directory");
			}

		SKIPINFO:
		alarm(0);
		};
	if ($@) {
		# Failed in some way, most likely a timeout
		$server->{'status'} = 'downwebmin';
		if ($@ =~ /timeout/) {
			$server->{'status_msg'} = "Failed to get status from Webmin in $webmin_timeout seconds";
			}
		else {
			$server->{'status_msg'} = $@;
			}
		}

	# Fix up detected OS
	if ($server->{'type'} eq 'unknown') {
		$server->{'type'} = &os_to_server_type($ostype, $real_ostype);
		}

	&save_server_collected($server, $info);
	}
elsif ($server->{'no_webmin_login'}) {
	# Webmin login disabled
	$server->{'status'} = 'nowebmin';
	$server->{'status_msg'} = "Webmin login disabled";
	}
else {
	# Webmin is not available
	$server->{'status'} = $webminroot ? 'nowebminlogin' : 'nowebmin';
	$server->{'status_msg'} = undef;
	}

# If we couldn't get memory or disk from Webmin, get it via SSH
my $info = &get_server_collected($server);
my $got_more_info;
if (!$got_memory) {
	# Try Linux "free" command
	my ($out, $ex, $err) = &execute_command_on_server($server, "free");
	if (!$ex && !$err) {
		my @mem;
		if ($out =~ /Mem:\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)/i) {
			$mem[0] = $1;
			$mem[1] = $3 + $5 + $6;
			}
		if ($out =~ /Swap:\s+(\d+)\s+(\d+)\s+(\d+)/i) {
			$mem[2] = $1;
			$mem[3] = $3;
			}
		if (@mem) {
			$info->{'mem'} = \@mem;
			$got_more_info = $got_memory = 1;
			}
		}

	# Try Solaris kstat and swap commands
	if (!$got_memory && &has_command_on_server($server, "kstat")) {
		my %stat;
		foreach my $s ("physmem", "freemem") {
			my ($out) = &execute_command_on_server(
					$server, "kstat -p -m unix -s $s");
			if ($out =~ /\s+(\d+)/) {
				$stat{$s} = $1;
				}
			}
		my ($swaptotal, $swapfree);
		my ($out) = &execute_command_on_server(
				$server, "swap -l");
		foreach my $line (split(/\r?\n/, $out)) {
			if ($line =~ /^\S+\s+\d+,\d+\s+\d+\s+(\d+)\s+(\d+)/) {
				$swaptotal += $1;
				$swapfree += $2;
				}
			}
		local ($pagesize) = &execute_command_on_server(
					$server, "pagesize 2>/dev/null");
		$pagesize = int($pagesize)/1024;
		$pagesize ||= 8;	# Fallback
		if ($stat{'physmem'}) {
			$info->{'mem'} = [ $stat{'physmem'}*$pagesize,
					   $stat{'freemem'}*$pagesize,
					   $swaptotal/2, $swapfree/2 ];
			$got_more_info = $got_memory = 1;
			}
		}

	# Get CPU load from "uptime" command
	my ($out, $ex, $err) = &execute_command_on_server($server, "uptime");
	if (!$ex && !$err &&
	    $out =~ /average:\s+([0-9\.]+),\s*([0-9\.]+),\s*([0-9\.]+)/i) {
		$info->{'load'} = [ $1, $2, $3 ];
		$got_more_info = 1;
		}
	}

if (!$got_disk) {
	# Get disk from df command
	my ($out, $ex, $err) = &execute_command_on_server($server, "df -kl");
	if (!$ex && !$err) {
		my @lines = split(/\r?\n/, $out);
		my ($total, $free);
		for(my $i=0; $i<@lines; $i++) {
			my $l = $lines[$i];
			if ($l =~ /^\/\S+$/) {
				# Filesystem name on own line
				$l .= $lines[++$i];
				}
			if ($l =~ /^\// && $l !~ /^\/platform\//) {
				my ($fs, $blocks, $used, $avail) =
					split(/\s+/, $l);
				if ($blocks) {
					$total += $blocks*1024;
					}
				else {
					$total += ($used+$avail)*1024;
					}
				$free += $avail*1024;
				}
			}
		if ($total) {
			$info->{'disk_total'} = $total;
			$info->{'disk_free'} = $free;
			}
		$got_more_info = 1;
		}
	}

# Get kernel and CPU info via SSH
if (!$got_kernel) {
	my ($out, $ex, $err) = &execute_command_on_server($server, 
		"uname -r ; uname -m ; uname -s");
	if (!$ex && !$err) {
		my ($r, $m, $o) = split(/\r?\n/, $out);
		$info->{'kernel'} = { 'version' => $r,
				      'arch' => $m,
				      'os' => $o };
		}
	}

# Get IO stats via SSH
if ($info->{'kernel'} && $info->{'kernel'}->{'os'} =~ /Linux/i) {
	my ($out, $ex, $err) = &execute_command_on_server($server,
							  "vmstat 1 2");
	if (!$ex && !$err) {
		local @lines = split(/\r?\n/, $out);
		local @w = split(/\s+/, $lines[$#lines]);
		shift(@w) if ($w[0] eq '');
		if ($w[8] =~ /^\d+$/ && $w[9] =~ /^\d+$/) {
			# Blocks in and out
			$info->{'io'} = [ $w[8], $w[9] ];

			# CPU user, kernel, idle, io, vm
			$info->{'cpu'} = [ @w[12..16] ];
			}
		}
	}

&save_server_collected($server, $info);

$rv = 1;

# Call any type-specific post-refresh function
DONECHECK:
my $rfunc = "type_".$server->{'manager'}."_post_refresh";
if (defined(&$rfunc)) {
	&$rfunc($server, $regen, $info);
	}

# Call any host-type-specific post-refresh function
foreach my $p (&is_parent_server($server)) {
	my $rfunc = "type_".$p."_post_host_refresh";
	if (defined(&$rfunc)) {
		&$rfunc($server, $regen, $info);
		}
	}

# Add disk usage, CPU and memory to historic stats, if we got them
&add_historic_collected_info($info, $time || $server->{'statustime'}, $server);

# Cache IP addresses, if we don't have them yet
if (!$server->{'ip_addresses'} || $regen) {
	&compute_ip_addresses($server);
	}

&release_lock_server($server);
return $rv;
}

# compute_ip_addresses(&server)
# Update's a server hash's ip_addresses field with IPs actually active
# on the system.
sub compute_ip_addresses
{
my ($server) = @_;
if ($server->{'status'} ne 'nohost') {
	my $cfunc = "type_".$server->{'manager'}."_can_interfaces";
	if (defined(&$cfunc) && &$cfunc($server)) {
		my $ifunc = "type_".$server->{'manager'}."_list_interfaces";
		my $ifaces = &$ifunc($server);
		if (ref($ifaces)) {
			$server->{'ip_addresses'} = join(" ",
				grep { !/^127\.0\./ }
				     map { $_->{'address'} } @$ifaces);
			}
		}
	}
}

# add_ip_address(&server, ip)
# Adds to the cached list of IP addresses
sub add_ip_address
{
my ($server, $ip) = @_;
$server->{'ip_addresses'} = join(" ",
	&unique(split(/\s+/, $server->{'ip_addresses'}), $ip));
}

# delete_ip_address(&server, ip)
# Removes from the cached list of IP addresses
sub delete_ip_address
{
my ($server, $ip) = @_;
$server->{'ip_addresses'} = join(" ",
	grep { $_ ne $ip } split(/\s+/, $server->{'ip_addresses'}));
}

# modify_primary_ip_address(&server, old-ip, new-ip)
# Update DNS, reverse DNS and on-host files when a primary IP is changed
sub modify_primary_ip_address
{
my ($server, $oldip, $newip) = @_;

# Fix DNS record
my $dfunc = "type_".$server->{'manager'}."_get_dns_name";
if (defined(&$dfunc)) {
	my ($dnsname, $zonename) = &$dfunc($server);
	if ($dnsname) {
		&modify_bind_dns_record($dnsname, $zonename, $oldip, $newip);
		}
	}

# Mount filesystem if needed
my $err = &mount_filesystem_if_needed($server);
return $err if ($err);

# Update /etc/hosts
my $temp = &transname();
my $err = &get_file_from_server($server, "/etc/hosts", $temp);
if (!$err) {
	my $lref = &read_file_lines($temp);
	foreach my $l (@$lref) {
		$l =~ s/^\Q$oldip\E\s/$newip /;
		}
	&flush_file_lines($temp);
	&put_file_to_server($server, $temp, "/etc/hosts");
	}
&unlink_file($temp);

# Un-mount if mounted before
&umount_filesystem_if_needed($server);
}

# modify_default_gateway(&server, gateway)
# Change the default gateway IP of a system. It is assumed that the gateway can
# be set in a network interface config.
sub modify_default_gateway
{
my ($server, $gw) = @_;

# Find first boot-time interface with a gateway, and change it
my $boots = &list_boot_server_interfaces($server);
if (ref($boots)) {
	my ($iface) = grep { $_->{'gateway'} } @$boots;
	if ($iface) {
		my $oldiface = { %$iface };
		$iface->{'gateway'} = $gw;
		my $err = &modify_boot_server_interface(
				$server, $iface, $oldiface);
		return $err if ($err);
		}
	}

# Updating routing table
if (&can_ssh_status($server)) {
	my ($out, $ex, $err) = &execute_command_on_server($server,
		"route delete default".
		($gw ? " ; route add default gw $gw" : ""));
	if ($ex || $err) {
		return "Failed to activate new gateway : ".($err || $out);
		}
	}

return undef;
}

# save_server_domains(&server, &domains)
# Writes out the list of domains hosted by some server
sub save_server_domains
{
my ($server, $doms) = @_;
if (!-d $server_domains_dir) {
	&make_dir($server_domains_dir, 0700);
	}
my $oldser = &read_file_contents("$server_domains_dir/$server->{'id'}");
my $newser = &serialise_variable($doms);
if ($oldser ne $newser) {
	&open_tempfile(DOMS, ">$server_domains_dir/$server->{'id'}");
	&print_tempfile(DOMS, $newser);
	&close_tempfile(DOMS);
	}
$get_server_domains_cache{$server->{'id'}} = $doms;
}

# get_server_domains(&server)
# Returns an array of domain objects from some server
sub get_server_domains
{
my ($server) = @_;
if (!$get_server_domains_cache{$server->{'id'}}) {
	my $ddata = &read_file_contents(
			"$server_domains_dir/$server->{'id'}");
	return ( ) if (!$ddata);	# Not collected yet?
	my $doms = &unserialise_variable($ddata);
	$get_server_domains_cache{$server->{'id'}} = $doms;
	}
return @{$get_server_domains_cache{$server->{'id'}}};
}

# save_server_collected(&server, &info)
# Writes out the status information collected from some server
sub save_server_collected
{
my ($server, $info) = @_;
if (!-d $server_collected_dir) {
	&make_dir($server_collected_dir, 0700);
	}
if ($info) {
	# Have info to write
	my $oldser = &read_file_contents(
		"$server_collected_dir/$server->{'id'}");
	my $newser = &serialise_variable($info);
	if ($oldser ne $newser) {
		&open_tempfile(DOMS, ">$server_collected_dir/$server->{'id'}");
		&print_tempfile(DOMS, $newser);
		&close_tempfile(DOMS);
		}
	$get_server_collected_cache{$server->{'id'}} = $info;
	}
else {
	# Info is being cleared
	&unlink_file("$server_collected_dir/$server->{'id'}");
	delete($get_server_collected_cache{$server->{'id'}});
	}
}

# get_server_collected(&server)
# Returns the hash ref of collected stats info from some server
sub get_server_collected
{
my ($server) = @_;
return $get_server_collected_cache{$server->{'id'}}
	if ($get_server_collected_cache{$server->{'id'}});
my $idata = &read_file_contents("$server_collected_dir/$server->{'id'}");
return undef if (!$idata);	# Not collected yet?
my $rv = &unserialise_variable($idata);
$get_server_collected_cache{$server->{'id'}} = $rv;
return $rv;
}

# find_suitable_server(&servers, "doms"|"space"|"cpu"|"mem")
# Finds a system for a new Virtualmin domain based on some criteria
sub find_suitable_server
{
my ($vservers, $mode) = @_;
my $server;
if ($mode eq "doms") {
	# Look for fewest domains
	my $min_domains;
	foreach my $s (@$vservers) {
		my @doms = &get_server_domains($s);
		if (scalar(@doms) < $min_domains || !$min_domains) {
			$min_domains = scalar(@doms);
			$server = $s;
			}
		}
	}
elsif ($mode eq "space") {
	# Look for most free disk space
	my $max_free;
	foreach my $s (@$vservers) {
		my $info = &get_server_collected($s);
		if ($info->{'disk_free'} > $max_free) {
			$max_free = $info->{'disk_free'};
			$server = $s;
			}
		}
	}
elsif ($mode eq "cpu") {
	# Look for lowest CPU load
	ny $min_load;
	foreach my $s (@$vservers) {
		my $info = &get_server_collected($s);
		if ($info->{'load'}->[0] < $min_load || !$min_load) {
			$min_load = $info->{'load'}->[0];
			$server = $s;
			}
		}
	}
elsif ($mode eq "mem") {
	# Look for highest free RAM
	my $max_free;
	foreach my $s (@$vservers) {
		my $info = &get_server_collected($s);
		if ($info->{'mem'}->[1] > $max_free) {
			$max_free = $info->{'mem'}->[1];
			$server = $s;
			}
		}
	}
return $server;
}

# parallel_server_function(&servers, &function, [&args])
# Calls some function on multiple servers, in 10 (by default) processes.
# Returns an array of the return values from the functions in those processes.
sub parallel_server_function
{
my ($servers, $func, $args) = @_;

# Build 10 buckets
my @buckets;
my $procs = $config{'procs'};
for(my $i=0; $i<@$servers; $i++) {
	push(@{$buckets[$i % $procs]}, $servers->[$i]);
	}

# Create results dir
my $resdir = &transname();
&make_dir($resdir, 0700);

# Fork 10 processes, each doing a bucket
my @pids;
for(my $i=0; $i<$procs; $i++) {
	my @bservers = @{$buckets[$i]};
	next if (!@bservers);
	if (!($pid = fork())) {
		foreach my $server (@bservers) {
			my @r = &$func($server, $args);
			&open_tempfile(RESULTS, ">$resdir/$server->{'id'}",0,1);
			&print_tempfile(RESULTS, &serialise_variable(\@r));
			&close_tempfile(RESULTS);
			}
		exit(0);
		}
	push(@pids, $pid);
	}

# Wait for them all
while(@pids) {
	my $pid = wait();
	@pids = grep { $_ ne $pid } @pids;
	}

# Read back result files, and return as list
my @rv;
foreach my $s (@$servers) {
	my $rvser = &read_file_contents("$resdir/$s->{'id'}");
	if ($rvser) {
		my $rv = &unserialise_variable($rvser);
		push(@rv, $rv);
		}
	else {
		push(@rv, undef);
		}
	}
return @rv;
}

# parallel_check_server_status(&servers, [re-generate], [skip-locked])
# Checks the status of multiple servers in 10 (by default) processes
sub parallel_check_server_status
{
my ($servers, $regen, $skiplock) = @_;
my $time = time();
return &parallel_server_function($servers,
	sub { if (!$skiplock || !&test_lock_server($_[0])) {
	        &check_server_status($_[0], $regen, 0, $time);
	        &save_managed_server($_[0]);
	        if (defined(&refresh_server_usage)) {
		  &refresh_server_usage($_[0], $time);
	        }
	      }
	      return ( $_[0]->{'status'}, $_[0]->{'status_msg'},
		       $_[0]->{'virtualmin_domains'},
		       $_[0]->{'virtualmin_error'} );
	    });
}

# parallel_install_package_updates(&servers, [&packages])
# Updates all packages on multiple servers, in 10 (by default) processes.
# Each element of the per-server return array is an hash ref with status,
# packages and error fields.
sub parallel_install_package_updates
{
my ($servers, $packages) = @_;
my %want;
if ($packages) {
	foreach my $p (@$packages) {
		$want{$p->{'name'},$p->{'system'}} = 1;
		}
	}
return &parallel_server_function($servers,
	sub { my ($server, $want) = @_;
	      my $info = &get_server_collected($server);
	      my @allgot;
	      @poss = @{$info->{'allposs'}};
	      @poss = @{$info->{'poss'}} if (!@poss);
	      if ($want) {
		# Limit to those requested
		@poss = grep { $want{$_->{'name'},$_->{'system'}} } @poss;
	      }
	      my %donedep;
	      foreach my $p (&sort_package_updates(@poss)) {
		  next if ($donedep{$p->{'name'}});
	          my $got = &install_package_update($_[0], $p);
		  my $status = { 'name' => $p->{'name'},
				 'version' => $p->{'version'} };
		  if (ref($got)) {
		    # Installed something
                    $status->{'status'} = 1;
                    $status->{'updates'} = $got;
		    foreach my $g (@$got) {
			$donedep{$g}++;
		        }
		    }
		  else {
		    # Install failed
                    $status->{'status'} = 0;
                    $status->{'error'} = $got;
                    }
                  push(@allgot, $status);
	          }
              &refresh_server_updates($_[0], \@allgot);
	      &check_server_status($_[0]);
	      &save_managed_server($_[0]);
              return @allgot;
	    }, $packages ? \%want : undef);
}

# refresh_server_updates(&server, &newly-gotten)
# Tell some server to refresh its list of installed packages
sub refresh_server_updates
{
my ($server, $got) = @_;
if ($server->{'status'} eq 'virt') {
	# Call Virtualmin collector function
	&remote_foreign_require($server, "virtual-server",
				"virtual-server-lib.pl");
	&remote_foreign_call($server, "virtual-server",
			     "refresh_possible_packages", $got);
	}
elsif ($server->{'status'} eq 'novirt') {
	# Call new Webmin collector function
	&remote_foreign_require($server, "system-status",
				"system-status-lib.pl");
	&remote_foreign_call($server, "system-status",
			     "refresh_possible_packages", $got);
	}
}

# domain_link(&server, &domain)
# Returns HTML for a link to edit a domain on some server
sub domain_link
{
my ($s, $d) = @_;
my $prot = $s->{'ssl'} ? 'https' : 'http';
my $target;
if ($s->{'id'} == 0) {
	# Link to Virtualmin on this server
	$url = "../virtual-server/edit_domain.cgi?dom=$d->{'id'}";
	}
else {
	# On another server
	my $info = &get_server_collected($s);
	my $path;
	if ($info->{'general'}->{'theme'} eq 'virtual-server-theme' &&
	    $info->{'general'}->{'tinfo'}->{'version'} >= 4.01) {
		# Can link using theme's domain display mode
		$path = "/?dom=$d->{'id'}";
		$target = "_new";
		}
	else {
		# Need to link to edit_domain.cgi
		$path = "/virtual-server/edit_domain.cgi?dom=$d->{'id'}";
		}
	if ($config{'link_mode'} == 1) {
		# Direct link
		$url = "$prot://$s->{'host'}:$s->{'port'}$path";
		}
	else {
		# Via servers module
		$url = "../servers/link.cgi/$s->{'id'}$path";
		}
	}
return "<a href='$url' ".($target ? "target=$target" : "").
       ">".&show_domain_name($d)."</a>";
}

sub webmin_link
{
my ($server) = @_;
my $prot = $server->{'ssl'} ? 'https' : 'http';
if ($config{'link_mode'} == 1) {
	return "$prot://$server->{'host'}:$server->{'port'}/";
	}
else {
	return "../servers/link.cgi/$server->{'id'}/";
	}
}

# call_virtualmin_api(&server, program, &args)
# Call a Virtualmin API program on some server, and return an error message and
# all the output. For this server, just run the .pl script directly.
sub call_virtualmin_api
{
my ($server, $prog, $args) = @_;
my ($out, $ex);

if ($server->{'id'} == 0) {
	# Local .. so we can just run the program
	my $mrd = &module_root_directory("virtual-server");
	my $cmd = "$mrd/$prog.pl";
	foreach my $a (@$args) {
		$cmd .= " --$a->[0]";
		if (defined($a->[1])) {
			$cmd .= " ".quotemeta($a->[1]);
			}
		}
	&clean_environment();
	$out = &backquote_logged("$cmd 2>&1 </dev/null");
	$ex = $?;
	&reset_environment();
	}
else {
	# Remote .. make HTTP call to Webmin
	my $path = "/virtual-server/remote.cgi?program=$prog";
	foreach my $a (@$args) {
		$path .= "&".&urlize($a->[0])."=".&urlize($a->[1]);
		}
	my $herr;
	&http_download($server->{'ip'}, $server->{'port'}, $path, \$out,
		       \$herr, undef, $server->{'ssl'}, $server->{'user'},
		       $server->{'pass'}, 60, 0, 1);
	if ($herr) {
		return ( $herr, undef );
		}
	if ($out =~ s/Exit\s+status:\s*(\d+)//) {
		$ex = $1;
		}
	else {
		$ex = -1;	# Invalid output??
		$out = "No output" if ($out !~ /\S/);
		}
	}

$out =~ s/\s+$//g;
if ($ex) {
	# Work out error message
	my @lines = grep { /\S/ } split(/\r?\n/, $out);
	my $err;
	if ($out =~ /usage:|\nvirtualmin\s/i) {
		# First line, before usage message
		$err = $lines[0];
		}
	else {
		# The whole error
		$err = $out;
		}
	return ( $err || "Unknown error", $out );
	}
else {
	return (undef, $out);
	}
}

sub get_server_blocksize
{
my ($server) = @_;
return 1024;	# Guess for now
}

# install_package_update(&server, &package)
# Installs an updated package on some system, and returns the array ref of new
# packages installed, or an error message
sub install_package_update
{
my ($server, $p) = @_;
$last_remote_error = undef;
my $mod = $server->{'status'} eq 'virt' ? 'security-updates'
					: 'package-updates';
my $pkg = $mod;
$pkg =~ s/-/_/g;
&remote_foreign_require($server, $mod, $mod."-lib.pl");
my $func = &remote_eval($server, $mod,
			   'defined(&capture_function_output_tempfile)') ?
				"capture_function_output_tempfile" :
				"capture_function_output";
my ($out, $rv) = &remote_foreign_call($server, $mod,
		$func, $pkg."::package_install",
		$p->{'update'} || $p->{'name'}, $p->{'system'}, 1);
if ($last_remote_error) {
	return $last_remote_error;
	}
elsif (ref($rv) && @$rv == 0 || $out =~ /install\s+failed/i) {
	return $out;
	}
else {
	return $rv;
	}
}

# show_confirm_form(message, cgi, &hiddens, ok-message, post-message)
# Prints a form for confirming some action
sub show_confirm_form
{
my ($msg, $cgi, $hiddens, $ok, $post) = @_;
print "<center>\n";
print &ui_form_start($cgi, "post");
foreach my $h (@$hiddens) {
	print &ui_hidden($h->[0], $h->[1]);
	}
print $msg,"<p>\n";
print &ui_form_end([ [ "confirm", $ok ] ]);
print $post,"<p>\n" if ($post);
print "</center>\n";
}

# shutdown_server(&server, [force])
# Remotely shut down some system. Returns undef on success, or an error
# message on failure.
sub shutdown_server
{
my ($server, $force) = @_;
my $sfunc = "type_".$server->{'manager'}."_shutdown";
if (defined(&$sfunc)) {
	# Type provides a shutdown function
	my $rv = &$sfunc($server, $force);
	return $rv if ($rv ne 'FALLBACK');
	}
if ($server->{'status'} eq 'virt' || $server->{'status'} eq 'novirt') {
	# Can use Webmin API call
	$last_remote_error = undef;
	&remote_foreign_require($server, "init", "init-lib.pl");
	my $iconfig = &remote_foreign_config($server, "init");
	&remote_foreign_call($server, "init", "execute_command",
	     $iconfig->{'shutdown_command'}." >/dev/null 2>&1 </dev/null &");
	return $last_remote_error if ($last_remote_error);
	}
else {
	# Need to try SSHing in
	my %iconfig = &foreign_config("init");
	my ($out, $ex, $err) = &execute_command_on_server($server,
		"($iconfig{'shutdown_command'} || shutdown now || ".
		"shutdown -i 5 -g 0 -y) >/dev/null 2>&1 </dev/null &");
	return $err if ($err);
	return $out if ($ex);
	}

# Wait for clean shutdown
my $tries = 0;
while($tries < 60) {
	my $p = &ping_server_host(&get_server_ip($server));
	if (!$p) {
		return undef;
		}
	sleep(1);
	$tries++;
	}
return "Failed to shut down after 60 seconds";
}

# reboot_server(&server)
# Remotely reboot some system. Returns undef on success, or an error
# message on failure.
sub reboot_server
{
my ($server) = @_;
my $rfunc = "type_".$server->{'manager'}."_reboot";
my $oldping = &ping_server_host(&get_server_ip($server));
if (defined(&$rfunc)) {
	# Type provides a reboot function
	my $rv = &$rfunc($server);
	return $rv if ($rv ne 'FALLBACK');
	}
if ($server->{'status'} eq 'virt' || $server->{'status'} eq 'novirt') {
	# Can use Webmin API call
	$last_remote_error = undef;
	&remote_foreign_require($server, "init", "init-lib.pl");
	my $iconfig = &remote_foreign_config($server, "init");
	&remote_foreign_call($server, "init", "execute_command",
			     $iconfig->{'reboot_command'});
	return $last_remote_error if ($last_remote_error);
	}
else {
	# Need to try SSHing in
	my %iconfig = &foreign_config("init");
	my ($out, $ex, $err) = &execute_command_on_server($server,
		"$iconfig{'reboot_command'} || shutdown -r now || reboot");
	return $err if ($err);
	return $out if ($ex);
	}

if ($oldping) {
	# Wait for a shutdown
	my $tries = 0;
	while($tries < 60) {
		my $p = &ping_server_host(&get_server_ip($server));
		last if (!$p);
		sleep(1);
		$tries++;
		}
	return "Failed to shut down after 60 seconds" if ($tries >= 60);

	# Wait for startup
	my $pinged = &wait_for_ping($server);
	my $sshed;
	if ($pinged) {
		$sshed = &wait_for_ssh($server);
		}
	return "Failed to start up after 60 seconds" if (!$sshed);
	}

return undef;
}

# startup_server(&server)
# Start up some virtual system by calling it's type-specific function.
# Returns a status code (0=failed, 1=OK, 2=No ping, 3=No SSH) and an error
# message.
sub startup_server
{
my ($server) = @_;
my $sfunc = "type_".$server->{'manager'}."_startup";
my ($ok, $err) = &$sfunc($server);
return ($ok, $err) if (!$ok);

# If the server has Webmin, wait for it to come up
if ($server->{'user'} && $ok != 2) {
	my $start = time();
	while(time() - $start < 60) {
		sleep(1);
		my $werr;
		alarm(5);
		eval {
			local $SIG{'ALRM'} = sub { die "timeout\n" };
			&open_socket($server->{'ip'},
				     $server->{'port'} || 10000,
				     WTEST, \$werr);
			};
		alarm(0);
		if (!$werr && !$@) {
			close(WTEST);
			last;
			}
		}
	}
return (1, undef);
}

sub server_in
{
my ($server) = @_;
return "<tt>$server->{'host'}</tt>";
}

# get_install_webmin_source(&server)
# Works out where to install Webmin from on some server, based on it's support
# for RPM or Debian packages.
sub get_install_webmin_source
{
my ($server) = @_;
my $type;

# Check what package system the host uses
my ($type, $update, $os) = &get_server_package_system($server);
if (!$type || $type eq "pkgadd") {
	# Don't use Solaris package of Webmin, as upgrading sucks
	$type = "tgz";
	}

# Work out download URL
my $source = $update eq "yum" || $update eq "apt" ? $update :
		$config{'download_'.$type} || $webmin_download_source{$type};
return ($source, $type, undef);
}

# install_webmin_server(&server, src, type, set-password)
# Attempt to install Webmin on some system, from the given source and type.
# Returns the output and an error message on failure.
sub install_webmin_server
{
my ($server, $src, $type, $setpass) = @_;
my ($out, $ex, $err);
$src =~ /\/([^\/]+)$/;
my $temp = "/tmp/$1";
my $rootdir;

# Try to install Perl and other dependencies
if (!&has_command_on_server($server, "perl") ||
    !&has_command_on_server($server, "wget")) {
	my ($pstatus, $pout) = &install_package_on_server($server,
							     "perl", "wget");
	if (!$pstatus && $pout) {
		return ($pout, "Failed to install required packages");
		}
	elsif (!$pstatus) {
		return (undef, "Perl and Wget are required to install Webmin, but cannot be automatically installed");
		}
	}

# Make sure the system has Perl
my $perlpath = &has_command_on_server($server, "perl");
$perlpath || return (undef, "Perl is not installed");

# Upload Webmin public key if needed
my $keytemp = &tempname_on_server($server, "jcameron-key.asc");
if ($src eq "yum" || $src eq "apt") {
	my $err = &put_file_to_server($server,
			"$module_root_directory/jcameron-key.asc",
			$keytemp);
	if ($err) {
		return (undef, "Failed to upload Webmin public key : $err");
		}
	}

if ($type eq "rpm" && $src eq "yum") {
	# RPM install using Webmin YUM repository
	my $err = &put_file_to_server($server,
			"$module_root_directory/webmin.repo",
			"/etc/yum.repos.d/webmin.repo");
	if ($err) {
		return (undef, "Failed to create webmin.repo : $err");
		}
	&execute_command_on_server($server, "rpm --import $keytemp");
	my ($wout, $wex, $werr) = &execute_command_on_server($server,
					"yum -y install webmin");
	return (undef, $werr) if ($werr);
	return (undef, "YUM failed : $wout") if ($wex);
	$rootdir = "/usr/libexec/webmin";
	$out .= $wout;
	}

elsif ($type eq "rpm") {
	# RPM install direct from the URL
	my ($wout, $wex, $werr) = &execute_command_on_server($server,
		"rm -f $temp && wget -nv -O $temp $src && rpm -U --nodeps $temp && rm -f $temp");
	return (undef, $werr) if ($werr);
	return ($wout, "RPM failed") if ($wex);
	$rootdir = "/usr/libexec/webmin";
	$out .= $wout;
	}

elsif ($type eq "dpkg" && $src eq "apt") {
	# APT install using Webmin repository
	my $temp = &transname();
	my $err = &get_file_from_server($server, "/etc/apt/sources.list",$temp);
	if ($err) {
		return (undef, "Failed to fetch sources.list : $err");
		}
	my $srcs_lref = &read_file_lines($temp);
	my $webmin_lref = &read_file_lines(
				"$module_root_directory/webmin.source", 1);
	my $found;
	foreach my $l (@$srcs_lref) {
		if ($l eq $webmin_lref->[0]) {
			$found++;
			}
		}
	if (!$found) {
		push(@$srcs_lref, @$webmin_lref);
		&flush_file_lines($temp);
		my $err = &put_file_to_server($server, $temp,
					      "/etc/apt/sources.list");
		if ($err) {
			return (undef, "Failed to save sources.list : $err");
			}
		&execute_command_on_server($server, "apt-get update");
		}
	else {
		&unflush_file_lines($temp);
		}

	# Now call apt-get to do the install
	&execute_command_on_server($server, "apt-get add $keytemp");
	my ($wout, $wex, $werr) = &execute_command_on_server($server,
				"apt-get -y --force-yes -f install webmin");
	return (undef, $werr) if ($werr);
	return (undef, "APT failed : $wout") if ($wex);
	$rootdir = "/usr/libexec/webmin";
	$out .= $wout;
	}

elsif ($type eq "dpkg") {
	# Download the deb and install it
	my ($wout, $wex, $werr) = &execute_command_on_server($server,
		"rm -f $temp && wget -nv -O $temp $src && dpkg --install --force-depends $temp && rm -f $temp");
	return (undef, $werr) if ($werr);
	return ($wout, "Debian package failed") if ($wex);
	$rootdir = "/usr/share/webmin";
	$out .= $wout;

	# Satisfy any Debian dependencies created by Webmin, if possible
	my ($dout, $dex, $derr) = &execute_command_on_server($server,
		"apt-get update ; apt-get -y -f --force-yes install </dev/null | cat");
	if (!$dex) {
		$out .= $dout;
		}
	}

elsif ($type eq "tgz" || $type eq "pkgadd") {
	# Download the tgz file, then run setup.sh. If we know the SSH
	# password, we can configure Webmin to use it .. otherwise, the 
	# password will be set later in the function.
	$server->{'user'} = 'root';
	my $crypt = $server->{'ssh_pass'} ? 'x' : 'fixlater';
	my $basedir = $server->{'manager'} eq 'zones' ? "/opt"
							 : "/usr/local";
	$rootdir = "$basedir/webmin";
	my ($wout, $wex, $werr) = &execute_command_on_server($server,
	    "wget -nv -O $temp $src && mkdir -p $basedir && cd $basedir && gunzip -c $temp | tar xf - && echo webmin-*/version && rm -f $temp");
	return (undef, $werr) if ($werr);
	return ($wout, "Tar file download or extraction failed") if ($wex);
	my $tardir;
	if ($wout =~ /(webmin-([0-9\.]+))\/version/) {
		$tardir = $1;
		}
	else {
		return ($wout, "Tar extraction failed");
		}
	my ($wout, $wex, $werr) = &execute_command_on_server($server,
		"config_dir=/etc/webmin var_dir=/var/webmin perl=$perlpath autoos=3 port=10000 login=root crypt=$crypt ssl=0 atboot=1 $basedir/$tardir/setup.sh $rootdir </dev/null");
	&execute_command_on_server($server, "rm -rf $basedir/$tardir");
	return (undef, $werr) if ($werr);
	return ($wout, "Setup script failed") if ($wex);
	$out .= $wout;
	}

else {
	return (undef, "Unknown package type $type");
	}

# Get details of the new Webmin
my ($sshstatus, $ssherr, $wroot, $wport, $wssl) =
	&check_server_ssh_login($server);
$server->{'port'} = $wport || 10000;
$server->{'ssl'} = $wssl;

# Set the Webmin password, if we don't have it
if ($setpass) {
	$server->{'user'} = 'root';
	if ($server->{'ssh_pass'}) {
		# Root and Webmin passwords are the same
		$server->{'pass'} = $server->{'ssh_pass'};
		$server->{'ssh_pass_same'} = 1;
		}
	else {
		# Need to set, since RPM and Deb installs by default use the
		# real root password, which we don't know
		$server->{'pass'} ||= &generate_random_password();
		my $perr = &set_server_webmin_password(
				$server, $rootdir, "root", $server->{'pass'});
		if ($perr) {
			$out .= "\nFailed to set Webmin password : $perr\n";
			}
		}
	}

# Call type-specific post configuration function
my $wfunc = "type_".$server->{'manager'}."_post_webmin";
if (defined(&$wfunc)) {
	&$wfunc($server, $wroot, $wport, $wssl);
	}

&enable_webmin_status_collection($server);

# Make sure Webmin is running OK, and get the OS
my ($wstatus, $werr, $wos, $wrealos) = &check_server_webmin_login($server);
if ($wstatus == 0) {
	$server->{'type'} = &os_to_server_type($wos, $wrealos);
	}
else {
	# Argh .. could not connect after all that work :(
	$out .= "\nWebmin installed, but could not connect : $werr\n";
	}

return ($out, undef, $wroot);
}

# enable_webmin_status_collection(&server)
# If possible, configure a system with Webmin to collect status info via
# a background cron job
sub enable_webmin_status_collection
{
my ($server) = @_;
my @st = &stat_file_on_server($server,
		"/etc/webmin/system-status/enable-collection.pl");
if (!@st) {
	return "Webmin version 1.491 or later is required";
	}
my ($out, $ex, $err) = &execute_command_on_server($server,
	"/etc/webmin/system-status/enable-collection.pl 5");
if (!$ex && !$err) {
	($out, $ex, $err) = &execute_command_on_server($server,
		"/etc/webmin/system-status/systeminfo.pl");
	}
return $err ? $err : $ex ? $out : undef;
}

# wait_webmin_server(&server, timeout)
# Wait for Webmin to start accepting connections on some server. Returns undef
# if OK, or the last error message on timeout.
sub wait_webmin_server
{
my ($server, $timeout) = @_;
my $start = time();
my $err;
while(time() - $start < $timeout) {
	my $fh = "WEBMINSOCK";
	if (&open_socket($server->{'ip'}, $server->{'port'}, $fh, \$err)) {
		close($fh);
		return undef;
		}
	sleep(1);
	}
return $err;
}

sub generate_random_password
{
&seed_random();
my $pass;
while(length($pass) < 8) {
	$pass .= chr(int(rand()*26)+97);
	}
return $pass;
}

# set_server_webmin_password(&server, webminroot, user, pass)
# Change the Webmin password on some server
sub set_server_webmin_password
{
my ($server, $webmindir, $user, $pass) = @_;
my ($pout, $pex, $perr) = &execute_command_on_server($server,
	"$webmindir/changepass.pl /etc/webmin $user ".quotemeta($pass));
return $perr ? $perr : $pex ? $pout : undef;
}

# set_server_webmin_password_crypt(&server, user, crypted)
# Sets the password for some user in Webmin to an encrypted string
sub set_server_webmin_password_crypt
{
my ($server, $user, $crypted) = @_;

# Get the miniserv.users file
my $passfile = "/etc/webmin/miniserv.users";
my $temp = &transname();
my $err = &get_file_from_server($server, $passfile, $temp);
return $err if ($err);

# Patch the line for the user
my $found;
my $lref = &read_file_lines($temp);
foreach my $l (@$lref) {
	my @w = split(/:/, $l);
	if ($w[0] eq $user) {
		$w[1] = $crypted;
		$l = join(':', @w);
		$found = 1;
		}
	}
&flush_file_lines($temp);
$found || return "Webmin user $user does not exist";

# Upload to server
my $err = &put_file_to_server($server, $temp, $passfile);
return $err if ($err);

# Update Webmin to apply the change
if ($server->{'status'} eq 'virt' ||
    $server->{'status'} eq 'novirt' ||
    $server->{'status'} eq 'nowebminlogin') {
	my ($out, $ex, $err) = &execute_command_on_server($server,
		"kill -USR1 `cat /var/webmin/miniserv.pid`");
	return $err if ($err);
	return "Failed to reload Webmin : $out" if ($ex);
	}

return undef;
}

# find_server_dependencies(&server, ...)
# Returns a list of other servers that depend on this one
sub find_server_dependencies
{
my @allservers = &list_managed_servers();
my @rv;
foreach my $server (@_) {
	foreach my $t (@server_management_types) {
		my $dfunc = "type_".$t."_depends";
		if (defined(&$dfunc)) {
			push(@rv, grep { local $_;
					 $_->{'id'} != $server->{'id'} &&
					 &$dfunc($server, $_) } @allservers);
			}
		}
	}
return @rv;
}

# allocate_ip_address(start-ips, end-ips, cidrs, [gateways, ifaces, want-iface])
# Returns an IP address from the given range that is not in use or pingable,
# and a CIDR. If not IP could be allocated, returns undef.
sub allocate_ip_address
{
my ($startips, $endips, $cidrs, $gws, $ifaces, $wantiface) = @_;
my @startips = split(/\s+/, $startips);
my @endips = split(/\s+/, $endips);
my @cidrs = split(/\s+/, $cidrs);
my @gws = split(/\s+/, $gws);
my @ifaces = split(/\s+/, $ifaces);
my %used = &used_ip_addresses();

# Find out which IPs we might be able to use
my @poss;
for(my $i=0; $i<@startips; $i++) {
	# If this range is for some host system interface, skip if we aren't
	# allocating for that interface
	next if ($wantiface && $ifaces[$i] ne $wantiface &&
		 $ifaces[$i] ne '' && $ifaces[$i] ne '*');

	# Split into sub-ranges
	my @sub_startips = split(/,/, $startips[$i]);
	my @sub_endips = split(/,/, $endips[$i]);
	my @sub_cidrs = split(/,/, $cidrs[$i]);
	my @sub_gws = split(/,/, $gws[$i]);
	for(my $j=0; $j<@sub_startips; $j++) {
		# Try each IP within the range
		my $start = &net::ip_to_integer($sub_startips[$j]);
		my $end = &net::ip_to_integer($sub_endips[$j]);
		for(my $n=$start; $n<=$end; $n++) {
			my $ip = &net::integer_to_ip($n);
			push(@poss, { 'id' => $ip,
				      'ip' => $ip,
				      'cidr' => $sub_cidrs[$j],
				      'gw' => $sub_gws[$j] })
				if (!$used{$ip});
			}
		}
	}

# Parallel ping them all
my @rvs = grep { $_ } map { $_->[0] } &parallel_server_function(\@poss, 
	sub { my $p = &ping_server_host($_[0]->{'ip'});
	      return $p ? undef : $_[0] });
@rvs = sort { &net::ip_to_integer($a->{'ip'}) <=>
	      &net::ip_to_integer($b->{'ip'}) } @rvs;
return @rvs ? ( $rvs[0]->{'ip'}, $rvs[0]->{'cidr'}, $rvs[0]->{'gw'} ) : ( );
}

# range_check_ip_address(ip, start-ips, end-ips, cidrs,
# 			 [gateways, ifaces, want-iface])
# Returns 1 if some IP is within the given ranges
sub range_check_ip_address
{
my ($ip, $startips, $endips, $cidrs, $gws, $ifaces, $wantiface) = @_;
my @startips = split(/\s+/, $startips);
my @endips = split(/\s+/, $endips);
my @cidrs = split(/\s+/, $cidrs);
my @gws = split(/\s+/, $gws);
my @ifaces = split(/\s+/, $ifaces);

for(my $i=0; $i<@startips; $i++) {
	# If this range is for some host system interface, skip if we aren't
	# allocating for that interface
	next if ($wantiface && $ifaces[$i] ne $wantiface &&
		 $ifaces[$i] ne '' && $ifaces[$i] ne '*');

	# Check if the IP falls within any sub-range
	my @sub_startips = split(/,/, $startips[$i]);
	my @sub_endips = split(/,/, $endips[$i]);
	for(my $j=0; $j<@sub_startips; $j++) {
		my $start = &net::ip_to_integer($sub_startips[$j]);
		my $end = &net::ip_to_integer($sub_endips[$j]);
		for(my $n=$start; $n<=$end; $n++) {
			my $rip = &net::integer_to_ip($n);
			if ($rip eq $ip) {
				return 1;
				}
			}
		}
	}
return 0;
}

# get_ip_range_usage(start, end)
# Returns the number of IPs and the number used in some range
sub get_ip_range_usage
{
my ($startip, $endip) = @_;
my ($count, $used) = (0, 0);
my $start = &net::ip_to_integer($startip);
my $end = &net::ip_to_integer($endip);
my %used = &used_ip_addresses();
for(my $n=$start; $n<=$end; $n++) {
	my $ip = &net::integer_to_ip($n);
	$count++;
	if ($used{$ip}) {
		$used++;
		}
	}
return ($count, $used);
}

# describe_ip_range(start-ips, end-ips, cidrs, [ifaces, want-iface])
# Turns space-separated strings of ranges into a nicer format
sub describe_ip_range
{
my ($startips, $endips, $cidrs, $ifaces, $wantiface) = @_;
my @startips = split(/\s+/, $startips);
my @endips = split(/\s+/, $endips);
my @ifaces = split(/\s+/, $ifaces);
my @rv;
for(my $i=0; $i<@startips; $i++) {
	# Remove from description IP ranges for interfaces we don't care about
	next if ($wantiface && $ifaces[$i] ne $wantiface &&
		 $ifaces[$i] ne '' && $ifaces[$i] ne '*');

	# Split into sub-ranges
	my @sub_startips = split(/,/, $startips[$i]);
	my @sub_endips = split(/,/, $endips[$i]);
	for(my $j=0; $j<@sub_startips; $j++) {
		if ($sub_startips[$j] eq $sub_endips[$j]) {
			push(@rv, $sub_startips[$j]);
			}
		else {
			my @so = split(/\./, $sub_startips[$j]);
			my @eo = split(/\./, $sub_endips[$j]);
			if ($so[0] == $eo[0] && $so[1] == $eo[1] &&
			    $so[2] == $eo[2]) {
				push(@rv, "$so[0].$so[1].$so[2].$so[3]-$eo[3]");
				}
			else {
				push(@rv, $sub_startips[$j]."-".
					  $sub_endips[$j]);
				}
			}
		if ($j == 1 && @sub_startips > 2) {
			# Only show 2 IPs
			push(@rv, "...");
			last;
			}
		}
	}
return join(", ", @rv);
}

# used_ip_addresses()
# Returns a hash of all IP addresses used by managed systems
sub used_ip_addresses
{
my %used;
foreach my $s (&list_managed_servers()) {
	# Add IPs from VPS
	$used{&to_ipaddress($s->{'host'})} = $s;
	$used{$s->{'ip'}} = $s;
	foreach my $ip (split(/\s+/, $s->{'ip_addresses'})) {
		$used{$ip}++;
		}

	# Add IPs from last collected from Virtualmin
	my $coll = &get_server_collected($s);
	if ($coll && $coll->{'ifaces'}) {
		foreach my $iface (@{$coll->{'ifaces'}}) {
			if ($iface->{'address'}) {
				$used{$iface->{'address'}} = $s;
				}
			}
		}
	}
return %used;
}

# get_server_package_system(&server)
# Checks which package system a server uses. Returns :
#  Package system, such as dpkg or rpm
#  Update system, such as apt or yum
#  Short OS code, such as redhat, fedora, debian or ubuntu
# This is taken from Webmin if available, SSH if not.
sub get_server_package_system
{
my ($server) = @_;
my ($pkg, $update, $os);
my $cache = $server_package_system_cache{$server->{'id'}};
if ($cache) {
	# Use last checked values
	return @$cache;
	}
if ($server->{'pass'} && gethostbyname($server->{'host'})) {
	# Ask Webmin first
	$last_remote_error = undef;
	&remote_foreign_require($server, "software", "software-lib.pl");
	if (!$last_remote_error) {
		($pkg, $update) = &remote_eval($server, "software",
		    "(\$config{'package_system'}, \$update_system)");
		$os = $server->{'type'};
		}
	}
if (!$pkg || !$update) {
	# No luck .. check what commands it has
	foreach my $cmd ("dpkg", "rpm", "pkgadd") {
		if (&has_command_on_server($server, $cmd)) {
			$pkg = $cmd;
			last;
			}
		}
	foreach my $cmd ("apt-get", "yum", "up2date", "pkg-get") {
		if (&has_command_on_server($server, $cmd)) {
			$update = $cmd eq "up2date" ? "rhn" :
				  $cmd eq "pkg-get" ? "csw" :
				  $cmd eq "apt-get" ? "apt" : $cmd;
			last;
			}
		}
	}
if ((!$os || $os eq 'unknown') && $server->{'manager'} eq 'zones') {
	# Zones are always Solaris
	$os = "solaris";
	}
if ((!$os || $os eq 'unknown') && $pkg eq "pkgadd") {
	# Only Solaris has pkgadd
	my ($out, $ex, $err) = &execute_command_on_server($server,
		"uname -s");
	if ($out =~ /SunOS|Solaris/i) {
		$os = "solaris";
		}
	}
if (!$os || $os eq 'unknown') {
	# Could not get OS, so check useful system files
	# XXX this should really be done with os_list.txt
	my ($out, $ex, $err) = &execute_command_on_server($server,
	    "(ls /etc/fedora-release /etc/redhat-release /etc/mandrake-release /etc/SuSE-release) 2>/dev/null");
	if ($out =~ /fedora-release/) {
		$os = "fedora";
		}
	elsif ($out =~ /redhat-release/) {
		# Might be redhat or centos
		($out, $ex, $err) = &execute_command_on_server($server,
			"cat /etc/redhat-release");
		if ($out =~ /CentOS/i) {
			$os = "centos";
			}
		else {
			$os = "redhat";
			}
		}
	elsif ($out =~ /mandrake-release/) {
		$os = "mandrake";
		}
	elsif ($out =~ /SuSE-release/) {
		$os = "suse";
		}
	else {
		# Might be Debian or Ubuntu
		($out, $ex, $err) = &execute_command_on_server($server,
			"cat /etc/issue");
		if ($out =~ /Ubuntu/) {
			$os = "ubuntu";
			}
		else {
			$os = "debian";
			}
		}
	}
$server_package_system_cache{$server->{'id'}} = [ $pkg, $update, $os ];
return ($pkg, $update, $os);
}

# install_package_on_server(&server, package, ...)
# Installs some named package on a server. The name can be an actual package
# as recognized by the OS, or a generic known to the update service known
# to Webmin. Returns a status code (0 if failed, 1 if OK) and the output/error.
sub install_package_on_server
{
my ($server, @names) = @_;
my ($pkg, $update, $os) = &get_server_package_system($server);

# Try to use the software module to resolve names
my $lib = &module_root_directory("software")."/".$update."-lib.pl";
if (-r $lib) {
	if (!$done_require{$lib}++) {
		require $lib;
		}
	if (defined(&update_system_resolve)) {
		my @newnames;
		foreach my $n (@names) {
			push(@newnames,
			     split(/\s+/, &update_system_resolve($n)));
			}
		@names = @newnames;
		}
	}

my $names = join(" ", map { quotemeta($_) } @names);
if ($update eq "apt") {
	# Use apt-get
	&execute_command_on_server($server, "apt-get update");
	my ($pout, $pex, $perr) = &execute_command_on_server(
		$server, "apt-get -y -f --force-yes install $names </dev/null | cat");
	return $pex ? (0, $pout) : $perr ? (0, $perr) : (1, $pout);
	}
elsif ($update eq "yum") {
	# Use YUM
	my ($pout, $pex, $perr) = &execute_command_on_server(
		$server, "yum -y install $names </dev/null");
	return $pex ? (0, $pout) : $perr ? (0, $perr) : (1, $pout);
	}
elsif ($update eq "csw") {
	# Use blastwave, in full auto mode
	&execute_command_on_server(
	    $server, "cp -p /var/pkg-get/admin /var/pkg-get/admin-old");
	&execute_command_on_server(
	    $server, "cp -p /var/pkg-get/admin-fullauto /var/pkg-get/admin");
	my ($pout, $pex, $perr) = &execute_command_on_server(
		$server, "pkg-get -i $names </dev/null");
	&execute_command_on_server(
	    $server, "cp -p /var/pkg-get/admin-old /var/pkg-get/admin");
	return $pex ? (0, $pout) : $perr ? (0, $perr) : (1, $pout);
	}
else {
	# Don't know how
	return (0, undef);
	}
}

# install_virtualmin_server(&server, set-password, serial, key)
# Starts the process of installing Virtualmin, by copying over the install
# script and running it. Returns undef if start OK, or an error message on
# failure.
sub install_virtualmin_server
{
my ($server, $setpass, $serial, $key) = @_;

# Check for a supported OS
my ($pkg, $update, $os) = &get_server_package_system($server);
if ($pkg ne "rpm" && $pkg ne "dpkg" && $pkg ne "pkgadd") {
	return $text{'virtualmin_epkg'};
	}
if ($update ne "apt" && $update ne "yum" && $update ne "up2date" &&
    $os ne "solaris") {
	return $text{'virtualmin_eupdate'};
	}
if (!$os || $os eq "unknown") {
	return $text{'virtualmin_eos'};
	}
if (&indexof($os, @virtualmin_operating_systems) < 0) {
	my ($osinfo) = grep { $_->[0] eq $os } @servers::server_types;
	foreach my $s (@virtualmin_operating_systems) {
		my ($sosinfo) = grep { $_->[0] eq $s }
					@servers::server_types;
		push(@supp, $sosinfo->[1]);
		}
	return &text('virtualmin_eos2', $osinfo->[1], join(", ", @supp));
	}

if (!$serial) {
	return $text{'virtualmin_elicence'};
	}

# Download the installer
my $itemp = &transname("virtualmin-install.sh");
my $error;
&http_download($virtualmin_licence_host,
	       $virtualmin_licence_port,
	       $serial eq "GPL" && $os eq "solaris" ?
		$virtualmin_gpl_solaris_installer_path :
	       $serial eq "GPL" ?
		$virtualmin_gpl_installer_path :
	       $os eq "solaris" ?
		"$virtualmin_solaris_installer_prog?serial=$serial;key=$key" :
		"$virtualmin_installer_prog?serial=$serial;key=$key",
	       $itemp, \$error, undef, $virtualmin_licence_ssl);
if ($error) {
	return &text('virtualmin_einstaller', $error);
	}
&set_ownership_permissions(undef, undef, 0755, $itemp);

# Transfer over the install script
my $script = "/virtualmin-install.sh";
my $err = &put_file_to_server($server, $itemp, $script);
unlink($itemp);
return &text('virtualmin_ecopy', $err) if ($err);

# Call type-specific pre function
my $pfunc = "type_".$server->{'manager'}."_pre_virtualmin";
if (defined(&$pfunc)) {
	my $err = &$pfunc($server, $pkg, $update, $os, $script);
	return $err if ($err);
	}

# Install perl, wget and fuser, if needed
if (!&has_command_on_server($server, "wget")) {
	my ($wok, $werr) = &install_package_on_server($server, "wget");
	if (!$wok) {
		return $werr ? &text('virtualmin_ewget', $werr, "wget") :
			       $text{'virtualmin_ewget2', "wget"};
		}
	}
if (!&has_command_on_server($server, "perl")) {
	my ($wok, $werr) = &install_package_on_server($server, "perl");
	if (!$wok) {
		return $werr ? &text('virtualmin_ewget', $werr, "perl") :
			       $text{'virtualmin_ewget2', "perl"};
		}
	}
if (!&has_command_on_server($server, "fuser")) {
	my ($wok, $werr) = &install_package_on_server($server, "psmisc");
	if (!$wok) {
		return $werr ? &text('virtualmin_ewget', $werr, "wget") :
			       $text{'virtualmin_ewget2', "wget"};
		}
	}

# Run the install script, capturing output to a file
my $temp = "/tmp/virtualmin-install.out";
$server->{'virtualmin_temp'} = $temp;
my ($out, $ex, $err) = &execute_command_on_server($server,
	"chmod +x $script ; ((echo y ; echo $server->{'host'}) | $script && echo SERVER-MANAGER-COMPLETE) >$temp 2>&1 &");

return undef;
}

# install_virtualmin_server_done(&server)
# Checks the status of the Virtualmin install one some server. Returns OK
# when done, undef if still waiting, or an error message on failure.
sub install_virtualmin_server_done
{
my ($server) = @_;

# Check if the installer is still running
my $temp = $server->{'virtualmin_temp'};
my ($out) = &execute_command_on_server($server, "fuser $temp");
my @pids;
while($out =~ /(\d+)(.*)/) {
	push(@pids, $1);
	$out = $2;
	}
if (@pids) {
	# Yes .. try again later
	return undef;
	}

# Remove the install script
my $script = "/virtualmin-install.sh";
&execute_command_on_server($server, "rm -f ".quotemeta($script));

# Done .. but did it work?
my ($tout, $tex, $terr) = &execute_command_on_server($server,
				"tail -20 $temp ; rm -f $temp");
if ($tout !~ s/SERVER-MANAGER-COMPLETE//) {
	# Looks like it didn't ..
	return "<pre>".&html_escape($tout)."</pre>";
	}

# Make sure it REALLY got installed, by looking for Webmin
my ($sstatus, $serr, $webminroot, $webminport, $webminssl) =
	&check_server_ssh_login($server);
if (!$webminroot) {
	return "<pre>".&html_escape($tout)."</pre>";
	}
$server->{'port'} = $webminport;
$server->{'ssl'} = $webminssl;

# And check for Virtualmin root
my ($out, $ex, $err) = &execute_command_on_server($server,
				"cat $webminroot/virtual-server/module.info");
if ($ex) {
	return $text{'virtual_evirtualmincheck'};
	}

# Set Webmin password, if we don't have the SSH password
$server->{'user'} = 'root';
if ($server->{'ssh_pass'}) {
	$server->{'pass'} = $server->{'ssh_pass'};
	$server->{'ssh_pass_same'} = 1;
	}
else {
	$server->{'pass'} ||= &generate_random_password();
	my $perr = &set_server_webmin_password(
			$server, $webminroot, "root", $server->{'pass'});
	if ($perr) {
		return &text('virtualmin_epass', $perr);
		}
	}

# At end, do a config check
&remote_foreign_require($server, "virtual-server", "virtual-server-lib.pl");
my $cerr = &remote_foreign_call($server, "virtual-server",
				   "check_virtual_server_config");
if ($cerr) {
	$server->{'virtualmin_checked'} = 0;
	$server->{'virtualmin_error'} = 1;
	}
else {
	$server->{'virtualmin_checked'} = 1;
	}

# Call type-specific post function
my $pfunc = "type_".$server->{'manager'}."_post_virtualmin";
if (defined(&$pfunc)) {
	my $perr = &$pfunc($server, $pkg, $update, $os);
	return $perr if ($perr);
	}

return "OK";
}

# licence_error_message()
# Returns a message about a system's license, if needed
sub licence_error_message
{
my ($lstatus, $lexpiry, $lerr, $lservers) = &check_server_manager_licence();
return undef if (!$lerr);
my $rv = "<table width=100%><tr bgcolor=#ff8888><td align=center>";
$rv .= "<b>".$text{'licence_err'}."</b><br>\n";
$rv .= $lerr."\n";
if (&can_licence()) {
	$rv .= &ui_form_start("/$module_name/licence.cgi");
	$rv .= &ui_submit($text{'licence_recheck'});
	$rv .= &ui_form_end();
	}
$rv .= "</td></tr></table>\n";
return $rv;
}

# warning_messages()
# Returns HTML for any warnings
sub warning_messages
{
my $warns = &licence_error_message();
if (&is_cloudmin_replica()) {
	my $rv = "<table width=100%><tr bgcolor=#ffff88><td align=center>";
	my $master = &get_replication_master();
	$rv .= "<p><b>".($master ? &text('repl_warning', $master)
				 : $text{'repl_warning2'})."</b><p>\n";
	$rv .= "</td></tr></table>\n";
	$warns .= $rv;
	}
return $warns;
}

# check_server_manager_licence()
# Checks the licence for this module, by looking for a file with the
# licence flag set. In this function, the status from the most recent check
# from Cron is used.
sub check_server_manager_licence
{
my %licence;
return ( ) if (!$cloudmin_pro);
&read_file_cached($licence_status, \%licence);
if (time() - $licence{'last'} > 3*24*60*60) {
	# Hasn't been checked from cron for 3 days .. do it now
	&update_server_manager_licence(\%licence);
	&write_file($licence_status, \%licence);
	}
return ($licence{'status'}, $licence{'expiry'},
        $licence{'err'}, $licence{'servers'});
}

# get_host_id()
# Returns a unique host ID for this system, based on the CPU, MAC address or
# hostname.
sub get_host_id
{
my $id;
if (&has_command("hostid")) {
	chop($id = `hostid 2>/dev/null`);
	}
if (!$id) {
	my ($iface) = grep { $_->{'fullname'} eq $config{'iface'} }
			      &net::active_interfaces();
	$id = $iface->{'ether'} if ($iface);
	}
if (!$id) {
	$id = &get_system_hostname();
	}
return $id;
}

# update_server_manager_licence(&licence)
# Checks the licence file, and tries to phone home
sub update_server_manager_licence
{
my ($licence) = @_;
$licence->{'expiry'} = undef;
$licence->{'servers'} = 0;
$licence->{'last'} = time();
if (!$cloudmin_pro) {
	# Free version, no check needed
	$licence->{'status'} = 0;
	return;
	}

# Do we have a licence file?
my ($serial, $key) = &get_server_manager_serial();
if (!$serial || !$key) {
	# No!
	$licence->{'status'} = 1;
	$licence->{'err'} = $text{'licence_efile'};
	return;
	}

# Work out a host ID, from the hostid command or MAC address or hostname
my $id = &get_host_id();

# Phone home to see if it is valid
my ($status, $err, $expiry, $servers) =
	&licence_scheduled($id, $serial, $key);
$licence->{'status'} = $status;
$licence->{'err'} = $err;
if ($status == 0) {
	$licence->{'expiry'} = $expiry;
	$licence->{'servers'} = $servers;
	}
}

# licence_scheduled(id, serial, key)
# Actually check a serial number and get with the Virtualmin license server.
# Returns the status code, error message, expiry date and max servers
sub licence_scheduled
{
my ($id, $serial, $key) = @_;
my ($out, $error);
&http_download($virtualmin_licence_host,
	       $virtualmin_licence_port,
	       "$vm2_licence_prog?id=$id&serial=$key",
	       \$out, \$error, undef, $virtualmin_licence_ssl);
if ($error) {
	return (2, "Failed to contact licence server : $error");
	}
elsif ($out =~ /^EXP\s+(\S+)\s+(\S+)/) {
	return (3, "The licence for this system expired on $1");
	}
elsif ($out =~ /^ERR\s+(.*)/) {
	return (2, "An error occurred checking the licence : $1");
	}
elsif ($out =~ /^OK\s+(\S+)\s+(\S+)/) {
	return (0, undef, $1, $2);
	}
else {
	return (1, "No valid licence was found for your host ID $id ".
		   "and license key $key");
	}

}

# check_virtualmin_config(&server, [no-require])
# Updates a server object with Virtualmin config errors
sub check_virtualmin_config
{
my ($server, $noreq) = @_;
if ($server->{'status'} eq 'virt') {
	if (!$noreq) {
		&remote_foreign_require($server, "virtual-server",
						 "virtual-server-lib.pl");
		}
	my $cerr = &remote_foreign_call($server, "virtual-server",
				   "set_all_null_print");
	my $cerr = &remote_foreign_call($server, "virtual-server",
				   "check_virtual_server_config");
	$cerr =~ s/<[^>]*>//g;	# Remove HTML
	$server->{'virtualmin_checked'} = $cerr ? 0 : 1;
	$server->{'virtualmin_error'} = $cerr;
	}
else {
	delete($server->{'virtualmin_checked'});
	delete($server->{'virtualmin_error'});
	}
}

# update_virtualmin_ips(&server)
# Update the IPs for any domains on the old main shared IP
sub update_virtualmin_ips
{
my ($server) = @_;
my @doms = &get_server_domains($server);
my %ipcount;
foreach my $d (@doms) {
	if (!$d->{'virt'}) {
		$ipcount{$d->{'ip'}}++;
		}
	}
my ($oldip) = sort { $ipcount{$b} <=> $ipcount{$a} } keys %ipcount;
$oldip || return "No domains on old shared IP found";
my $newip = &get_server_ip($server);
foreach my $d (@doms) {
	if (!$d->{'virt'} && $d->{'ip'} eq $oldip) {
		my ($err, $out) = &call_virtualmin_api(
			$server, "modify-domain", 
			[ [ "domain", $d->{'dom'} ],
			  [ "shared-ip", $newip ] ]);
		if ($err) {
			return "$d->{'dom'} failed : $err";
			}
		$d->{'ip'} = $newip;
		}
	}
&save_server_domains($server, \@doms);
return undef;
}

# get_interface_use(&server, &info, &domains, &iface)
# Returns a code and string describing what some interface is for. Codes
# are 0=none, 1=default IP for Virtualmin, 2=For domain
sub get_interface_use
{
my ($server, $info, $doms, $iface) = @_;
if ($iface->{'address'}  &&
    $iface->{'address'} eq $info->{'defip'}) {
	return (1, $text{'iface_default'});
	}
else {
	my @ipdoms = grep { $_->{'ip'} eq $iface->{'address'} } @$doms;
	if (@ipdoms) {
		return (2,
			@ipdoms > 4 ? &text('iface_many', scalar(@ipdoms)) :
			@ipdoms == 1 ? &text('iface_dom', 
					     "<tt>$ipdoms[0]->{'dom'}</tt>") :
			&text('iface_doms', 
		          join(", ", map { "<tt>$_->{'dom'}</tt>" } @ipdoms)) );
		}
	elsif ($iface->{'address'} eq $server->{'ip'} ||
	       $iface->{'address'} eq &to_ipaddress($server->{'host'})) {
		return (1, $text{'iface_primary'});
		}
	else {
		return (0, $text{'iface_nothing'});
		}
	}
}

# create_authorized_key(&server)
# Add the SSH key selected for this server to root's ~/.ssh/authorized_keys file
sub create_authorized_key
{
my ($server) = @_;
my ($key) = grep { $_->{'id'} eq $server->{'key'} } &list_ssh_keys();
my $authkeys = &setup_authorized_keys($server);
my $temp = &transname();
&open_tempfile(AUTH, ">$temp");
&print_tempfile(AUTH, &generate_public_key($key),"\n");
&close_tempfile(AUTH);
&set_ownership_permissions(undef, undef, 0700, $temp);
return &put_file_to_server($server, $temp, $authkeys);
}

# setup_authorized_keys(&server)
# Ensure that ~/.ssh exists, and return the path to the authorized_keys file
sub setup_authorized_keys
{
my ($server) = @_;

# Work out root's home dir
my $roothome;
my $data = &get_file_data_from_server($server, "/etc/passwd");
foreach my $l (split(/\r?\n/, $data)) {
	my @w = split(/:/, $l);
	if ($w[0] eq 'root') {
		$roothome = $w[5];
		last;
		}
	}
if ($server->{'type'} eq 'solaris') {
	$roothome ||= "/";
	}
else {
	$roothome ||= "/root";
	}

# Create .ssh dir if missing
my $sshdir = "$roothome/.ssh";
my @st = &stat_file_on_server($server, $sshdir);
if (!@st) {
	my $temp = &transname();
	&make_dir($temp, 0700);
	&put_file_to_server($server, $temp, $sshdir);
	}

return "$sshdir/authorized_keys";
}

# set_shadow_root_password(&server, pass)
# Sets the root password for a server by directly editing /etc/shadow
sub set_shadow_root_password
{
my ($server, $pass) = @_;

# If this is an EC2 server, the default SSHd config doesn't allow password-less
# root logins! Fix that (in advanced, so that the new password works)
if ($server->{'manager'} eq 'ec2') {
	&fix_ssh_root_login($server);
	&execute_command_on_server($server, "killall -HUP sshd");
	}

# Mount filesystem if needed
my $err = &mount_filesystem_if_needed($server);
return $err if ($err);

my $shadow = &transname();
my $passfile = "/etc/shadow";
my $err = &get_file_from_server($server, $passfile, $shadow);
if ($err) {
	# Perhaps it has /etc/passwd?
	$passfile = "/etc/passwd";
	$err = &get_file_from_server($server, $passfile, $shadow);
	}
if (!$err) {
	my $lref = &read_file_lines($shadow);
	foreach my $l (@$lref) {
		my @w = split(/:/, $l, -1);
		if ($w[0] eq "root") {
			my $salt = substr(time(), -2);
			$w[1] = &unix_crypt($pass, $salt);
			$l = join(':', @w);
			}
		}
	&flush_file_lines($shadow);
	$err = &put_file_to_server($server, $shadow, $passfile);
	}

# Un-mount if mounted before
&umount_filesystem_if_needed($server);

return $err;
}

# clear_authorized_key(&server)
# Delete root's authorized_keys file from a server
sub clear_authorized_key
{
my ($server) = @_;
foreach my $f ("/root/.ssh/authorized_keys",
	       "/root/.ssh/authorized_keys2",
	       "/.ssh/authorized_keys",
	       "/.ssh/authorized_keys2") {
	&delete_file_on_server($server, $f);
	}
return undef;
}

# has_addnew_keys(&server)
# Returns 1 if there are any extra SSH keys to add for this server
sub has_addnew_keys
{
my ($server) = @_;
my @keys = grep { $_->{'id'} ne $server->{'key'} && $_->{'addnew'} }
		   &list_ssh_keys();
return @keys ? 1 : 0;
}

# addnew_authorized_keys(&server)
# Add extra authorized keys to a new server
sub addnew_authorized_keys
{
my ($server) = @_;
my $authkeys = &setup_authorized_keys($server);
my $temp = &transname();
&get_file_from_server($server, $authkeys, $temp);	# OK if missing
my $missing = -r $temp ? 0 : 1;
&open_tempfile(AUTH, ">>$temp");
foreach my $key (grep { $_->{'id'} ne $server->{'key'} && $_->{'addnew'} }
		      &list_ssh_keys()) {
	&print_tempfile(AUTH, &generate_public_key($key),"\n");
	}
&close_tempfile(AUTH);
&set_ownership_permissions(undef, undef, 0700, $temp) if ($missing);
return &put_file_to_server($server, $temp, $authkeys);
}

# regenerate_ssh_host_keys(&server)
# Delete all SSH host keys from a system, re-generate and restart SSHd
sub regenerate_ssh_host_keys
{
my ($server) = @_;
my $found = 0;
if (!&has_command_on_server($server, "ssh-keygen")) {
	return "ssh-keygen command not found";
	}
foreach my $t ('', 'dsa', 'rsa') {
	my $hkf = "/etc/ssh/".($t ? "ssh_host_${t}_key" : "ssh_host_key");
	my @st = &stat_file_on_server($server, $hkf);
	next if (!@st);
	my $err = &delete_file_on_server($server, $hkf);
	if ($err) {
		return "Failed to delete $hkf : $err";
		}
	&delete_file_on_server($server, $hkf.".pub");
	my ($out, $ex, $err) = &execute_command_on_server($server,
		"ssh-keygen".($t ? " -t $t" : "")." -f $hkf -N '' </dev/null");
	if ($ex || $err) {
		return "Failed to generate $hkf : ".($err || $out);
		}
	$found++;
	}
if ($found) {
	# Restart SSHd too
	&execute_command_on_server($server,
		$server->{'type'} eq 'solaris' ?
			'pkill -HUP sshd' : 'killall -HUP sshd');
	&clear_ssh_host_key($server);
	}
return $found ? undef : "No SSH host keys found";
}

# check_domain_move(&serverdoms, &destserver, delete, direct, re-allocate-ip)
# Checks if the given set of virtual servers can be moved together, and returns
# an error message if not.
sub check_domain_move
{
my ($serverdoms, $dest, $delete, $direct, $realloc) = @_;
my @destdoms = &get_server_domains($dest);
my %sources;

foreach my $sd (@$serverdoms) {
	my ($server, $d) = @$sd;
	$sources{$server->{'id'}} ||= $server;
	if ($d->{'parent'}) {
		# This is a sub-server .. either the parent must be on the
		# target already, or in the list of those to move.
		my ($pd) = grep { $_->[1]->{'id'} == $d->{'parent'} }
				   @$serverdoms;
		if (!$pd) {
			($pd) = grep { $_->{'id'} == $d->{'parent'} } @destdoms;
			}
		if (!$pd) {
			return &text('dmass_eparent', $d->{'dom'});
			}
		}
	else {
		# This is a top-level server .. all child domains must be
		# included if in delete mode, or they would be lost
		if ($delete) {
			my @srcdoms = &get_server_domains($server);
			my @children = grep { $_->{'parent'} == $d->{'id'} }
					       @srcdoms;
			foreach my $cd (@children) {
				my ($inlist) =
					grep { $_->[1]->{'id'} == $cd->{'id'} }
					     @$serverdoms;
				if (!$inlist) {
					return &text('dmass_echild',
						     $d->{'dom'}, $cd->{'dom'});
					}
				}
			}
		}

	# Check if source and dest servers are the same
	if ($server->{'id'} == $dest->{'id'}) {
		return &text('dmass_esame', $d->{'dom'}, $server->{'host'});
		}

	# Check for clash on target
	my ($idclash) = grep { $_->{'id'} eq $d->{'id'} } @destdoms;
	if ($idclash) {
		return &text('dmass_emoveclash', $d->{'dom'});
		}
	my ($clash) = grep { $_->{'dom'} eq $d->{'dom'} } @destdoms;
	if ($clash) {
		return &text('dmass_emoveclash2', $d->{'dom'});
		}

	# If the domain has a private IP, it must be deleted from
	# the source system to work, unless re-allocating
	if ($d->{'virt'} && !$d->{'virtalready'} && $delete != 1 && !$realloc) {
		return &text('dmass_evirtdelete', $d->{'dom'}, $d->{'ip'});
		}
	}

# If doing a direct transfer, make sure all sources can SSH to the dest
if ($direct) {
	foreach my $server (values %sources) {
		next if ($dest->{'ssh_pass'});	# Assume it will work
		next if ($dest->{'id'} == 0);	# Direct isn't even needed
		my ($out, $ex, $err) = &execute_command_on_server($server,
			"ssh -o PasswordAuthentication=no -x ".
			"-".$dest->{'ssh_protocol'}." ".
			($dest->{'ssh_port'} ? " -p ".$dest->{'ssh_port'} : "").
			$dest->{'ssh_user'}."\@".$dest->{'ip'}." echo OK");
		return $err if ($err);
		if ($ex || $out !~ /OK/) {
			return &text('dmass_emovessh',
				     $server->{'host'}, $dest->{'host'},
				     &html_escape($out));
			}
		}
	}

return undef;
}

# check_move_features(&serverdoms, &destserver)
# Checks if the destination server has all the needed features required to
# setup the selected domains. Returns a list of missing features and domains
# found.
sub check_move_features
{
my ($serverdoms, $dest) = @_;
my @rv;
my $info = &get_server_collected($dest);
foreach my $sd (@$serverdoms) {
	my ($server, $d) = @$sd;
	my $sinfo = &get_server_collected($server);
	foreach my $f (@{$sinfo->{'features'}}) {
		my ($dgot) = grep { $_->{'feature'} eq $f->{'feature'} }
				     @{$info->{'features'}};
		if ($d->{$f->{'feature'}} && (!$dgot || !$dgot->{'enabled'})) {
			# Missing on destination
			push(@rv, [ $server, $d, $f ]);
			}
		}
	}
return @rv;
}

# move_domains_to_server(&serverdoms, &destserver, delete-source, direct-copy,
# 		  	 re-allocate-ip)
# Transfers domains from source systems to a single destination. Calls 
# $first_print and friends to display progress.
sub move_domains_to_server
{
my ($serverdoms, $dest, $delete, $direct, $realloc) = @_;
my (@refresh, %refreshed);
$direct = 0 if ($dest->{'id'} == 0);	# Transferring to master

# Sort list so that parents come first
my @sorted = sort { $a->[1]->{'parent'} <=> $b->[1]->{'parent'} ||
		       $a->[1]->{'alias'} <=> $b->[1]->{'alias'} } @$serverdoms;

my (%failed, %donebackup, %sourcetemp);
foreach my $sd (@sorted) {
	my ($server, $d) = @$sd;

	# Re-connect to Webmin, to avoid RPC timeout
	&remote_finished();

	# Show start message
	if ($direct) {
		&$first_print(&text('move_backing2', $d->{'dom'},
				    $server->{'host'}, $dest->{'host'}));
		}
	else {
		&$first_print(&text('move_backing', $d->{'dom'},
				    $server->{'host'}));
		}

	# Find a good temp dir on the source
	$last_remote_error = undef;
	&remote_foreign_require($server, "webmin", "webmin-lib.pl");
	if ($last_remote_error) {
		&$second_print(&text('move_ewebmin', $last_remote_error));
		$failed{$d->{'id'}} = $sd;
		next;
		}
	my $tmpdir = $sourcetemp{$server->{'id'}};
	if (!$tmpdir) {
		my $temp = &remote_foreign_call($server, "webmin",
					"tempname", "$d->{'dom'}.tar.gz");
		$tmpdir = $temp;
		$tmpdir =~ s/\/([^\/]+)$//;
		}

	# Find a temp file on the target, if needed
	my $desttemp;
	if ($dest->{'id'} != 0) {
		$last_remote_error = undef;
                &remote_foreign_require($dest, "webmin", "webmin-lib.pl");
		if ($last_remote_error) {
			&$second_print(&text('move_ewebmin',
					     $last_remote_error));
			$failed{$d->{'id'}} = $sd;
			next;
			}
		$desttemp = &remote_foreign_call($dest, "webmin",
						 "tempname", $filename);
		if ($direct) {
			# For a direct transfer, this is a directory that we
			# scp the backup into
			&remote_foreign_call($dest, "webmin", "make_dir",
					     $desttemp, 0700);
			}
		}

	# Check if parent has failed
	if ($d->{'parent'} && $failed{$d->{'parent'}}) {
		&$second_print(&text('move_eparent',
			       $failed{$d->{'parent'}}->[1]->{'dom'}));
		$failed{$d->{'id'}} = $sd;
		next;
		}
	if ($d->{'alias'} && $failed{$d->{'alias'}}) {
		&$second_print(&text('move_ealias',
			       $failed{$d->{'alias'}}->[1]->{'dom'}));
		$failed{$d->{'id'}} = $sd;
		next;
		}

	my @args = ( [ "domain", $d->{'dom'} ],
		     [ "all-features" ],
		     [ "option", "mail mailfiles 1" ],
		     [ "newformat" ],
		      );
	if ($direct) {
		# Backup to dest via SSH directly
		my $pa = $dest->{'ssh_port'} ? ":".$dest->{'ssh_port'} : "";
		push(@args, [ "dest", "ssh://$dest->{'ssh_user'}:$dest->{'ssh_pass'}$pa\@$dest->{'ip'}$desttemp" ]);
		}
	else {
		# Backup to a temp file on the target
		push(@args, [ "dest", $tmpdir ]);
		}
	my ($err, $out) = &call_virtualmin_api(
		$server, "backup-domain", \@args);
	if ($err) {
		&$second_print(&text('move_ebackup', $err));
		$failed{$d->{'id'}} = $sd;
		next;
		}

	# Work out the resulting filename and size
	my (@st, $filename, $statserver, $statdir);
	if ($direct) {
		# Stat on dest server
		$statserver = $dest;
		$statdir = $desttemp;
		}
	else {
		# Stat on source server
		$statserver = $server;
		$statdir = $tmpdir;
		}
	&remote_finished();
	&remote_foreign_require($statserver, "webmin", "webmin-lib.pl");
	foreach my $p ("$d->{'dom'}.tar.gz",
		       "$d->{'dom'}.tar.bz2",
		       "$d->{'dom'}.tar") {
		my $st = &remote_eval($statserver, "webmin",
					"[ stat('$statdir/$p') ]");
		@st = @$st;
		if (@st) {
			$filename = $p;
			last;
			}
		}
	if (!@st) {
		&$second_print(&text('move_estat'));
		$failed{$d->{'id'}} = $sd;
		next;
		}

	# Make sure the target can support the backup format
	my $unc = $filename =~ /\.gz$/ ? "gunzip" :
		     $filename =~ /\.bz2$/ ? "bunzip2" :
		     $filename =~ /\.zip$/ ? "unzip" : "tar";
	if (!&has_command_on_server($dest, $unc)) {
		&$second_print(&text('move_eunc', "<tt>$unc</tt>"));
		$failed{$d->{'id'}} = $sd;
		next;
		}

	&$second_print(&text('move_backed', &nice_size($st[7])));

	# Transfer to master system, if not already there
	my ($localtemp, @st);
	if (!$direct) {
		if ($server->{'id'} != 0) {
			&$first_print(&text('move_download',
					    $d->{'dom'}, $filename));
			$localtemp = &transname($filename);
			my $err = &get_file_from_server($server,
				"$tmpdir/$filename", $localtemp);
			&execute_command_on_server($server,
				   "rm -f ".quotemeta("$tmpdir/$filename"));
			if ($err) {
				&$second_print(&text('move_edownload', $err));
				$failed{$d->{'id'}} = $sd;
				next;
				}
			@st = stat($localtemp);
			&$second_print(&text('move_downloaded',
					     &nice_size($st[7])));
			}
		else {
			$localtemp = "$tmpdir/$filename";
			@st = stat($localtemp);
			}

		# Transfer to destination (if not already there)
		if ($dest->{'id'} != 0) {
			&$first_print(&text('move_upload', $d->{'dom'},
				$filename, $dest->{'host'}));
			my $err = &put_file_to_server($dest, $localtemp,
							 $desttemp);
			unlink($localtemp);
			if ($err) {
				&$second_print(&text('move_eupload', $err));
				$failed{$d->{'id'}} = $sd;
				next;
				}
			&$second_print(&text('move_uploaded',
					     &nice_size($st[7])));
			}
		else {
			$desttemp = $localtemp;
			}
		}
	else {
		# Work out real destination filename
		$desttemp .= "/".$filename;
		}

	# Flag as done
	$donebackup{$d->{'id'}} = $desttemp;
	}

# Disable or delete requested domains
my %disabled;
foreach my $sd (@sorted) {
	my ($server, $d) = @$sd;

	# Skip if not backed up
	next if (!$donebackup{$d->{'id'}});

	# Skip if the parent has already been done, or has failed
	next if ($d->{'parent'} && $donebackup{$d->{'parent'}});
	next if ($d->{'parent'} && $failed{$d->{'parent'}});

	if ($delete == 2) {
		# Disable on source
		&$first_print(&text('move_disable', $d->{'dom'},
						    $server->{'host'}));
		my @args = ( [ "domain", $d->{'dom'} ] );
		my ($err, $out) = &call_virtualmin_api(
					$server, "disable-domain", \@args);
		if ($err) {
			&$second_print(&text('move_edisable', $err));
			$failed{$d->{'id'}} = $sd;
			next;
			}
		else {
			&$second_print(&text('move_disabled', $d->{'dom'}));
			push(@refresh, $server)
				if (!$refreshed{$server->{'id'}}++);
			$disabled{$server->{'id'},$d->{'dom'}} = 1;
			}
		}
	elsif ($delete == 1) {
		# Delete on source
		&$first_print(&text('move_delete', $d->{'dom'},
						   $server->{'host'}));
		my @args = ( [ "domain", $d->{'dom'} ] );
		my ($err, $out) = &call_virtualmin_api(
					$server, "delete-domain", \@args);
		if ($err) {
			&$second_print(&text('move_edelete', $err));
			$failed{$d->{'id'}} = $sd;
			next;
			}
		else {
			&$second_print(&text('move_deleted', $d->{'dom'}));
			push(@refresh, $server)
				if (!$refreshed{$server->{'id'}}++);
			}
		}
	}

# Re-create all domains from backups. This has to be done after deleting from
# the source (if requested), so that we don't get clashes.
foreach my $sd (@sorted) {
	my ($server, $d) = @$sd;

	# Skip if failed
	next if ($failed{$d->{'id'}});

	# Restore on destination
	my $desttemp = $donebackup{$d->{'id'}};
	&$first_print(&text('move_restore', $d->{'dom'}, $dest->{'host'}));
	my @args = ( [ "source", $desttemp ],
			[ "all-features" ],
			[ "option", "dns fixip 1" ],
			[ "option", "web fixip 1" ],
			[ "option", "ssl fixip 1" ],
			[ "option", "mail mailfiles 1" ],
			[ "domain", $d->{'dom'} ] );
	if ($realloc && $d->{'virt'}) {
		push(@args, [ "allocate-ip" ]);
		}
	my ($err, $out) = &call_virtualmin_api($dest,
			"restore-domain", \@args);
	if ($delete != 1) {
		&execute_command_on_server($server,
			"rm -f ".quotemeta($desttemp));
		}
	if (!$err && $out =~ /Restore\s+failed/i) {
		# Catch case where restore-domain didn't exit with non-zero
		$err = $out;
		}
	if ($err) {
		# Restore failed!!
		&$block_print($out);
		&$second_print(&text('move_erestore', $err));
		if ($delete == 1) {
			# Was deleted on the source already!
			&$second_print(&text('move_ewarning', $d->{'dom'},
					     $desttemp, $server->{'host'}));
			}
		elsif ($delete == 2 && $disabled{$server->{'id'},$d->{'dom'}}) {
			# Was disabled on the source .. re-enable
			&$first_print(&text('move_enable', $d->{'dom'},
						    $server->{'host'}));
			my @args = ( [ "domain", $d->{'dom'} ] );
			my ($err, $out) = &call_virtualmin_api(
					$server, "enable-domain", \@args);
			if ($err) {
				&$second_print(&text('move_eenable', $err));
				}
			else {
				&$second_print(&text('move_enabled',
						     $d->{'dom'}));
				}
			}
		$failed{$d->{'id'}} = $sd;
		next;
		}
	&$second_print(&text('move_restored', $d->{'dom'}));
	push(@refresh, $dest) if (!$refreshed{$dest->{'id'}}++);
	}

if (@refresh) {
	# Refresh status of all changed systems
	&$first_print(&text('move_refresh', scalar(@refresh)));
	foreach my $server (@refresh) {
		&check_server_status($server);
		&save_managed_server($server);
		}
	&$second_print($text{'create_done'});
	}

return keys %failed;
}

# find_sub_servers(&serverdoms)
# Given a list of server/domain tuples, finds all their sub-servers and aliases
# and returns a list. 
sub find_sub_servers
{
my ($serverdoms) = @_;
my @rv;
foreach my $sd (@serverdoms) {
	my ($server, $d) = @$sd;
	my @doms = &get_server_domains($server);
	if (!$d->{'parent'}) {
		# Find sub-servers
		push(@rv, map { [ $server, $_ ] }
			      grep { $_->{'parent'} &&
				     $_->{'parent'} == $d->{'id'} } @doms);
		}
	# Find sub-domains
	push(@rv, map { [ $server, $_ ] }
		      grep { $_->{'subdom'} &&
			     $_->{'subdom'} == $d->{'id'} } @doms);
	# Find aliases
	push(@rv, map { [ $server, $_ ] }
		      grep { $_->{'alias'} &&
			     $_->{'alias'} == $d->{'id'} } @doms);
	}
return &unique_serverdoms(\@rv);
}

# unique_serverdoms(&serverdoms)
# Given a list of server/domain tuples, removes duplicates
sub unique_serverdoms
{
my ($serverdoms) = @_;
my %done;
return grep { !$done{$_->[0]->{'id'},$_->[1]->{'id'}}++ } @$serverdoms;
}

# create_allocate_ip(&server)
# Bring up a new virtual interface on the given server, and return the address.
# Returns the interface object on success, or an error string on failure.
sub create_allocate_ip
{
my ($server) = @_;
my $pfunc = "type_".$server->{'manager'}."_list_parent_interfaces";
my $parents = &$pfunc($server);
ref($parents) || return "Failed to get parent network interfaces : $parents";
my ($piface) = grep { $_->{'name'} !~ /^lo/ &&
			 $_->{'virtual'} eq '' } @$parents;
my $iface = { 'name' => $piface->{'name'},
		 'netmask' => $piface->{'netmask'} };
my $ifunc = "type_".$server->{'manager'}."_create_interface";
my $err = &$ifunc($server, $iface);
return $err ? $err : $iface;
}

# get_domain_interface(&server, &domain)
# On systems that support interface management, find the private interface
# used for some domain.
sub get_domain_interface
{
my ($server, $d) = @_;
return undef if (!$d->{'virt'});	# Has no private IP
my $ifunc = "type_".$server->{'manager'}."_list_interfaces";
return undef if (!defined(&$ifunc));	# Server doesn't so interfaces
my $ifaces = &$ifunc($server);
return $ifaces if (!ref($ifaces));
my ($iface) = grep { $_->{'address'} eq $d->{'ip'} } @$ifaces;
return $iface;
}

# get_server_default_gateway(&server)
# Returns the default gateway IP address for some system. Uses Webmin if
# possible, netstat otherwise.
sub get_server_default_gateway
{
my ($server) = @_;
my $gw;
if ($server->{'manager'} eq 'this') {
        # Just call own module
        ($gw) = &net::get_default_gateway();
        }
elsif ($server->{'status'} eq 'virt' || $server->{'status'} eq 'novirt') {
	# Get from Webmin
	$last_remote_error = undef;
	&remote_foreign_require($server, "net", "net-lib.pl");
	if (!$last_remote_error) {
		($gw) = &remote_foreign_call($server, "net",
					     "get_default_gateway");
		return $gw;
		}
	}
# Fall back to netstat command
my ($out, $ex, $err) = &execute_command_on_server($server, "netstat -rn");
foreach my $l (split(/\r?\n/, $out)) {
	my @w = split(/\s+/, $l);
	if ($w[0] eq "default" || $w[0] eq "0.0.0.0") {
		$gw = $w[1];
		last;
		}
	}
return $gw;
}

# get_global_links(system-count)
# Returns 4 array refs, for links, titles, icons and categories
sub get_global_links
{
my ($virtcount) = @_;
my (@glinks, @gtitles, @gicons, @gcats);

if (!&can_action(undef, "global")) {
	goto NOGLOBAL;
	}

# SSH key management
push(@glinks, "list_keys.cgi");
push(@gtitles, $text{'keys_title'});
push(@gicons, "images/keys.gif");
push(@gcats, "settings");

# Server images
if ($server_management_types{'xen'} ||
    $server_management_types{'kvm'} ||
    $server_management_types{'vserver'} ||
    $server_management_types{'openvz'} ||
    $server_management_types{'zones'}) {
	push(@glinks, "list_images.cgi");
	push(@gtitles, $text{'images_title'});
	push(@gicons, "images/images.gif");
	push(@gcats, "settings");

	if (!$module_info{'onehost'}) {
		push(@glinks, "list_storages.cgi");
		push(@gtitles, $text{'storages_title'});
		push(@gicons, "images/storages.gif");
		push(@gcats, "settings");
		}
	}

# Bandwidth monitoring
if ($server_management_types{'xen'} ||
    $server_management_types{'kvm'} ||
    $server_management_types{'vserver'} ||
    $server_management_types{'openvz'} ||
    $server_management_types{'zones'}) {
	push(@glinks, "edit_bw.cgi");
	push(@gtitles, $text{'bw_title'});
	push(@gicons, "images/bw.gif");
	push(@gcats, "monitor");

	if ($config{'bw_enabled'}) {
		push(@glinks, "bwgraph.cgi");
		push(@gtitles, $text{'graph_title2'});
		push(@gicons, "images/graph.gif");
		push(@gcats, "monitor");
		}
	}

# Historic graphs for all systems
push(@glinks, "history.cgi");
push(@gtitles, $text{'history_title'});
push(@gicons, "images/hist.gif");
push(@gcats, "monitor");

# Alert rules
push(@glinks, "list_alerts.cgi");
push(@gtitles, $text{'alerts_title'});
push(@gicons, "images/alerts.gif");
push(@gcats, "monitor");

# System owners
push(@glinks, "list_owners.cgi");
push(@gtitles, $text{'owners_title'});
push(@gicons, "images/owners.gif");
push(@gcats, "settings");

# Account plans
if (&supports_plans()) {
	push(@glinks, "list_plans.cgi");
	push(@gtitles, $text{'plans_title'});
	push(@gicons, "images/plans.gif");
	push(@gcats, "settings");
	}

# Master admin email
push(@glinks, "edit_email.cgi");
push(@gtitles, $text{'email_title'});
push(@gicons, "images/email.gif");
push(@gcats, "settings");

if ($virtcount) {
	# Default Virtualmin features
	push(@glinks, "list_features.cgi");
	push(@gtitles, $text{'features_title'});
	push(@gicons, "images/features.gif");
	push(@gcats, "virtualmin");
	}

# Virtualmin licences
push(@glinks, "list_licences.cgi");
push(@gtitles, $text{'licences_title'});
push(@gicons, "images/licences.gif");
push(@gcats, $virtcount ? "virtualmin" : "settings");

# Plugins
push(@glinks, "list_plugins.cgi");
push(@gtitles, $text{'plugins_title'});
push(@gicons, "images/plugins.gif");
push(@gcats, "settings");

# Replication
if (!$module_info{'onehost'}) {
	push(@glinks, "edit_repl.cgi");
	push(@gtitles, $text{'repl_title'});
	push(@gicons, "images/repl.gif");
	push(@gcats, "settings");
	}

# Type-defined icons
foreach my $t (@server_management_types) {
	my $gfunc = "type_".$t."_global_links";
	if (defined(&$gfunc)) {
		foreach my $g (&$gfunc()) {
			push(@glinks, $g->{'link'});
			push(@gtitles, $g->{'title'});
			push(@gicons, $g->{'icon'});
			push(@gcats, $g->{'cat'} || "settings");
			}
		}
	}

# Host locations
if (defined(&list_locations)) {
	push(@glinks, "list_locations.cgi");
	push(@gtitles, $text{'locations_title'});
	push(@gicons, "images/locations.gif");
	push(@gcats, "hosts");
	}

# IP allocation overview
push(@glinks, "list_ips.cgi");
push(@gtitles, $text{'ips_title'});
push(@gicons, "images/ips.gif");
push(@gcats, "hosts");

# Plugin-defined icons
foreach my $p (@plugins) {
	if (&plugin_defined($p, "settings_links")) {
		foreach my $g (&plugin_call($p, "settings_links")) {
			push(@glinks, $g->{'link'});
			push(@gtitles, $g->{'title'});
			push(@gicons, $g->{'icon'});
			push(@gcats, $g->{'cat'} || "settings");
			}
		}
	}

NOGLOBAL:
if ($virtcount) {
	# Virtualmin domains
	push(@glinks, "list_domains.cgi");
	push(@gtitles, $text{'domains_title'});
	push(@gicons, "images/domains.gif");
	push(@gcats, "virtualmin");

	# Virtualmin syncing
	push(@glinks, "list_vsyncs.cgi");
	push(@gtitles, $text{'vsyncs_title'});
	push(@gicons, "images/vsyncs.gif");
	push(@gcats, "virtualmin");
	}

if (&can_action(undef, "backup") && defined(&list_backups)) {
	# Backup and restore
	push(@glinks, "list_backups.cgi");
	push(@gtitles, $text{'backups_title'});
	push(@gicons, "images/backups.gif");
	push(@gcats, "backup");

	push(@glinks, "list_backuplogs.cgi");
	push(@gtitles, $text{'backuplogs_title'});
	push(@gicons, "images/backuplog.gif");
	push(@gcats, "backup");

	push(@glinks, "restore_form.cgi");
	push(@gtitles, $text{'restore_title'});
	push(@gicons, "images/restore.gif");
	push(@gcats, "backup");
	}

if ($access{'owner'}) {
	# Change owner details
	push(@glinks, "owner_form.cgi");
	push(@gtitles, $text{'oform_title'});
	push(@gicons, "images/oform.gif");
	push(@gcats, "settings");
	}

if (!$cloudmin_pro) {
	# Upgrade link
	push(@glinks, "upgrade_form.cgi");
	push(@gtitles, $text{'upgrade_title'});
	push(@gicons, "images/upgrade.gif");
	push(@gcats, "settings");
	}

return (\@glinks, \@gtitles, \@gicons, \@gcats);
}

# get_available_create_links()
# Returns a list of link objects for creation actions available to the
# current user
sub get_available_create_links
{
my @rv;
foreach $t (@server_manager::server_management_types) {
	$lfunc = "server_manager::type_".$t."_create_links";
	if (defined(&$lfunc)) {
		foreach $l (&$lfunc()) {
			$l->{'type'} = $t;
			my $cfunc = $l->{'create'} ? \&can_create_server
						   : \&can_add_server;
			my $can = &$cfunc($t);
			if ($can) {
				push(@rv, $l);
				}
			}
		}
	}
return @rv;
}

# sort_package_updates(package, ...)
# Sorts a list of packages into the order they should be installed, so that
# Webmin is always done first, then the updates module, then virtualmin,
# then plugins
sub sort_package_updates
{
return sort { ($b->{'name'} eq 'webmin' ? 3 :
	       $b->{'name'} =~ /security-updates$/ ? 2 :
	       $b->{'name'} =~ /virtual-server$/ ? 1 : 0)
	      <=>
	      ($a->{'name'} eq 'webmin' ? 3 :
	       $a->{'name'} =~ /security-updates$/ ? 2 :
	       $a->{'name'} =~ /virtual-server$/ ? 1 : 0) } @_;
}

# get_server_actions(&server)
# Returns a list of array refs containing possible actions for some server
sub get_server_actions
{
my ($server) = @_;
my $status = $server->{'status'};
my $t = $server->{'manager'};
my @rv;

# Work out what we can and cannot do
my $nfunc = "type_".$server->{'manager'}."_no_image";
my $noimage = defined(&$nfunc) && &$nfunc($server) ||
		 $status eq 'nohost';
my $mfunc = "type_".$server->{'manager'}."_can_move";
my $canmove = defined(&$mfunc) && &$mfunc($server);
my $sfunc = "type_".$t."_no_shutdown";
my $noshut = defined(&$sfunc) && &$sfunc($server);
my $rfunc = "type_".$t."_no_reboot";
my $noreboot = defined(&$rfunc) && &$rfunc($server);
my $tfunc = "type_".$t."_can_transfer";
my $cantransfer = defined(&$tfunc) && &$tfunc($server);
my $cfunc = "type_".$t."_get_console_output";
my $canconsole = defined(&$cfunc);
my $clfunc = "type_".$t."_supports_console_login";
my $canlogin = defined(&$clfunc) && &$clfunc($server);
my $rsfunc = "type_".$server->{'manager'}."_can_reset";
my $canreset = defined(&$rsfunc) && &$rsfunc($server);
my $pfunc = "type_".$server->{'manager'}."_can_password";
my $canpass = defined(&$pfunc) && &$pfunc($server);

# Start with links to edit_serv.cgi
my $ed = "edit_serv.cgi?id=$server->{'id'}";
if (&can_action($server, "edit")) {
	push(@rv, { 'id' => 'edit',
		    'desc' => $text{'edit_link_edit'},
		    'cat' => '',
		    'link' => $ed,
		    'priority' => 1 });
	}
elsif (&can_action($server, "view")) {
	# Or link to view details
	push(@rv, { 'id' => 'view',
		    'desc' => $text{'edit_link_view'},
		    'cat' => '',
		    'link' => "edit_serv.cgi?id=$server->{'id'}",
		    'priority' => 1 });
	}

# Link for interfaces
my $ifunc = "type_".$t."_list_interfaces";
my $cfunc = "type_".$t."_can_interfaces";
if (defined(&$ifunc) && &$cfunc($server) &&
    $status ne 'paused' && $status ne 'alive' && $status ne 'nohost' &&
    &can_action($server, "ifaces")) {
	push(@rv, { 'id' => 'ifaces',
		    'desc' => $text{'edit_link_ifaces'},
		    'cat' => 'system',
		    'link' => "list_ifaces.cgi?id=$server->{'id'}" });
	}

# Link for reverse IP, if possible
my @revs = grep { !$_->{'outside'} } &get_server_reverse_records($server);
if (&can_action($server, "reverse") && @revs) {
	push(@rv, { 'id' => 'reverse',
		    'desc' => $text{'edit_link_reverse'},
		    'cat' => 'system',
		    'link' => "edit_reverse.cgi?id=$server->{'id'}" });
	}

# Link for Virtualmin domains
if ($status eq 'virt' && (&can_action($server, "edit") ||
			  &can_action($server, "view"))) {
	push(@rv, { 'id' => 'doms',
		    'desc' => $text{'edit_link_doms'},
		    'cat' => 'system',
		    'link' => "edit_domains.cgi?id=$server->{'id'}" });
	}

# Link for updates, if any
if (($server->{'virtualmin_poss'} || $server->{'all_poss'}) &&
    &can_action($server, "update")) {
	push(@rv, { 'id' => 'update',
		    'desc' => &text('edit_link_update',
		    		    $server->{'all_poss'} ||
				      $server->{'virtualmin_poss'}),
		    'cat' => '',
		    'link' => "mass_update_form.cgi?d=$server->{'id'}" });
	}

# Link to edit limits
if (&can_edit_limits($server) && &can_action($server, "limits")) {
	push(@rv, { 'id' => 'limits',
		    'desc' => $text{'edit_link_limits'},
		    'cat' => 'res',
		    'link' => "edit_limits.cgi?id=$server->{'id'}" });
	}

if ($status eq 'down' || $status eq 'nossh' || $status eq 'nohost' ||
    $status eq 'paused' || $status eq 'noping') {
	# Actions are limited when system is down
	my $sfunc = "type_".$t."_no_startup";
	my $nostart = defined(&$sfunc) && &$sfunc($server) ||
		   	 $status eq 'nohost';
	if (&can_action($server, "refresh")) {
		push(@rv, { 'id' => 'refresh',
			    'desc' => $text{'edit_refresh'},
			    'cat' => undef });
		}
	if ($cantransfer && &can_action($server, "transfer")) {
		push(@rv, { 'id' => 'transfer',
			    'desc' => $text{'edit_transfer'},
			    'cat' => 'manage',
			    'link' => "transfer_form.cgi?id=$server->{'id'}" });
		}
	if ($status ne 'paused' && !$nostart &&
	    &can_action($server, "startup")) {
		push(@rv, { 'id' => 'startup',
			    'desc' => $text{'edit_startup'},
			    'cat' => 'power' });
		}
	if (($status eq 'nossh' || $status eq 'paused' ||
	     $status eq 'noping') && !$noshut &&
	    &can_action($server, "shutdown")) {
		push(@rv, { 'id' => 'shutdown',
			    'desc' => $text{'edit_shutdown'},
			    'cat' => 'power' });
		}
	if (($status eq 'nossh' || $status eq 'paused' ||
             $status eq 'noping') && !$noreboot &&
	    &can_action($server, "reboot")) {
		push(@rv, { 'id' => 'reboot',
			    'desc' => $text{'edit_reboot'},
			    'cat' => 'power' });
		}
	}
elsif ($status eq 'alive') {
	# For servers where we are not allowed to login, only show boot-related
	# actions
	if (&can_action($server, "refresh")) {
		push(@rv, { 'id' => 'refresh',
			    'desc' => $text{'edit_refresh'},
			    'cat' => '' });
		push(@rv, undef);
		}
	if (!$noreboot && &can_action($server, "reboot")) {
		push(@rv, { 'id' => 'reboot',
			    'desc' => $text{'edit_reboot'},
			    'cat' => 'power' });
		}
	if (!$noshut && &can_action($server, "shutdown")) {
		push(@rv, { 'id' => 'shutdown',
			    'desc' => $text{'edit_shutdown'},
			    'cat' => 'power' });
		}
	}
else {
	# Most actions are only for up servers
	my $wurl = &webmin_link($server);
	if (&can_action($server, "refresh")) {
		push(@rv, { 'id' => 'refresh',
			    'desc' => $text{'edit_refresh'},
			    'cat' => '' });
		if ($server->{'status'} eq 'virt' ||
		    $server->{'status'} eq 'novirt') {
			push(@rv, { 'id' => 'regen',
				    'desc' => $text{'edit_regen'},
				    'cat' => '' });
			}
		push(@rv, undef);
		}
	if (&can_action($server, "run")) {
		push(@rv, { 'id' => 'shell',
		    	    'desc' => $text{'edit_shell'},
		    	    'cat' => 'manage' });
		}
	if ($cantransfer && &can_action($server, "transfer")) {
		push(@rv, { 'id' => 'transfer',
			    'desc' => $text{'edit_transfer'},
			    'cat' => 'manage',
			    'link' => "transfer_form.cgi?id=$server->{'id'}" });
		}
	if (($status eq 'novirt' || $status eq 'virt') && $server->{'id'}) {
		# Tunneled link to Webmin
		push(@rv, { 'id' => 'webmin',
			    'desc' => $text{'edit_webmin2'},
			    'cat' => '',
			    'target' => '_new',
			    'link' => $wurl });
		if ($wurl =~ /link.cgi/) {
			# Also direct link
			my $prot = $server->{'ssl'} ? 'https' : 'http';
			my $durl = "$prot://$server->{'host'}:$server->{'port'}/";
			push(@rv, { 'id' => 'webmin',
				    'desc' => $text{'edit_webmin3'},
				    'cat' => '',
				    'target' => '_new',
				    'link' => $durl });
			}
		}
	push(@rv, undef);	# Spacer
	if (($status eq 'novirt' || $status eq 'nowebmin') &&
	    $server->{'manager'} ne 'this' &&
	    &can_action($server, "virtualmin")) {
		push(@rv, { 'id' => 'installvirt',
			    'desc' => $text{'edit_installvirt'},
			    'cat' => 'manage' });
		}
	if ($status eq 'nowebmin' &&
	    &can_action($server, "webmin")) {
		push(@rv, { 'id' => 'installwebmin',
			    'desc' => $text{'edit_installwebmin'},
			    'cat' => 'manage' });
		}
	if ($status eq 'virt' && $server->{'virtualmin_error'} &&
	    &can_action($server, "refresh")) {
		push(@rv, { 'id' => 'recheck',
			    'desc' => $text{'edit_recheck'},
			    'cat' => '' });
		}
	if (!$noreboot && &can_action($server, "reboot")) {
		push(@rv, { 'id' => 'reboot',
			    'desc' => $text{'edit_reboot'},
			    'cat' => 'power' });
		}
	if (!$noshut && &can_action($server, "shutdown")) {
		push(@rv, { 'id' => 'shutdown',
			    'desc' => $text{'edit_shutdown'},
			    'cat' => 'power' });
		}
	if (&can_action($server, "run") && $canlogin != 2 && $canlogin != -2) {
		# Root shell (don't show if console is the same)
		push(@rv, { 'id' => 'rootshell',
			    'desc' => $text{'edit_rootshell'},
			    'cat' => 'manage',
			    'link' => "login.cgi?id=$server->{'id'}&shell=1" });
		}
	}
if (&can_action($server, "pass") && $canpass) {
	push(@rv, { 'id' => 'pass',
		    'desc' => $text{'edit_setpass'},
		    'cat' => 'manage',
		    'link' => "edit_pass.cgi?id=$server->{'id'}" });
	}
if ($status ne 'nohost') {
	# Console messages can be displayed as long as the host system is up
	if ($canconsole && &can_action($server, "console")) {
		push(@rv, { 'id' => 'console',
			    'desc' => $text{'edit_console'},
			    'cat' => 'power',
			    'link' => "console.cgi?id=$server->{'id'}" });
		}
	}
if ($canlogin && &can_action($server, "console")) {
	# Access console interactively
	push(@rv, { 'id' => 'login',
		    'desc' => $text{'edit_login'},
		    'cat' => 'power',
		    'link' => "login.cgi?id=$server->{'id'}" });
	}
if ($t ne 'real' && $t ne 'this' && &can_action($server, "delete")) {
	# Can delete the system
	push(@rv, { 'id' => 'delete',
		    'desc' => $text{'edit_delete'},
		    'cat' => 'power' });
	}
if (!$noimage && &can_action($server, "image")) {
	# Can create an image
	push(@rv, { 'id' => 'image',
		    'desc' => $text{'edit_image'},
		    'cat' => 'manage',
		    'link' => "image_form.cgi?id=$server->{'id'}" });
	}
if ($canmove && &can_action($server, "move")) {
	# Can move to another host
	push(@rv, { 'id' => 'move',
		    'desc' => $text{'edit_move'},
		    'cat' => 'manage',
		    'link' => "move_form.cgi?id=$server->{'id'}" });
	}
if ($canreset && &can_action($server, "reset")) {
	# Can reset to original image
	push(@rv, { 'id' => 'reset',
		    'desc' => $text{'edit_reset'},
		    'cat' => 'manage',
		    'link' => "reset_form.cgi?id=$server->{'id'}" });
	}

# Pause/un-pause link
my $pfunc = "type_".$t."_can_pause";
if (defined(&$pfunc) && &can_action($server, "pause")) {
	my $p = &$pfunc($server);
	if ($p == 1) {
		push(@rv, { 'id' => 'pause',
			    'desc' => $text{'edit_pause'},
			    'cat' => 'power',
			    'link' => "pause_form.cgi?id=$server->{'id'}" });
		}
	elsif ($p == 2) {
		push(@rv, { 'id' => 'unpause',
			    'desc' => $text{'edit_unpause'},
			    'cat' => 'power',
			    'link' => "unpause.cgi?id=$server->{'id'}" });
		}
	}

# Complex pages associated with system
my $dfunc = "type_".$t."_can_disks";
if (defined(&$dfunc) && &$dfunc($server) && $status ne 'paused' &&
    &can_action($server, "disks")) {
	push(@rv, { 'id' => 'disks',
		    'desc' => $text{'edit_disks'},
		    'cat' => 'res',
		    'link' => "list_disks.cgi?id=$server->{'id'}" });
	}

# Virtual CPUs
my $vfunc = "type_".$t."_can_vcpus";
if (defined(&$vfunc) && &$vfunc($server) &&
    &can_action($server, "vcpus")) {
	push(@rv, { 'id' => 'vcpus',
		    'desc' => $text{'edit_vcpus'},
		    'cat' => 'res',
		    'link' => "list_vcpus.cgi?id=$server->{'id'}" });
	}

# Bandwidth graph
my $rfunc = "type_".$t."_real_interfaces";
if ($config{'bw_enabled'} && defined(&$rfunc) &&
    &can_action($server, "graph")) {
	push(@rv, { 'id' => 'bw',
		    'desc' => $text{'edit_bw'},
		    'cat' => 'res',
		    'link' => "bwgraph.cgi?id=$server->{'id'}" });
	}

# System statistics, if we have any
if (&can_action($server, "graph") &&
    &list_historic_stats([ $server ])) {
	push(@rv, { 'id' => 'history',
		    'desc' => $text{'edit_history'},
		    'cat' => 'res',
		    'link' => "history.cgi?search=$server->{'host'}&".
			      "id=$server->{'id'}" });
	}

# Host system pages
my @par = &is_parent_server($server);
foreach my $p (@par) {
	if (-r "$module_root_directory/list_${p}s.cgi" &&
	    &can_action(undef, "global")) {
		# Edit Xen/whatever host details
		push(@rv, { 'id' => 'host',
			    'desc' => $text{$p.'_editlink'} ||
				      $text{$p.'_edit'},
			    'cat' => 'manage',
			    'link' => "edit_${p}.cgi?id=$server->{'id'}" });
		}
	my $ffunc = "type_".$p."_find_servers";
	if (defined(&$ffunc) && &can_action(undef, "global")) {
		# Find hosted systems
		push(@rv, { 'id' => 'find',
			    'desc' => $text{'find_title_'.$p},
			    'cat' => 'manage',
			    'link' => "find_form.cgi?id=$server->{'id'}&type=$p" });
		}
	}

# Add type-specific actions
my $afunc = "type_".$t."_server_actions";
if (defined(&$afunc)) {
	push(@rv, &$afunc($server));
	}

# Add plugin-defined actions
foreach my $p (@plugins) {
	if (&plugin_defined($p, "server_actions")) {
		push(@rv, &plugin_call($p, "server_actions", $server));
		}
	}

return @rv;
}

# check_virtualmin_serial(serial, key)
# Checks if some licence is valid for Virtualmin. This is done via an HTTP
# request to www.virtualmin.com, with some my caching. Returns 1 if yes
# (and the number of domains, servers and expiry date in an array context),
# 0 if no, -1 if could not tell
sub check_virtualmin_serial
{
my ($serial, $key) = @_;
my $id = &get_host_id();

# First check out positive responses cache
my %serialcache;
&read_file($serial_cache_file, \%serialcache);
my $skh = join(" ", $serial, $key, $id);
if (defined($serialcache{$shk})) {
	($lastcheck, $domains, $servers) = split(/\s+/, $serialcache{$shk});
	if ($lastcheck > time()-60*60) {
		return (1, $domains, $servers);
		}
	}

# Need to really query Virtualmin
my ($out, $error);
&http_download($virtualmin_licence_host,
	       $virtualmin_licence_port,
	       "$virtualmin_licence_prog?id=$id&serial=$key",
	       \$out, \$error, undef, $virtualmin_licence_ssl);
my @rv;
if ($out =~ /^OK\s+(\S+)\s+(\S+)\s+(\S+)/) {
	@rv = ( 1, $2, $3, $1 );
	}
elsif ($error || $out =~ /^ERR\s+/) {
	@rv = ( -1 );
	}
else {
	@rv = ( 0 );
	}

# Update cache and return result
if ($rv[0]) {
	$serialcache{$skh} = join(" ", time(), $rv[1], $rv[2]);
	}
else {
	delete($serialcache{$skh});
	}
&write_file($serial_cache_file, \%serialcache);
return wantarray ? @rv : $rv[0];
}

# get_server_manager_serial()
# Returns the serial number and key for this Cloudmin install
sub get_server_manager_serial
{
my %serial;
if (&read_file($licence_file, \%serial)) {
	return ($serial{'SerialNumber'}, $serial{'LicenseKey'});
	}
return ( );
}

# allocate_virtualmin_serial([vm2])
# Returns either a serial number or key from the list of those pre-allocated,
# or undef and an error message
sub allocate_virtualmin_serial
{
my ($vm2) = @_;
my @lics = &list_virtualmin_licences();
my ($first) = grep { $_->{'vm2'} == $vm2 &&
			$_->{'free'} && !$_->{'install'} } @lics;
if ($first) {
	return ($first->{'serial'}, $first->{'key'});
	}
else {
	return (undef, $text{'virtualmin_efree'});
	}
}

# virtualmin_licence_form(name, no-none, gpl-opt)
# Returns HTML for selecting a Virtualmin licence
sub virtualmin_licence_form
{
my ($name, $nonone, $gpl) = @_;
my @opts;
my ($cansame, $canalloc);
if (!$nonone) {
	push(@opts, [ 0, $text{'virtualmin_smode0'}."<br>" ]);
	}
push(@opts, [ 1, &text('virtualmin_smode1',
		       &ui_textbox($name."_serial", undef, 20),
		       &ui_textbox($name."_key", undef, 20))."<br>" ]);
if (&can_action(undef, "licence")) {
	my ($vaserial, $vakey) = &allocate_virtualmin_serial(1);
	if ($vaserial) {
		$cansame = 1;
		push(@opts, [ 2, $text{'virtualmin_smode2'}."<br>" ]);
		}
	my ($aserial, $akey) = &allocate_virtualmin_serial(0);
	if ($aserial) {
		push(@opts, [ 3, $text{'virtualmin_smode3'}."<br>" ]);
		$canalloc = 1;
		}
	}
if ($gpl) {
	# GPL mode, only for script install
	push(@opts, [ 4, $text{'virtualmin_smode4'}."<br>" ]);
	}
if (@opts > 1) {
	return &ui_radio($name, $cansame ? 2 :
				$canalloc ? 3 :
				$nonone ? 1 : 0, \@opts);
	}
else {
	return &ui_hidden($name, $opts[0]->[0]).$opts[0]->[1];
	}
}

# virtualmin_licence_parse(name, &in)
# Returns a serial number and key for Virtualmin, or undef and an error message
# explaining why the key is not valid
sub virtualmin_licence_parse
{
my ($name, $in) = @_;
if ($in->{$name} == 0) {
	# None needed
	return ();
	}
elsif ($in->{$name} == 1) {
	# Manually entered
	$in{$name."_serial"} =~ /^\S+$/ ||
		return (undef, $text{'virtualmin_eserial'});
	$in{$name."_key"} =~ /^\S+$/ ||
		return (undef, $text{'virtualmin_ekey'});
	my $lok = &check_virtualmin_serial($in{$name."_serial"},
					      $in{$name."_key"});
	$lok > 0 || return (undef, $text{'virtualmin_evalid'});
	return ($in{$name."_serial"}, $in{$name."_key"});
	}
elsif ($in->{$name} == 2 && &can_action(undef, "licence")) {
	# Same as Cloudmin
	&can_action(undef, "license") ||
		return (undef, $text{'virtualmin_ecannot'});
	return &get_server_manager_serial();
	}
elsif ($in->{$name} == 3 && &can_action(undef, "licence")) {
	# Allocate from pool
	&can_action(undef, "license") ||
		return (undef, $text{'virtualmin_ecannot'});
	my ($aserial, $akey) = &allocate_virtualmin_serial(0);
	return ($aserial, $akey);
	}
elsif ($in->{$name} == 4) {
	# Fixed GPL version
	return ("GPL", "GPL");
	}
else {
	return (undef, "Unknown licence mode!");
	}
}

# list_virtualmin_licences()
# Returns a list of serial numbers and keys that have been pre-registered
# for use by Virtualmin
sub list_virtualmin_licences
{
# Use cache if possible
if (defined(@list_virtualmin_licences_cache)) {
	return @list_virtualmin_licences_cache;
	}

# If the Cloudmin licence can also be used for Virtualmin, start with it
&lock_file($virtualmin_licences_file);
my @rv;
my ($vm2serial, $vm2key) = &get_server_manager_serial();
my %vm2cache;
&read_file($licence_cache_file, \%vm2cache);
if ($vm2cache{'max_last'} &&
    time() - $vm2cache{'max_last'} < 24*60*60) {
	# Use cached version
	push(@rv, \%vm2cache);
	}
else {
	# Check Cloudmin licence for real
	my ($lok, $ldoms, $lservers, $lexpiry) =
		&check_virtualmin_serial($vm2serial, $vm2key);
	if ($lok > 0) {
		%vm2cache = ( 'serial' => $vm2serial,
			      'key' => $vm2key,
			      'domains' => $ldoms,
			      'servers' => $lservers,
			      'expiry' => $lexpiry,
			      'max_last' => time(),
			      'vm2' => 1 );
		push(@rv, \%vm2cache);
		&write_file($licence_cache_file, \%vm2cache);
		}
	}

# Read the licence pool
open(LIC, $virtualmin_licences_file);
while(<LIC>) {
	s/\r|\n//g;
	my %lic = map { split(/=/, $_) } split(/\s+/, $_);
	if ($lic{'install'} && !kill(0, $lic{'install'})) {
		delete($lic{'install'});
		}
	push(@rv, \%lic);
	}
close(LIC);

# For licences that we don't have domain and server counts for, get them
# from Virtualmin. Re-do this every 24 hours, as the customer may have upgraded
foreach my $l (@rv) {
	if ($l->{'domains'} eq '' ||
	    time() - $l->{'max_last'} >= 24*60*60) {
		my ($lok, $ldoms, $lservers, $lexpiry) =
			&check_virtualmin_serial($l->{'serial'}, $l->{'key'});
		if ($lok == 0) {
			# Invalid!
			$l->{'invalid'} = 1;
			}
		elsif ($lok > 0) {
			delete($l->{'invalid'});
			$l->{'domains'} = $ldoms;
			$l->{'servers'} = $lservers;
			$l->{'expiry'} = $lexpiry;
			}
		$l->{'max_last'} = time();
		$changed = 1;
		}
	$l->{'users'} = [ ];
	}

# For each licence, find out which systems it is used on
my @servers = &list_managed_servers();
my %lmap = map { $_->{'serial'}, $_ } @rv;
foreach my $s (@servers) {
	if ($s->{'virtualmin_serial'}) {
		my $l = $lmap{$s->{'virtualmin_serial'}};
		if ($l) {
			push(@{$l->{'users'}}, $s);
			}
		}
	}

# For each licence, find in-progress installs and decrease the free count
&lock_file($virtualmin_progress_file);
my %progress;
&read_file($virtualmin_progress_file, \%progress);
foreach my $l (@rv) {
	$l->{'progress'} = 0;
	my @newprog;
	foreach my $p (split(/\s+/, $progress{$l->{'serial'}})) {
		if (kill(0, $p)) {
			$l->{'progress'}++;
			push(@newprog, $p);
			}
		}
	$progress{$l->{'serial'}} = join(' ', @newprog);
	}
&write_file($virtualmin_progress_file, \%progress);
&unlock_file($virtualmin_progress_file);

# For each licence, work out how many more servers it can be used on
foreach my $l (@rv) {
	if (!$l->{'invalid'}) {
		if ($l->{'servers'}) {
			$l->{'free'} = $l->{'servers'} -
				       scalar(@{$l->{'users'}}) -
				       $l->{'progress'};
			$l->{'free'} = 0 if ($l->{'free'} < 0);
			}
		else {
			$l->{'free'} = -1;	# Unlimited
			}
		}
	}

# Write out the licence list if changed
if ($changed) {
	&save_virtualmin_licences(\@rv);
	}
&unlock_file($virtualmin_licences_file);

@list_virtualmin_licences_cache = @rv;
return @rv;
}

# check_licence_expiry(&license|date)
# Returns 0 if some license is OK, 1 if close to expiry (7 days), 2 if expired
sub check_licence_expiry
{
my ($lic) = @_;
my $date = ref($lic) ? $lic->{'expiry'} : $lic;
if ($date =~ /^(\d{4})\-(\d+)\-(\d+)$/) {
	my $ut = timelocal(0, 0, 0, $3, $2-1, $1-1900);
	my $days = int(($ut - time()) / (24*60*60));
	return $days < 0 ? 2 : $days < 7 ? 1 : 0;
	}
else {
	return -1;
	}
}

# save_virtualmin_licences(&licences)
# Updates the Virtualmin licence pool
sub save_virtualmin_licences
{
my ($licences) = @_;
&open_lock_tempfile(LIC, ">$virtualmin_licences_file");
foreach my $l (@$licences) {
	next if ($l->{'vm2'});
	&print_tempfile(LIC, join(" ", map { $_."=".$l->{$_} }
				grep { $_ ne "users" &&
				       $_ ne "progress" } keys %$l)."\n");
	}
&close_tempfile(LIC);
}

# start_installing_virtualmin_licence(serial, key)
# Marks some serial number and key as being installed now
sub start_installing_virtualmin_licence
{
my ($serial, $key) = @_;
my %progress;
&lock_file($virtualmin_progress_file);
&read_file($virtualmin_progress_file, \%progress);
$progress{$serial} = join(' ', split(/\s+/, $progress{$serial}), $$);
&write_file($virtualmin_progress_file, \%progress);
&unlock_file($virtualmin_progress_file);
}

# start_installing_virtualmin_licence(serial, key)
# Marks some serial number and key as no longer being installed
sub stop_installing_virtualmin_licence
{
my ($serial, $key) = @_;
my %progress;
&lock_file($virtualmin_progress_file);
&read_file($virtualmin_progress_file, \%progress);
$progress{$serial} = join(' ', grep { $_ != $$ }
				    split(/\s+/, $progress{$serial}));
&write_file($virtualmin_progress_file, \%progress);
&unlock_file($virtualmin_progress_file);
}

# fetch_virtualmin_licences()
# Checks for new Virtualmin licences associated with the Cloudmin licence, and
# adds them. Returns an error message on failure, or a list of added licenses
# on success.
sub fetch_virtualmin_licences
{
my $id = &get_host_id();
my ($serial, $key) = &get_server_manager_serial();
my ($out, $error);
&http_download($virtualmin_licence_host,
	       $virtualmin_licence_port,
	       "$virtualmin_alllicences_prog?id=$id&serial=$key",
	       \$out, \$error, undef, $virtualmin_licence_ssl);
if ($out =~ /^BAD\s+(.*)/) {
	return $1;
	}
elsif ($out =~ /^OK\s+(\d+)/) {
	my @lics = &list_virtualmin_licences();
	my %got = map { $_->{'serial'}, $_ } @lics;
	my @lines = split(/\r?\n/, $out);
	shift(@lines);
	my @rv;
	foreach my $l (@lines) {
		my ($vserial, $vkey, $vend, $vdoms, $vservers) =
			split(/\s+/, $l);
		my $got = $got{$vserial};
		if ($got) {
			# Update existing details, to be one the safe side
			$got->{'domains'} = $vdoms;
			$got->{'servers'} = $vservers;
			}
		else {
			# Add to list
			my $lic = { 'serial' => $vserial,
				       'key' => $vkey,
				       'domains' => $vdoms,
				       'servers' => $vservers };
			push(@rv, $lic);
			push(@lics, $lic);
			}
		}
	&save_virtualmin_licences(\@lics);
	return \@rv;
	}
else {
	return "No Virtualmin licenses found";
	}
}

# can_all_licenses()
# Returns 1 if current Cloudmin license can be used to fetch associated Virtualmin
# licenses. Not true for EC2 shared keys.
sub can_all_licenses
{
my ($serial, $key) = &get_server_manager_serial();
return $key !~ /^AMAZON/i;
}

# list_all_script_updates(&servers)
# Fetch all possible script upgrades from multiple systems. Returns a list of
# hashes, each containing the details of one upgrade in one domain on one system
sub list_all_script_updates
{
my ($servers) = @_;
my @rv;
my @canservers = grep { $_->{'status'} eq 'virt' &&
			   $_->{'virtualmin_serial'} } @$servers;
my $temp = &transname();
&parallel_server_function(\@canservers, \&fetch_all_script_updates, $temp);
foreach my $s (@canservers) {
	my $data = &read_file_contents($temp.".".$s->{'id'});
	next if (!$data);
	my $updates = &unserialise_variable($data);
	foreach my $u (@$updates) {
		$u->{'server'} = $s;
		push(@rv, $u);
		}
	unlink($temp.".".$s->{'id'});
	}
return @rv;
}

# fetch_all_script_updates(&server, file)
# Fetch a list of script updates from some server, and serialize into a file
sub fetch_all_script_updates
{
my ($server, $tempbase) = @_;
$last_remote_error = undef;
&remote_foreign_require($server, "virtual-server", "virtual-server-lib.pl");
return undef if ($last_remote_error);
my $updates = &remote_eval($server, "virtual-server",
			'[ &list_script_upgrades([ &list_domains() ]) ]');
&open_tempfile(SERIAL, ">".$tempbase.".".$server->{'id'});
&print_tempfile(SERIAL, &serialise_variable($updates));
&close_tempfile(SERIAL);
}

# update_server_scripts(&server, &updates)
# Install all scripts from a set of possible updates on a Virtualmin server, via
# API calls.
sub update_server_scripts
{
my ($server, $updates) = @_;
my @rv;
foreach my $u (@$updates) {
	# Build API call args
	my @args = ( [ 'domain', $u->{'dom'}->{'dom'} ],
			[ 'type', $u->{'script'}->{'name'} ],
			[ 'upgrade', $u->{'sinfo'}->{'id'} ],
			[ 'version', $u->{'ver'} ],
		      );
	my ($err, $out) = &call_virtualmin_api($server, "install-script",
						  \@args);
	push(@rv, [ $u, $err, $out ]);
	}
return @rv;
}

sub can_edit_limits
{
my ($server) = @_;
my $cfunc = "type_".$server->{'manager'}."_can_cpu";
my $mfunc = "type_".$server->{'manager'}."_can_memory";
my $vfunc = "type_".$server->{'manager'}."_can_vcpus";
my $rfunc = "type_".$server->{'manager'}."_real_interfaces";
return defined(&$cfunc) && &$cfunc($server) ||
       defined(&$mfunc) && &$mfunc($server) ||
       defined(&$vfunc) && &$vfunc($server) ||
       defined(&$rfunc) && $config{'bw_enabled'};
}

# run_system_script(&system, when, action)
# Run the pre/post creation/deletion script, if defined, and tell the user
sub run_system_script
{
my ($server, $when, $action) = @_;
my $cmd = $config{$when.'_'.$action.'_cmd'};
return 1 if (!$cmd);

# Set environment variables
foreach $e (keys %ENVS) {
	delete($ENV{$e}) if ($e =~ /^SERVERMANAGER_/);
	}
$ENV{'SERVERMANAGER_WHEN'} = uc($when);
$ENV{'SERVERMANAGER_ACTION'} = uc($action);
foreach my $k (keys %$server) {
	$ENV{'SERVERMANAGER_'.uc($k)} = $server->{$k};
	}
if ($server->{'manager'} ne 'this' && $server->{'manager'} ne 'real') {
	# Add host variables too
	my $parent = &get_parent_server($server);
	if ($parent) {
		foreach my $k (keys %$parent) {
			$ENV{'SERVERMANAGER_PARENT_'.uc($k)} = $parent->{$k};
			}
		}
	}

&$first_print($text{'run_'.$when.'_'.$action});
my $out = &backquote_logged("($cmd) 2>&1 </dev/null");
if ($?) {
	&$second_print(&text('run_failed', "<tt>".&html_escape($out)."</tt>"));
	return 0;
	}
else {
	&$second_print($text{'create_done'});
	return 1;
	}
}

# get_parent_server(&server)
# Given a server, returns the one that hosts it or undef
sub get_parent_server
{
my ($server) = @_;
my $pfunc = "type_".$server->{'manager'}."_parent";
if (defined(&$pfunc)) {
	return &$pfunc($server);
	}
return undef;
}

# is_parent_server(&server)
# Returns a list of the system types this server hosts
sub is_parent_server
{
my ($server) = @_;
my @rv;
foreach my $t ('xen', 'kvm', 'vserver', 'zone', 'openvz', 'citrix') {
	if ($server->{$t."_host"}) {
		push(@rv, $t eq 'zone' ? 'zones' : $t);
		}
	}
return wantarray ? @rv : $rv[0];
}

# is_virtual_server(&server)
# Returns the manager type of some system is virtual
sub is_virtual_server
{
my ($server) = @_;
foreach my $t (@virtual_server_management_types) {
	return $t if ($server->{'manager'} eq $t);
	}
return undef;
}

# list_child_servers(&server, [&all-servers])
# Returns a list of other servers this one hosts. For each type it can host,
# check all other servers of that type to see if their parent is this one.
sub list_child_servers
{
my ($server, $allservers) = @_;
my @servers = $allservers ? @$allservers : &list_managed_servers();
my @rv;
foreach my $p (&is_parent_server($server)) {
	$p = "zones" if ($p eq "zone");
	my $pfunc = "type_".$p."_parent";
	if (defined(&$pfunc)) {
		foreach my $s (grep { $_->{'manager'} eq $p } @servers) {
			my $par = &$pfunc($s, \@servers);
			if ($par && $par->{'id'} eq $server->{'id'}) {
				push(@rv, $s);
				}
			}
		}
	}
return @rv;
}

# show_ip_range_input(starts, ends, cidrs, [gateways,
# 		      interfaces, &possible-ifaces])
# show_ip_range_input(&server, prefix, show-gateways, &possible-ifaces)
# Returns HTML for entering 1 or more IP allocation ranges
sub show_ip_range_input
{
my ($server, $pfx, $show_gateways, $poss) = @_;
my @pools = split(/\s+/, $server->{$pfx."_pool"});
my @starts = split(/\s+/, $server->{$pfx."_start"});
my @ends = split(/\s+/, $server->{$pfx."_end"});
my @cidrs = split(/\s+/, $server->{$pfx."_cidr"});
my @ifaces = split(/\s+/, $server->{$pfx."_ifaces"});
my @gws = map { $_ eq '*' ? '' : $_ } split(/\s+/, $server->{$pfx."_gws"});

# Table headings for pools
my @cols = ( $text{'range_pool'} );
if ($poss) {
	push(@cols, $text{'range_iface'});
	}
if (@starts) {
	push(@cols, $text{'range_count'}, $text{'range_used'});
	}

# Add rows for IP pools, if any
my $table;
my @allpools = &list_ip_pools();
$table .= &ui_hidden("show_gateways", $show_gateways);
if (@allpools) {
	$table .= &ui_columns_start(\@cols, 100, 0, [ "width=75%" ]);
	for(my $i=0; $i<=@pools; $i++) {
		my @cols = (
		    &ui_select("pool_$i", $pools[$i],
			[ [ '', '&nbsp;' ],
			   map { my $desc = &describe_ip_range($_->{'start'},
							       $_->{'end'},
							       $_->{'cidr'});
				 [ $_->{'id'},
				   $desc." ".
				   ($_->{'desc'} ? " (".$_->{'desc'}.")" : "")
				 ] } @allpools ]),
		    );
		if ($poss) {
			push(@cols, &ui_select("piface_$i",
				       !$pools[$i] ? '*' : $ifaces[$i] || '*',
				       [ [ '*', $text{'range_any'} ], @$poss ],
				       1, 0, 1));
			}
		if ($starts[$i]) {
			my ($count, $used) = &get_ip_range_usage($starts[$i],
								 $ends[$i]);
			push(@cols, $count, $used);
			}
		elsif (@starts) {
			push(@cols, '', '');
			}
		$table .= &ui_columns_row(\@cols);
		}
	$table .= &ui_columns_end();
	}

# Exclude ranges from pools in manual list
foreach my $p (@pools) {
	shift(@starts);
	shift(@ends);
	shift(@cidrs);
	shift(@gws);
	shift(@ifaces);
	}

# Table headings for manual ranges
my @cols = ( $text{'range_start'}, $text{'range_end'}, $text{'range_cidr'} );
if ($show_gateways) {
	push(@cols, $text{'range_gw'});
	}
if ($poss) {
	push(@cols, $text{'range_iface'});
	}
if (@starts) {
	push(@cols, $text{'range_count'}, $text{'range_used'});
	}

# Add rows for manually entered IP ranges, if there are no pools
if (!@allpools || @starts) {
	$table .= &ui_columns_start(\@cols, 100, 0,
			[ "width=20%", "width=20%", "width=10%" ]);
	for(my $i=0; $i<=@starts; $i++) {
		my @cols = ( &ui_textbox("start_$i", $starts[$i], 15),
			     &ui_textbox("end_$i", $ends[$i], 15),
			     &ui_textbox("cidr_$i", $cidrs[$i], 5) );
		if ($show_gateways) {
			push(@cols, &ui_textbox("gw_$i", $gws[$i], 15));
			}
		if ($poss) {
			push(@cols, &ui_select("iface_$i", $ifaces[$i] || '*',
				       [ [ '*', $text{'range_any'} ], @$poss ],
				       1, 0, 1));
			}
		if ($starts[$i]) {
			my ($count, $used) = &get_ip_range_usage($starts[$i],
								 $ends[$i]);
			push(@cols, $count, $used);
			}
		elsif (@starts) {
			push(@cols, '', '');
			}
		$table .= &ui_columns_row(\@cols);
		}
	$table .= &ui_columns_end();
	}
return $table;
}

# parse_ip_range_input(&in, &server, prefix)
# Parse the form generated by show_ip_range_input, and updates lists of start,
# end and cidr addresses, and maybe gateways and interfaces in the given server
# object.
sub parse_ip_range_input
{
my ($in, $server, $pfx) = @_;
my (@starts, @ends, @cidrs, @gws, @ifaces, @pools);

# Parse IP pools table
my %allpools = map { $_->{'id'}, $_ } &list_ip_pools();
my $pid;
for(my $i=0; defined($pid = $in->{"pool_$i"}); $i++) {
	next if (!$pid);
	my $p = $allpools{$pid};
	next if (!$p);
	push(@pools, $pid);
	push(@starts, $p->{'start'});
	push(@ends, $p->{'end'});
	push(@cidrs, $p->{'cidr'});
	if ($in->{'show_gateways'}) {
		push(@gws, $p->{'gateway'} || "*");
		}
	if (defined($in->{"piface_$i"})) {
		push(@ifaces, $in->{"piface_$i"});
		}
	}

# Parse manual IPs table
for(my $i=0; defined($in->{"start_$i"}); $i++) {
	next if ($in->{"start_$i"} !~ /\S/);
	&check_ipaddress($in->{"start_$i"}) ||
		&error(&text('range_estart', $i+1));
	&check_ipaddress($in->{"end_$i"}) ||
		&error(&text('range_eend', $i+1));
	if (&check_ipaddress($in->{"cidr_$i"})) {
		# Netmask .. convert to cidr
		$in->{"cidr_$i"} = &net::mask_to_prefix($in->{"cidr_$i"});
		}
	else {
		# Validate cidr
		$in->{"cidr_$i"} =~ /^\d+$/ &&
		  $in->{"cidr_$i"} > 0 &&
		  $in->{"cidr_$i"} <= 32 || &error(&text('range_ecidr', $i+1));
		}
	my $startnum = &net::ip_to_integer($in->{"start_$i"});
	my $endnum = &net::ip_to_integer($in->{"end_$i"});
	$startnum <= $endnum || &error(&text('range_erange', $i+1));
	push(@starts, $in->{"start_$i"});
	push(@ends, $in->{"end_$i"});
	push(@cidrs, $in->{"cidr_$i"});
	if (defined($in->{"gw_$i"})) {
		if (!$in->{"gw_$i"}) {
			push(@gws, "*");
			}
		else {
			&check_ipaddress($in->{"gw_${i}"}) ||
				&error(&text('range_egw', $i+1));
			push(@gws, $in->{"gw_${i}"});
			}
		}
	if (defined($in->{"iface_$i"})) {
		push(@ifaces, $in->{"iface_$i"});
		}
	}

# Validate and store resulting lists
@starts || &error($text{'range_enone'});
$server->{$pfx."_pool"} = join(" ", @pools);
$server->{$pfx."_start"} = join(" ", @starts);
$server->{$pfx."_end"} = join(" ", @ends);
$server->{$pfx."_cidr"} = join(" ", @cidrs);
if (@gws || @ifaces) {
	$server->{$pfx."_gws"} = join(" ", @gws);
	}
if (@ifaces) {
	$server->{$pfx."_ifaces"} = join(" ", @ifaces);
	}
}

# show_disk_reboot_message(&server, &disk)
# Prints a form prompting for a reboot if needed after some disk change
sub show_disk_reboot_message
{
my ($server, $disk) = @_;
my $rfunc = "type_".$server->{'manager'}."_need_disk_reboot";
if ($server->{'status'} ne 'down' &&
    defined(&$rfunc) && &$rfunc($server, $disk)) {
	print &ui_form_start("save_serv.cgi");
	print &ui_hidden("id", $in{'id'});
	print &ui_hidden("reboot", 1);
	print &ui_hidden("confirm", 1);
	print &ui_hidden("updown", 1);
	print "<b>$text{'disk_needreboot'}</b><p>\n";
	print &ui_form_end([ [ undef, $text{'limits_reboot'} ] ]);
	}
}

# find_server_manager_cron_job(command, [&jobs], [user])
# Returns the cron job object that runs some command (perhaps with redirection)
sub find_server_manager_cron_job
{
my ($cmd, $jobs, $user) = @_;
if (!$jobs) {
	&foreign_require("cron", "cron-lib.pl");
	$jobs = [ &cron::list_cron_jobs() ];
	}
$user ||= "root";
my @rv = grep { $_->{'user'} eq $user &&
	     $_->{'command'} =~ /(^|[ \|\&;])\Q$cmd\E($|[ \|\&><;])/ } @$jobs;
return wantarray ? @rv : $rv[0];
}

# get_global_from_address(&server)
# Returns the from address to use when sending email to some server.
sub get_global_from_address
{
my ($server) = @_;
&foreign_require("mailboxes", "mailboxes-lib.pl");
my $rv = $config{'from_addr'} || &mailboxes::get_from_address();
return $rv;
}

# host_free_desc(&vhost, [manager])
# Returns a string listing free disk space and RAM for some host
sub host_free_desc
{
my ($vhost, $manager) = @_;
return "" if (!can_action(undef, "global"));
my @rv;
my $freedisk = &host_free_disk($vhost, $manager);
if ($freedisk) {
	push(@rv, &text('create_hostdisk', &nice_size($freedisk)));
	}
my $freemem = &host_free_memory($vhost, $manager);
if ($freemem) {
	push(@rv, &text('create_hostmem', &nice_size($freemem)));
	}
return @rv ? " (".join(", ", @rv).")" : "";
}

# host_free_disk(&host, manager, [&for-server])
# Returns the amount of disk space free on some host system, perhaps in LVM.
# In an array context, returns the total disk too.
sub host_free_disk
{
my ($vhost, $manager, $server) = @_;
my $vinfo = &get_server_collected($vhost);
my @rv;
my $lvm = $vhost->{$manager.'_vg_free'} &&
	  (!$server || $server->{$manager.'_filesystem_vg'});
if ($manager && $lvm) {
	@rv = ( $vhost->{$manager.'_vg_free'}, $vhost->{$manager.'_vg_total'} );
	}
elsif ($vinfo && $vinfo->{'disk_free'}) {
	@rv = ( $vinfo->{'disk_free'}, $vinfo->{'disk_total'} );
	}
return wantarray ? @rv : $rv[0];
}

# host_free_memory(&host, manager)
# Returns the amount of RAM free on some host system, perhaps taking Xen host
# memory into account
sub host_free_memory
{
my ($vhost, $manager) = @_;
my $vinfo = &get_server_collected($vhost);
if ($manager && $vhost->{$manager.'_mem_free'}) {
	return $vhost->{$manager.'_mem_free'};
	}
elsif ($vinfo && $vinfo->{'mem'}) {
	return $vinfo->{'mem'}->[1]*1024;
	}
return undef;
}

# usable_host_system(&server, manager, extra-ram, extra-disk)
# Checks if some host system is has enough RAM and disk free to host another
# virtual system.
sub usable_host_system
{
my ($vhost, $manager, $mem, $disk) = @_;

# Check how much RAM and disk is free now
my $diskfree = &host_free_disk($vhost, $manager);
my $memfree = &host_free_memory($vhost, $manager);

# Take away RAM assigned to down systems
if ($vhost->{'floor_mem_down'}) {
	foreach my $s (&list_managed_servers()) {
		next if ($s->{'status'} ne 'down');
		my $v = &get_parent_server($s);
		next if ($v->{'id'} ne $vhost->{'id'});
		my $mfunc = "type_".$s->{'manager'}."_get_memory_size";
		if (defined(&$mfunc)) {
			$memfree -= &$mfunc($s);
			}
		}
	}

# See if we are under
if (defined($diskfree) && $diskfree-$disk <= 0) {
	# Would use up all the disk
	return wantarray ? (0, &text('floor_nodisk2',
				     &nice_size($disk-$diskfree))) : 0;
	}
if (defined($diskfree) && $diskfree-$disk < $vhost->{'floor_disk'}) {
	# Not enough disk
	return wantarray ?
	    (0, &text('floor_nodisk', &nice_size($diskfree-$disk),
				      &nice_size($vhost->{'floor_disk'}))) : 0;
	}
if (defined($memfree) && $memfree-$mem <= 0) {
	# Would use up all the RAM
	return wantarray ? (0, &text('floor_nomem2',
				     &nice_size($mem-$memfree))) : 0;
	}
if (defined($memfree) && $memfree-$mem < $vhost->{'floor_mem'}) {
	# Not enough RAM
	return wantarray ?
	    (0, &text('floor_nomem', &nice_size($memfree-$mem),
				     &nice_size($vhost->{'floor_mem'}))) : 0;
	}
return wantarray ? ( 1 ) : 1;
}

# get_provider_link()
# Returns HTML for the logo that should be displayed in the theme for the
# Virtualmin hosting provider. In an array context, also returns the image
# URL and link URL, if set.
sub get_provider_link
{
# Does this owner have a logo
my ($logo, $link);
($logo, $link) = ($access{'theme_image'}, $access{'theme_link'});
if (!$logo) {
        # Call back to global config
        $logo = $config{'theme_image'} || $gconfig{'vm2_theme_image'};
        $link = $config{'theme_link'} || $gconfig{'vm2_theme_link'};
        }
if ($logo && $logo ne "none") {
        my $html;
        $html .= "<a href='$link' target=_new>" if ($link);
        $html .= "<img src='$image' border=0>";
        $html .= "</a>" if ($link);
        return wantarray ? ( $html, $logo, $link ) : $html;
        }
else {
        return wantarray ? ( ) : undef;
        }
}

# move_system(&system, &dest, [shutdown], [reallocate-ip])
# Moves a virtual system to a host hosting server, which is assumed to be
# able to support it. Calls the appropriate type-specific move function to
# do most of the work. Returns undef on success or an error message on failure.
# May print stuff.
sub move_system
{
my ($server, $dest, $shutdown, $allocate) = @_;
my @pars = &is_parent_server($dest);
my $dfunc = "type_".$server->{'manager'}."_desc";
my $desc = &$dfunc($server);
&indexof($server->{'manager'}, @pars) >= 0 ||
	return "Destination system $dest->{'host'} cannot host $desc systems";
my $vhost = &get_parent_server($server);
$vhost->{'id'} ne $dest->{'id'} ||
	return "Source and destination host systems are the same!";

# Check if moving is supported
my $cfunc = "type_".$server->{'manager'}."_can_move";
if (!defined(&$cfunc) || !&$cfunc($server, $dest)) {
	return "The $desc system $server->{'host'} cannot be moved to $dest->{'host'}";
	}

# Check for resource limits on the target
my ($disk, $mem);
my $dfunc = "type_".$server->{'manager'}."_get_disk_size";
if (defined(&$dfunc)) {
	$disk = &$dfunc($server);
	}
my $sfunc = "type_".$server->{'manager'}."_get_disk_space";
if (!$disk && defined(&$sfunc)) {
	$disk = &$sfunc($server);
	}
my $mfunc = "type_".$server->{'manager'}."_get_memory";
if (defined(&$mfunc)) {
	$mem = &$mfunc($server);
	}
my ($ok, $err) = &usable_host_system($dest, $server->{'manager'}, $mem, $disk);
if (!$ok) {
	return "The host system $dest->{'host'} is not suitable : $err";
	}

# Do the actual move
my $mfunc = "type_".$server->{'manager'}."_move_system";
my $err = &$mfunc($server, $dest, $shutdown, $allocate);

# Refresh status
&$first_print($text{'save_refreshing'});
&check_server_status($server, 0, 1);
&save_managed_server($server);
&$second_print(&text('save_refreshdone2',
	&describe_status($server, 1, 1)));

return $err;
}

# manual_move_system(&system, &dest)
# Updates the Cloudmin config to reflect an already-done manual move of some
# system to a new host. May print stuff.
sub manual_move_system
{
my ($server, $dest) = @_;
my @pars = &is_parent_server($dest);
my $dfunc = "type_".$server->{'manager'}."_desc";
my $desc = &$dfunc($server);
&indexof($server->{'manager'}, @pars) >= 0 ||
	return "Destination system $dest->{'host'} cannot host $desc systems";
my $vhost = &get_parent_server($server);
$vhost->{'id'} ne $dest->{'id'} ||
	return "Source and destination host systems are the same!";

# Check if moving is supported
my $cfunc = "type_".$server->{'manager'}."_can_move";
if (!defined(&$cfunc) || &$cfunc($server, $dest) != 2) {
	return "The $desc system $server->{'host'} cannot be manually moved to $dest->{'host'}";
	}

# Do the actual move
my $mfunc = "type_".$server->{'manager'}."_manual_move_system";
my $err = &$mfunc($server, $dest, $shutdown, $allocate);

# Refresh status
&$first_print($text{'save_refreshing'});
&check_server_status($server, 0, 1);
&save_managed_server($server);
&$second_print(&text('save_refreshdone2',
	&describe_status($server, 1, 1)));

return $err;
}

# reset_system(&system)
# Resets a virtual system to its original image. 
sub reset_system
{
my ($server) = @_;

# Get the current Virtualmin serial and key, if any
my $info = &get_server_collected($server);
my ($serial, $key);
if ($info && $info->{'serial'}) {
	$serial = $info->{'serial'}->{'serial'};
	$key = $info->{'key'}->{'key'};
	}

# If running, shut down
my $was_up = 0;
if ($server->{'status'} ne 'down') {
	&$first_print($text{'reset_shutting'});
	$err = &shutdown_server($server);
	if ($err) {
		return &text('smove_shutfailed', $err);
		}
	$server->{'status'} = 'down';	# Assume it worked
	$was_up = 1;
	&$second_print($text{'create_done'});
	}

# Transfer across the original image
my $img = &get_server_image($server->{'image'});
my $vhost = &get_parent_server($server);
&$first_print(&text('create_copying', &nice_size($img->{'size'}),
				      $vhost->{'host'}));
my ($imageok, $imagetemp) = &transfer_image_files($server, 1);
if ($imageok == 0) {
	return &text('create_ecopy', $imagetemp);
	}
else {
	$server->{'imagetemp'} = $imagetemp;
	$server->{'imagelocal'} = ($imageok != 1);
	&$second_print($imageok == 1 ? $text{'create_done'} :
		       $imageok == 2 ? $text{'create_nocopy'} :
		       $imageok == 3 ? $text{'create_incache'} :
			 	       $text{'create_addcache'});
	}

# Clear any custom SSH port, as the reset will revert to the default
delete($server->{'ssh_port'});

# Start creation process and wait for it to complete
&$first_print($text{'reset_recreating'});
my $cfunc = "type_".$server->{'manager'}."_create";
my $err = &$cfunc($server, $serial, $key, 1);
if ($err) {
	return &text('create_ecreate', $err);
	}
my $dfunc = "type_".$server->{'manager'}."_create_done";
&$second_print($text{'create_created'});
&$first_print($text{'create_waiting'});
while(1) {
	my $err = &$dfunc($server);
	if ($err eq "OK") {
		last;
		}
	elsif ($err) {
		if ($imageok == 1) {
			&cleanup_image_files($server, $imagetemp);
			}
		return &text('create_ewait', $err);
		}
	sleep(1);
	}
&$second_print($text{'create_waited'});

# Clean up image files
if ($imageok == 1) {
        &cleanup_image_files($server, $imagetemp);
        }
&save_managed_server($server);

# Remove old SSH keys for this system
&clear_ssh_host_key($server);

# Call any post-creation function
$dfunc = "type_".$server->{'manager'}."_create_post";
if (defined(&$dfunc)) {
        &$dfunc($server, $serial, $key, 1);
        }

# Wait for SSH login
my ($sshstatus, $ssherr, $webmindir, $webminport, $webminssl);
my $bfunc = "type_".$server->{'manager'}."_needs_boot";
if ($server->{'no_sshlogin'} && defined(&$bfunc) && &$bfunc($server)) {
	&$first_print($text{'create_sshing'});
	my $sshcount = 0;
	while(1) {
		($sshstatus, $ssherr, $webmindir, $webminport, $webminssl) =
			&check_server_ssh_login($server);
		if ($sshstatus == 0) {
			# All OK
			&$second_print($text{'create_sshdone'});
			last;
			}
		elsif ($sshcount > 120) {
			# Timeout
			&$second_print(&text('create_sshfailed', 120, $ssherr));
			last;
			}
		$sshcount++;
		sleep(1);
		}
	}
if (!$webmindir) {
        ($sshstatus, $ssherr, $webmindir, $webminport, $webminssl) =
		&check_server_ssh_login($server);
	}

# Wait for Webmin to start, if we have it
if ($webmindir) {
        &$first_print($text{'create_webminstarting'});
        my $err = &wait_webmin_server($server, 60);
        if (!$err) {
                &$second_print($text{'create_webminstarted'});
                }
        else {
                &$second_print(&text('create_webminnostart', 60, $err));
                }
	}

# Call any really final post-creation function
my $dfunc = "type_".$server->{'manager'}."_create_ready";
if (defined(&$dfunc)) {
        &$dfunc($server, $serial, $key);
        }

# Refresh status, forcing a full re-collection
&$first_print($text{'save_refreshing'});
&save_server_domains($server, [ ]);
&save_server_collected($server, undef);
&check_server_status($server, 1);
&save_managed_server($server);
&$second_print(&text('save_refreshdone2',
	&describe_status($server, 1, 1)));

return undef;
}

# substitute_virtualmin_template(string, &hash)
# Just exists to be called from newfeatures-lib.pl
sub substitute_virtualmin_template
{
my ($str, $hash) = @_;
return &substitute_template($str, $hash);
}

# get_search_form_mode(&in)
sub get_search_form_mode
{
my ($in) = @_;
foreach my $i ('gok', 'pok', 'eok', 'sok', 'ok') {
	return $i if ($in->{$i});
	}
return undef;
}

# show_search_form(&in, &candiate-servers)
# Return a grid of inputs for searching for systems, with fields filled in
sub show_search_form
{
my ($in, $servers) = @_;
my @grid = ( );
my $mode = &get_search_form_mode($in) || $in->{'oldmode'};

sub highlight_field
{
my ($msg, $but) = @_;
$msg = "<b>$msg</b>";
$msg = "<i>$msg</i>" if ($mode eq $but);
return $msg;
}

# Search by hostname or desc
push(@grid, &highlight_field($text{'index_search'}, "ok"));
push(@grid, &ui_textbox("search", $in->{'search'}, 30).
	    " ".&ui_submit($text{'index_searchok'}, "ok"));

# Search by group
my @groups = &unique(map { split(/\t/, $_->{'group'}) } @$servers);
if (@groups) {
	push(@grid, &highlight_field($text{'index_gsearch'}, "gok"));
	push(@grid, &ui_select("gsearch", $in->{'gsearch'}, \@groups).
		    " ".&ui_submit($text{'index_searchgok'}, "gok"));
	}

# Search by host system
my @parents = grep { &is_parent_server($_) } @$servers;
if (@parents) {
	@parents = sort { $a->{'host'} cmp $b->{'host'} } @parents;
	push(@grid, &highlight_field($text{'index_psearch'}, "pok"));
	push(@grid, &ui_select("psearch", $in->{'psearch'},
	    [ map { [ $_->{'id'}, $_->{'host'} ] } @parents ]).
		    " ".&ui_submit($text{'index_searchpok'}, "pok"));
	}

# Search by status (including some useful pseudo-statuses)
push(@grid, &highlight_field($text{'index_ssearch'}, "sok"));
push(@grid, &ui_select("ssearch", $in->{'ssearch'} || 'up',
		[ [ 'up', "&lt;$text{'status_up'}&gt;" ],
		  [ 'wm', "&lt;$text{'status_wm'}&gt;" ],
		  [ 'bad', "&lt;$text{'status_bad'}&gt;" ],
		  [ 'updates', "&lt;$text{'status_updates'}&gt;" ],
		  map { [ $_->[0], $text{'status_'.$_->[0]} ] }
		      @server_statuses ]).
	    " ".&ui_submit($text{'index_searchsok'}, "sok"));

# Search by EC2 account (normally hidden)
if ($mode eq 'eok') {
	push(@grid, &highlight_field($text{'index_esearch'}, "eok"));
	push(@grid, &ui_select("esearch", $in->{'esearch'},
	    [ map { [ $_->{'id'}, $_->{'account'} ] }
		  &list_ec2_accounts() ]).
		    " ".&ui_submit($text{'index_searcheok'}, "eok"));
	}

return &ui_grid_table(\@grid, 4, 100,
	[ "width=10%", "width=40%", "width=10%", "width=40%" ]).
       &ui_hidden("oldmode", $mode);
}

# apply_search_form(&in, &servers)
# Given a list of servers and a search criteria from show_search_form, return
# only those servers which match
sub apply_search_form
{ 
my ($in, $servers) = @_;
my $mode = &get_search_form_mode($in) || $in->{'oldmode'};

if ($mode eq 'gok') {
	# Search by group
	return grep { my @g = split(/\t/, $_->{'group'});
			&indexof($in->{'gsearch'}, @g) >= 0 } @$servers;
	}
elsif ($mode eq 'pok') {
	# Search by parent
	my ($parent) = grep { $_->{'id'} eq $in->{'psearch'} } @$servers;
	return grep { my $p = &get_parent_server($_);
		  $p && $p->{'id'} eq $parent->{'id'} } @$servers;
	}
elsif ($mode eq 'eok') {
	# Search by EC2 account
	my ($ec2) = grep { $_->{'id'} == $in->{'esearch'} }
		      &list_ec2_accounts();
	return grep { $_->{'ec2'} == $in->{'esearch'} } @$servers;
	}
elsif ($mode eq 'sok') {
	# Search by status
	my @sts;
	if ($in->{'ssearch'} eq 'up') {
		@sts = ( 'nowebmin', 'novirt', 'virt', 'alive' );
		}
	elsif ($in->{'ssearch'} eq 'wm') {
		@sts = ( 'novirt', 'virt' );
		}
	elsif ($in->{'ssearch'} eq 'bad') {
		@sts = ( 'down', 'noping', 'nohost', 'nossh', 'nosshlogin',
			 'downwebmin', 'nowebminlogin' );
		}
	else {
		@sts = ( $in->{'ssearch'} );
		}
	if ($in->{'ssearch'} eq 'updates') {
		# Search by updates
		return grep { $_->{'virtualmin_poss'} ||
			      $_->{'all_poss'} } @$servers;
		}
	else {
		# By regular status
		return grep { &indexof($_->{'status'}, @sts) >= 0 }
				@$servers;
		}
	}
else {
	# By hostname
	my $s = $in->{'search'};
	return grep { $_->{'host'} =~ /\Q$s\E/i ||
		      $_->{'desc'} =~ /\Q$s\E/i } @$servers;
	}
}

# show_webmin_login_form([&server], [type])
# Outputs fields for selecting the Webmin login and password for a system
sub show_webmin_login_form
{
my ($server, $type) = @_;
$type ||= $server->{'manager'} if ($server);
my $sfunc = "type_".$type."_no_ssh";
my $no_ssh = defined(&$sfunc) && &$sfunc();
my $newserver = !$server || !$server->{'id'};

# Webmin login
print &ui_hidden("webmin_newserver", $newserver);
print &ui_table_row($text{'add_webmin'},
	&ui_radio("webmin_mode", !$server ? 0 :
				 $server->{'ssh_pass_same'} ? 1 :
				 $server->{'user'} ? 2 : 0,
	      [ [ 0, ($newserver ? $text{'add_webmin0'}
				 : $text{'add_webmin0a'})."<br>" ],
		$no_ssh ? ( ) : ( [ 1, $text{'add_webmin1'}."<br>" ] ),
		[ 2, &text('add_webmin2',
			  &ui_textbox("wuser", $server ? $server->{'user'}
						       : "root", 20),
			  &ui_textbox("wpass", $server ? $server->{'pass'}
						       : "", 20)) ] ])."<br>".
	&ui_checkbox("ssl", 1, $text{'add_ssl'},
		     $server ? $server->{'ssl'} : 1));

# Webmin port
print &ui_table_row($text{'add_port'},
	&ui_textbox("port", $server ? $server->{'port'} : 10000, 6));
}

# parse_webmin_login_form(&in, &server)
# Parses the form generated by show_webmin_login_form and updates 
# the given server object. Returns undef on success or an error message 
# on failure.
sub parse_webmin_login_form
{
my ($in, $server) = @_;

if ($in->{'webmin_mode'} == 1) {
	# Password is same as SSH
	$server->{'ssh_pass'} || return $text{'add_emode1'};
	$server->{'user'} = $server->{'ssh_user'};
	$server->{'pass'} = $server->{'ssh_pass'};
	$server->{'ssh_pass_same'} = 1;
	$server->{'no_webmin_login'} = 0;
	}
elsif ($in->{'webmin_mode'} == 2) {
	# Username and password given
	$in->{'wuser'} =~ /^\S+$/ || return $text{'add_ewuser'};
	$server->{'user'} = $in->{'wuser'};
	$in->{'wpass'} =~ /\S/ || return $text{'add_ewpass'};
	$server->{'pass'} = $in->{'wpass'};
	$server->{'ssh_pass_same'} = 0;
	$server->{'no_webmin_login'} = 0;
	}
else {
	# No Webmin
	delete($server->{'user'});
	delete($server->{'pass'});
	$server->{'ssh_pass_same'} = 0;
	if (!$in->{'webmin_newserver'}) {
		$server->{'no_webmin_login'} = 1;
		}
	}
$server->{'ssl'} = $in->{'ssl'} ? 1 : 0;
$in->{'port'} =~ /^\d+$/ || return $text{'add_eport'};
$server->{'port'} = $in->{'port'};
return undef;
}

# copy_webmin_login_details(&source, &dest)
# Copy Webmin login fields from one server to another
sub copy_webmin_login_details
{
my ($src, $dst) = @_;
foreach my $f ('user', 'pass', 'ssh_pass_same', 'ssl', 'port') {
	$dst->{$f} = $src->{$f};
	}
}

# show_ssh_login_form([&server], [type])
# Outputs fields for selecting the SSH login and password or key for a system.
# May not output anything if the system type doesn't support or need SSH.
sub show_ssh_login_form
{
my ($server, $type) = @_;
$type ||= $server->{'manager'} if ($server);

my $sfunc = "type_".$type."_no_ssh";
my $no_ssh = defined(&$sfunc) && &$sfunc();
return if ($no_ssh);

# Root password / key
my $must_pass = !&can_action(undef, "sshkeys") &&
	        !$server->{'key'} &&
		!$server->{'ssh_nologin'};
if ($must_pass) {
	# Cannot select SSH keys
	print &ui_table_row($text{'add_authpass'},
		&ui_textbox("upass", undef, 20));
	}
else {
	# Can choose password, key or no SSH
	print &ui_table_row($text{'add_auth'},
		&ui_radio("auth_mode", !$server ? 0 :
				       $server->{'ssh_nologin'} ? 2 :
				       $server->{'key'} ? 1 : 0,
		      [ [ 0, &text('add_auth0',
			   &ui_textbox("upass", $server ? $server->{'ssh_pass'}
							: undef, 20))."<br>" ],
			[ 1, &text('add_auth1',
				&ssh_key_menu("key", $type,
					$server ? $server->{'key'}
						: undef))."<br>" ],
			[ 2, $text{'add_auth2'} ] ]));
	}

# SSH protocol version
print &ui_table_row($text{'add_protocol'},
	&ui_radio("protocol", $server ? $server->{'ssh_protocol'} : 2,
		  [ [ 2 ], [ 1 ] ]));

# Root login
print &ui_table_row($text{'add_user'},
	&ui_textbox("uuser", $server ? $server->{'ssh_user'}
				     : "root", 20));

# SSH port number
print &ui_table_row($text{'add_sshport'},
	&ui_opt_textbox("uport", $server ? $server->{'ssh_port'}
					 : undef, 5, $text{'default'}." (22)"));
}

# parse_ssh_login_form(&in, &server)
# Update a server object based on inputs from show_ssh_login_form. Returns undef
# on success, or an error message on failure.
sub parse_ssh_login_form
{
my ($in, $server) = @_;
return undef if (!defined($in->{'auth_mode'}));		# No SSH mode
my $must_pass = !&can_action(undef, "sshkeys") &&
	        !$server->{'key'} &&
		!$server->{'ssh_nologin'};

$in->{'uuser'} =~ /^[a-z0-9\.\-\_]+$/i || return $text{'add_euuser'};
$server->{'ssh_user'} = $in->{'uuser'};
if (!$in->{'uport_def'}) {
	$in->{'uport'} =~ /^\d+$/ && $in->{'uport'} > 0 &&
	    $in->{'uport'} < 65536 || return $text{'add_euport'};
	$server->{'ssh_port'} = $in->{'uport'};
	}
else {
	delete($server->{'ssh_port'});
	}
if ($in->{'auth_mode'} == 0 || $must_pass) {
	# Via password
	$in->{'upass'} || return $text{'add_eupass'};
	$server->{'ssh_pass'} = $in->{'upass'};
	delete($server->{'key'});
	$server->{'ssh_nologin'} = 0;
	}
elsif ($in->{'auth_mode'} == 1) {
	# Via SSH key
	$in->{'key'} || return $text{'add_ekey'};
	$server->{'key'} = $in->{'key'};
	delete($server->{'ssh_pass'});
	$server->{'ssh_nologin'} = 0;
	}
elsif ($in->{'auth_mode'} == 2) {
	# No SSH login should be tried
	$server->{'ssh_nologin'} = 1;
	}
$server->{'ssh_protocol'} = $in->{'protocol'};
return undef;
}

# copy_ssh_login_details(&source, &dest)
# Copy SSH login fields from one server to another
sub copy_ssh_login_details
{
my ($src, $dst) = @_;
foreach my $f ('ssh_user', 'ssh_port', 'ssh_pass', 'ssh_nologin',
	       'ssh_protocol') {
	$dst->{$f} = $src->{$f};
	}
}

# list_available_host_servers(type, [extra-ram, extra-disk])
# Returns a list of systems that can host some virtualization type, and
# are up and running. Also takes RAM and disk needs into account.
sub list_available_host_servers
{
my ($type, $mem, $disk) = @_;
my $alttype = $type eq "zones" ? "zone" : $type;
my @vhosts = grep { ($_->{$type.'_host'} || $_->{$alttype.'_host'}) &&
                    &can_host_server($_) } &list_managed_servers();
@vhosts = grep { $_->{'status'} eq 'nowebmin' ||
		 $_->{'status'} eq 'novirt' ||
		 $_->{'status'} eq 'virt' } @vhosts;
@vhosts = grep { &usable_host_system($_, $type, $mem, $disk) } @vhosts;
return @vhosts;
}

# find_host_server(&server, host-type, [extra-ram, extra-disk])
# Returns a host system for some type (xen, vserver, zone), based on those
# available to the system owner and available RAM / etc
sub find_host_server
{
my ($server, $type, $mem, $disk) = @_;
my @vhosts = &list_available_host_servers($type, $mem, $disk);
return undef if (!@vhosts);
return &find_host_server_from_vhosts($server, \@vhosts, $access{'hostmode'},
				     $type);
}

# find_host_server_from_vhosts(&server, &vhosts, host-allocation-mode,
# 			       host-type)
# Finds the best host system from a list
sub find_host_server_from_vhosts
{
my ($server, $vhosts, $hostmode, $type) = @_;
my @vhosts = @$vhosts;
if ($hostmode eq 'mem') {
	# Sort by free memory, get best
	my %memmap;
	foreach my $vhost (@vhosts) {
		if ($vhost->{$type.'_mem_free'}) {
			# Special case for Xen hosts where free memory may
			# not match the 'free' command
			$memmap{$vhost->{'id'}} = $vhost->{$type.'_mem_free'};
			}
		else {
			my $info = &get_server_collected($vhost);
			$memmap{$vhost->{'id'}} = $info->{'mem'}->[1];
			}
		}
	@vhosts = sort { $memmap{$b->{'id'}} <=> $memmap{$a->{'id'}} } @vhosts;
	return $vhosts[0];
	}
elsif ($hostmode eq 'disk') {
	# Sort by free disk
	my %diskmap;
	foreach my $vhost (@vhosts) {
		if ($vhost->{$type.'_vg_free'}) {
			# Special case for Xen or KVM on LVM
			$diskmap{$vhost->{'id'}} = $vhost->{$type.'_vg_free'};
			}
		else {
			my $info = &get_server_collected($vhost);
			$diskmap{$vhost->{'id'}} = $info->{'disk_free'};
			}
		}
	@vhosts = sort { $diskmap{$b->{'id'}} <=> $diskmap{$a->{'id'}}} @vhosts;
	return $vhosts[0];
	}
else {
	# Choose randomly
	my $r = int(rand()*scalar(@vhosts));
	return $vhosts[$r];
	}
}

# show_host_server_field(label, name, manager, [host-change-function])
# Returns HTML for selecting a host system, if the user is allowed to.
sub show_host_server_field
{
my ($label, $name, $type, $hostfunc) = @_;
my @vhosts = &list_available_host_servers($type);
my ($default) = grep { $_->{$type.'_default'} } @vhosts;
$default ||= $vhosts[0];
my @locs = &list_vhost_locations(\@vhosts);
my ($defloc) = grep { $_->{'default'} } @locs;
$defloc ||= $locs[0] if (@locs);
my $field;
my $hostfield = &ui_select($name."_on", $default->{'id'},
		[ map { [ $_->{'id'}, $_->{'host'}.
		      &host_free_desc($_, $type) ] } @vhosts ],
		1, 0, 0, 0,
		$hostfunc ? "onChange='${hostfunc}(value)'" : "");
my $locfield = &ui_select($name."_loc", $defloc->{'id'},
		[ map { [ $_->{'id'}, $_->{'desc'} ] } @locs ],
		1, 0, 0, 0,
		$locfunc ? "onChange='${hostfunc}(\"loc\")'" : "");
if (!@vhosts) {
	# None available
	$field = "<font color=red><b>$text{'create_novhost'}</b></font>";
	}
elsif (&can_select_host_server() && &can_select_host_location() && @locs) {
	# Can choose explicit host, or location
	$field = &ui_radio_table($name."_def", 1,
			[ [ 1, $text{'locations_sel'}, $locfield,
			    $hostfunc ? "onClick='${hostfunc}(\"loc\")'" : "" ],
			  [ 0, $text{'locations_host'}, $hostfield,
			    $hostfunc ? "onClick='${hostfunc}(form.${name}_on.value)'" : "" ],
			], 1);
	}
elsif (&can_select_host_location() && @locs) {
	# Can only choose location
	$field = &ui_hidden($name."_def", 1).
		 $text{'locations_sel'}.' '.$locfield;
	}
elsif (&can_select_host_server()) {
	# Can only choose host
	$field = &ui_hidden($name."_def", 0).
		 $hostfield;
	}
if ($field) {
	my $f = &ui_table_row($label, $field);
	my $js;
	if (&can_select_host_location() && @locs) {
		$js .= "${hostfunc}('loc')\n";
		}
	elsif (&can_select_host_server()) {
		$js .= "${hostfunc}($default->{'id'});\n";
		}
	return wantarray ? ( $f, $js) : $f;
	}
return wantarray ? ( ) : undef;
}

# parse_host_server_field(&server, name, manager, &in, extra-ram, extra-disk)
# Returns a host system object parsed from the form by show_host_server_field,
# or calls error
sub parse_host_server_field
{
my ($server, $name, $type, $in, $mem, $disk) = @_;
my @vhosts = &list_available_host_servers($type);
@vhosts || &error($text{'create_exenvhostnone'});
my @locs;
if (defined(&list_vhost_locations)) {
	@locs = &list_vhost_locations(\@vhosts);
	}
my ($vhost, $loc);
if (&can_select_host_server() && &can_select_host_location() && @locs) {
	# Either host or location
	if ($in->{$name."_def"} == 1) {
		($loc) = grep { $_->{'id'} eq $in{$name."_loc"} } @locs;
		$loc || &error($text{'create_exenvhostloc'});
		}
	else {
		($vhost) = grep { $_->{'id'} eq $in->{$name."_on"} } @vhosts;
		$vhost || &error($text{'create_exenvhostsel'});
		}
	}
elsif (&can_select_host_location() && @locs) {
	# Pick one from a location
	($loc) = grep { $_->{'id'} eq $in{$name."_loc"} } @locs;
	$loc || &error($text{'create_exenvhostloc'});
	}
elsif (&can_select_host_server()) {
	# Specific host chosen
	($vhost) = grep { $_->{'id'} eq $in->{$name."_on"} } @vhosts;
	$vhost || &error($text{'create_exenvhostsel'});
	}
else {
	# Cannot choose any host - let plan decide
	$vhost = &find_host_server($server, $type, $mem, $disk);
	$vhost || &error($text{'create_exenvhostalloc'});
	}
if ($loc) {
	# Have a location, need to pick host from it
	$vhost = &find_host_from_location($server, $loc, $type, $mem, $disk);
	$vhost || &error(&text('create_exenvhostalloc2', $loc->{'desc'}));
	}
my ($ok, $err) = &usable_host_system($vhost, $type, $mem, $disk);
$ok || &error(&text('create_ehostusable', $vhost->{'host'}, $err));
return $vhost;
}

# show_host_floor_table(&server)
# Show a section for minimum RAM and disk to keep free on a host system
sub show_host_floor_table
{
my ($server) = @_;
print &ui_hidden_table_start($text{'xen_header6'}, "width=100%", 4,
			     "floor", 0);

# Disk space to leave free
print &ui_table_row($text{'floor_disk'},
	&ui_bytesbox("floor_disk", int($server->{'floor_disk'})), 3);

# Memory to leave free
print &ui_table_row($text{'floor_mem'},
	&ui_bytesbox("floor_mem", int($server->{'floor_mem'})));

# Include down systems in memory use?
print &ui_table_row($text{'floor_mem_down'},
	&ui_yesno_radio("floor_mem_down", $server->{'floor_mem_down'}));

print &ui_hidden_table_end("floor");
}

# parse_host_floor_table(&server, &in)
# Parse inputs generated by show_host_floor_table
sub parse_host_floor_table
{
my ($server, $in) = @_;

# Parse disk space to free
$in->{'floor_disk'} =~ /^[0-9\.]+$/ || &error($text{'floor_edisk'});
$server->{'floor_disk'} = $in->{'floor_disk'} * $in->{'floor_disk_units'};

# Parse memory to leave free
$in->{'floor_mem'} =~ /^[0-9\.]+$/ || &error($text{'floor_emem'});
$server->{'floor_mem'} = $in->{'floor_mem'} * $in->{'floor_mem_units'};
$server->{'floor_mem_down'} = $in->{'floor_mem_down'};
}

# tempname_on_server(&server, [basename])
# Returns a temporary file name on a remote system
sub tempname_on_server
{
my ($server, $base) = @_;
if ($server->{'manager'} eq 'this') {
	# Use my function
	return &tempname($base);
	}
elsif ($server->{'status'} eq 'virt' || $server->{'status'} eq 'novirt') {
	# Ask the remote Webmin
	&remote_foreign_require($vhost, "webmin", "webmin-lib.pl");
	return &remote_foreign_call($vhost, "webmin", "tempname", $base);
	}
else {
	# Use the configured dir
	my $ostemp = $vhost->{'type'} eq 'solaris' ? '/var/tmp' : '/tmp';
	my $tempdir = $config{'img_temp'} || $ostemp;
	if ($base) {
		$base =~ s/^(.*)\///;
		return $tempdir.'/'.$base;
		}
	else {
		$main::tempfilecount++;
		&seed_random();
		return $tempdir.'/'.int(rand(1000000))."_".
		       $main::tempfilecount."_".$scriptname;
		}
	}
}

# plugin_call(module, function, [arg, ...])
# If some plugin function is defined, call it and return the result,
# otherwise return undef
sub plugin_call
{
my ($mod, $func, @args) = @_;
if (&plugin_defined($mod, $func)) {
	if ($main::module_name ne "server_manager") {
		# Set up server_manager package
		&foreign_require("server-manager", "server-manager-lib.pl");
		$server_manager::first_print = $first_print;
		$server_manager::second_print = $second_print;
		$server_manager::indent_print = $indent_print;
		$server_manager::outdent_print = $outdent_print;
		}
	return &foreign_call($mod, $func, @args);
	}
else {
	return wantarray ? ( ) : undef;
	}
}

# plugin_defined(module, function)
# Returns 1 if some function is defined in a plugin
sub plugin_defined
{
my $pkg = $_[0];
$pkg =~ s/[^A-Za-z0-9]/_/g;
my $func = "${pkg}::$_[1]";
return defined(&$func);
}

# strip_html_tags(html)
# Removes all HTML tags from a string, returning plain text
sub strip_html_tags
{
my ($html) = @_;
$html =~ s/<[^>]*>//g;
return $html;
}

# Print functions for HTML output
sub first_html_print { print @_,"<br>\n"; }
sub second_html_print { print @_,"<p>\n"; }
sub indent_html_print { print "<ul>\n"; }
sub outdent_html_print { print "</ul>\n"; }
sub block_html_print { print "<pre>".&html_escape(join("", @_))."</pre>"; }

# Print functions for text output
sub first_text_print
{
print $indent_text,
      (map { &html_tags_to_text(&entities_to_ascii($_)) } @_),"\n";
}
sub second_text_print
{
print $indent_text,
      (map { &html_tags_to_text(&entities_to_ascii($_)) } @_),"\n\n";
}
sub indent_text_print { $indent_text .= "    "; }
sub outdent_text_print { $indent_text = substr($indent_text, 4); }
sub block_text_print { print join("", @_); }

# Print functions to capture output as text
sub first_capture_text_print
{
$capture_print .= $indent_text.
      join("", map { &html_tags_to_text(&entities_to_ascii($_)) } @_)."\n";
}
sub second_capture_text_print
{
$capture_print .= $indent_text.
      join("", map { &html_tags_to_text(&entities_to_ascii($_)) } @_)."\n\n";
}
sub block_capture_text_print
{
$capture_print .= join("", @_);
}

sub html_tags_to_text
{
my ($rv) = @_;
$rv =~ s/<tt>|<\/tt>//g;
$rv =~ s/<font[^>]*>|<\/font>//g;
$rv =~ s/<b>|<\/b>//g;
$rv =~ s/<i>|<\/i>//g;
$rv =~ s/<u>|<\/u>//g;
$rv =~ s/<pre>|<\/pre>//g;
$rv =~ s/<br>/\n/g;
$rv =~ s/<p>/\n\n/g;
return $rv;
}

sub null_print { }

sub set_all_null_print
{
$first_print = $second_print = $indent_print = $outdent_print = $block_print =
	\&null_print;
}
sub set_all_text_print
{
$first_print = \&first_text_print;
$second_print = \&second_text_print;
$indent_print = \&indent_text_print;
$outdent_print = \&outdent_text_print;
$block_print = \&block_text_print;
}
sub set_all_html_print
{
$first_print = \&first_html_print;
$second_print = \&second_html_print;
$indent_print = \&indent_html_print;
$outdent_print = \&outdent_html_print;
$block_print = \&block_html_print;
}
sub set_all_capture_text_print
{
$first_print = \&first_capture_text_print;
$second_print = \&second_capture_text_print;
$indent_print = \&indent_text_print;
$outdent_print = \&outdent_text_print;
$block_print = \&block_capture_text_print;
}

# These functions store and retrieve the current print commands
sub push_all_print
{
push(@print_function_stack, [ $first_print, $second_print,
			      $indent_print, $outdent_print, $block_print ]);
&set_all_null_print();
}
sub pop_all_print
{
my $p = pop(@print_function_stack);
($first_print, $second_print, $indent_print, $outdent_print, $block_print) =@$p;
}

# nice_rate(bits-per-sec)
# Returns a number of bits per second, nicely formatted
sub nice_rate
{
my ($bps) = @_;
my $n = &nice_size($bps);
$n =~ s/B$/bits\/s/;
return $n;
}

# ui_ratebox(name, bits, size, [disabled])
# Returns a field for selecting a network rate in bps
sub ui_ratebox
{
my ($name, $bits, $size, $dis) = @_;
my $units = 1;
if (!defined($bits)) {
	$units = 1024*1024;
	}
elsif ($bits >= 10*1024*1024*1024*1024) {
	$units = 1024*1024*1024*1024;
	}
elsif ($bits >= 10*1024*1024*1024) {
	$units = 1024*1024*1024;
	}
elsif ($bits >= 10*1024*1024) {
	$units = 1024*1024;
	}
elsif ($bits >= 10*1024) {
	$units = 1024;
	}
else {
	$units = 1;
	}
if ($bits ne "") {
	$bits = sprintf("%.2f", ($bits*1.0)/$units);
	$bits =~ s/\.00$//;
	}
$size = &ui_max_text_width($size || 8);
return &ui_textbox($name, $bits, $size, $dis)." ".
       &ui_select($name."_units", $units,
		 [ [ 1, "bits/s" ],
		   [ 1024, "kb/sec" ],
		   [ 1024*1024, "Mb/sec" ],
		   [ 1024*1024*1024, "Gb/sec" ],
		   [ 1024*1024*1024*1024, "Tb/sec" ] ],
		 undef, undef, undef, $dis);
}

# parse_ifconfig_output(out)
# Parses the output of ifconfig -a into a list of interfaces
sub parse_ifconfig_output
{
my ($out) = @_;
my @ifaces;
my @lines;
foreach my $l (split(/\r?\n/, $out)) {
	if ($l =~ /^\S+/) { push(@lines, $l); }
	else { $lines[$#lines] .= $l; }
	}
foreach my $l (@lines) {
	my %ifc;
	$l =~ /^([^:\s]+)/; $ifc{'name'} = $1;
	$l =~ /^(\S+)/; $ifc{'fullname'} = $1;
	if ($l =~ /^(\S+):(\d+)/) { $ifc{'virtual'} = $2; }
	if ($l =~ /inet addr:(\S+)/) { $ifc{'address'} = $1; }
	if ($l =~ /Mask:(\S+)/) { $ifc{'netmask'} = $1; }
	if ($l =~ /Bcast:(\S+)/) { $ifc{'broadcast'} = $1; }
	if ($l =~ /HWaddr (\S+)/) { $ifc{'ether'} = $1; }
	if ($l =~ /MTU:(\d+)/) { $ifc{'mtu'} = $1; }
	if ($l =~ /P-t-P:(\S+)/) { $ifc{'ptp'} = $1; }
	$ifc{'up'}++ if ($l =~ /\sUP\s/);
	$ifc{'promisc'}++ if ($l =~ /\sPROMISC\s/);
	$ifc{'edit'} = ($ifc{'name'} !~ /^ppp/);
	$ifc{'index'} = scalar(@rv);
	push(@ifaces, \%ifc);
	}
return @ifaces;
}

# tar_supports_gzip(&server)
# Returns 1 if tar on some system supports the z option to do gzip compression.
# Assumed true for GNU tar.
sub tar_supports_gzip
{
my ($server) = @_;
my ($out, $ex, $err) = &execute_command_on_server($server,"tar --version 2>&1");
return !$err && !$ex && $out =~ /GNU\s+tar/i ? 1 : 0;
}

# list_active_server_interfaces(&server)
# Returns a list of all running network interfaces on a system, as an array ref
sub list_active_server_interfaces
{
my ($server) = @_;
if ($server->{'status'} eq 'virt' || $server->{'status'} eq 'novirt') {
	# Get from Webmin
	$last_remote_error = undef;
	&remote_foreign_require($server, "net", "net-lib.pl");
	return $last_remote_error if ($last_remote_error);
	my @active = &remote_foreign_call(
		$server, "net", "active_interfaces", 1);
	return $last_remote_error if ($last_remote_error);

	# Also add in gateways
	my @routes = &remote_foreign_call($server, "net", "list_routes");
	foreach my $r (@routes) {
		my ($iface) = grep { $_->{'fullname'} eq $r->{'iface'}} @active;
		if ($r->{'dest'} eq "0.0.0.0" && $iface) {
			$iface->{'gateway'} = $r->{'gateway'};
			}
		}
	return \@active;
	}
else {
	# Try parsing ifconfig output
	my ($out, $ex, $err) = &execute_command_on_server($server,
		"ifconfig -a");
	return $err if ($err);
	return $out if ($ex);
	my @active = &parse_ifconfig_output($out);

	# Also add in gateways
	my ($out, $ex, $err) = &execute_command_on_server($server,
		"netstat -rn");
	return $err if ($err);
	return $out if ($ex);
	foreach my $l (split(/\r?\n/, $out)) {
		my ($dest, $gw, undef, undef, undef, undef, undef, $i) =
			split(/\s+/, $l);
		my ($iface) = grep { $_->{'fullname'} eq $i } @active;
		if ($dest eq "0.0.0.0" && $iface) {
			$iface->{'gateway'} = $gw;
			}
		}
	return \@active;
	}
}

# create_active_server_interface(&server, &iface)
# Use the ifconfig command or Webmin to activate an interface
sub create_active_server_interface
{
my ($server, $iface) = @_;
if ($server->{'status'} eq 'virt' || $server->{'status'} eq 'novirt') {
	# Call remote Webmin to bring up interface
	$last_remote_error = undef;
	&remote_foreign_require($server, "net", "net-lib.pl");
	return $last_remote_error if ($last_remote_error);
	$iface->{'up'} = 1;
	&remote_foreign_call($server, "net", "activate_interface", $iface);
	return $last_remote_error if ($last_remote_error);
	}
else {
	# Activate with ifconfig command
	my $cmd = "ifconfig ".quotemeta($iface->{'fullname'})." ".
		     quotemeta($iface->{'address'})." up ".
		     "netmask ".quotemeta($iface->{'netmask'})." ".
		     "broadcast ".quotemeta($iface->{'broadcast'});
	my ($out, $ex, $err) = &execute_command_on_server($server, $cmd);
	return $err if ($err);
	return $out if ($ex);
	}
return undef;
}

# delete_active_server_interface(&server, &iface)
# De-activate an interface, either via Webmin or running ifconfig
sub delete_active_server_interface
{
my ($server, $iface) = @_;
if ($server->{'status'} eq 'virt' || $server->{'status'} eq 'novirt') {
	# De-activate it using Webmin
	$last_remote_error = undef;
	&remote_foreign_require($server, "net", "net-lib.pl");
	return $last_remote_error if ($last_remote_error);
	&remote_foreign_call($server, "net", "deactivate_interface", $iface);
	return $last_remote_error if ($last_remote_error);
	}
else {
	# Just remove with ifconfig
	my $cmd = "ifconfig ".quotemeta($iface->{'fullname'})." down";
	my ($out, $ex, $err) = &execute_command_on_server($server, $cmd);
	return $err if ($err);
	return $out if ($ex);
	}
return undef;
}

# modify_active_server_interface(&server, &iface, &oldiface)
# Update an active interface, either via Webmin or ifconfig command
sub modify_active_server_interface
{
my ($server, $iface, $oldiface) = @_;
my $oldip = &get_server_ip($server);
my $primary = $oldip eq $oldiface->{'address'} ? 1 : 0;
if (($server->{'status'} eq 'virt' || $server->{'status'} eq 'novirt') &&
    !$primary) {
	# Change it using Webmin
	$last_remote_error = undef;
	&remote_foreign_require($server, "net", "net-lib.pl");
	return $last_remote_error if ($last_remote_error);
	&remote_foreign_call($server, "net", "activate_interface", $iface);
	return $last_remote_error if ($last_remote_error);
	}
else {
	# Use the ifconfig command
	my $cmd = "ifconfig ".quotemeta($iface->{'fullname'})." ".
		     quotemeta($iface->{'address'})." ".
		     "netmask ".quotemeta($iface->{'netmask'})." ".
		     "broadcast ".quotemeta($iface->{'broadcast'});
	if ($primary) {
		# Will hang, so background it
		$cmd = "(sleep 2 ; $cmd >/dev/null 2>&1 </dev/null) &";
		}
	my ($out, $ex, $err) = &execute_command_on_server($server, $cmd);
	return $err if ($err);
	return $out if ($ex);
	}
return undef;
}

# list_boot_server_interfaces(&server)
# Returns a list of all bootup network interfaces on a system, as an array ref
sub list_boot_server_interfaces
{
my ($server) = @_;
if ($server->{'status'} eq 'virt' || $server->{'status'} eq 'novirt') {
	# Get from Webmin
	$last_remote_error = undef;
	&remote_foreign_require($server, "net", "net-lib.pl");
	return $last_remote_error if ($last_remote_error);
	my @boot = &remote_foreign_call(
		$server, "net", "boot_interfaces", 1);
	return $last_remote_error if ($last_remote_error);
	return \@boot;
	}
elsif (&redhat_server_type($server)) {
	# Read all ifcfg-* files
	my $idir = "/etc/sysconfig/network-scripts";
	my $files = &list_dir_on_server($server, $idir);
	return "Failed to list $idir : $files" if (!ref($files));
	my @boot;
	foreach my $f (grep { /^ifcfg-[a-z0-9:\.]+$/ && !/\.(bak|old)$/ }
			    @$files) {
		my $temp = &transname();
		my $err = &get_file_from_server($server, $idir."/".$f, $temp);
		next if ($err);
		my %conf;
		&read_env_file($temp, \%conf);
		my $b = { };
                $b->{'fullname'} = $conf{'DEVICE'};
                if ($b->{'fullname'} =~ /(\S+):(\d+)/) {
                        $b->{'name'} = $1;
                        $b->{'virtual'} = $2;
                        }
                else {
			$b->{'name'} = $b->{'fullname'};
			}
                $b->{'up'} = defined($conf{'ONPARENT'}) &&
			     $b->{'virtual'} ne '' ?
                                ($conf{'ONPARENT'} eq 'yes') :
                                ($conf{'ONBOOT'} eq 'yes');
                $b->{'address'} = $conf{'IPADDR'};
                $b->{'netmask'} = $conf{'NETMASK'};
                $b->{'broadcast'} = $conf{'BROADCAST'};
                $b->{'gateway'} = $conf{'GATEWAY'};
                $b->{'mtu'} = $conf{'MTU'};
                $b->{'dhcp'} = ($conf{'BOOTPROTO'} eq 'dhcp');
                $b->{'bootp'} = ($conf{'BOOTPROTO'} eq 'bootp');
                $b->{'edit'} = 1;
                $b->{'desc'} = $conf{'NAME'};
                $b->{'file'} = $idir."/".$f;
		&unlink_file($temp);
		push(@boot, $b);
		}
	return \@boot;
	}
elsif (&debian_server_type($server)) {
	# Read /etc/network/interfaces
	my $temp = &transname();
	my $ifile = "/etc/network/interfaces";
	my $err = &get_file_from_server($server, $ifile, $temp);
	return $err if ($err);
	my $lref = &read_file_lines($temp, 1);
	my @boot;
	my %auto;
	foreach my $l (@$lref) {
		if ($l =~ /^iface\s+(\S+)\s+inet\s+(static|loopback)/) {
			# Start of a new interface
			$b = { 'name' => $1,
			       'fullname' => $1 };
			$b->{'name'} =~ s/:\d+$//;
			push(@boot, $b);
			}
		elsif ($l =~ /^\s+(address|netmask|network|broadcast|gateway)\s+(\S+)/ && $b) {
			# Some parameter of an interface
			$b->{$1} = $2;
			}
		elsif ($l =~ /^auto\s+(.*)/) {
			# Auto line - save to apply later
			foreach my $a (split(/\s+/, $1)) {
				$auto{$a}++;
				}
			}
		}
	foreach my $b (@boot) {
		$b->{'up'} = $auto{$b->{'fullname'}};
		}
	&unlink_file($temp);
	return \@boot;
	}
else {
	# Out of luck ..
	return "Listing boot-time network interfaces on systems of type ".
	       $server->{'type'}." is not supported";
	}
}

# create_boot_server_interface(&server, &iface)
# Add an interface to be activated at boot, via Webmin or editing config files
sub create_boot_server_interface
{
my ($server, $iface) = @_;
if ($server->{'status'} eq 'virt' || $server->{'status'} eq 'novirt') {
	# Ask Webmin to add
	$last_remote_error = undef;
	&remote_foreign_require($server, "net", "net-lib.pl");
	return $last_remote_error if ($last_remote_error);
	&remote_foreign_call($server, "net", "save_interface", $iface);
	return $last_remote_error if ($last_remote_error);
	}
elsif (&redhat_server_type($server)) {
	# Create ifcfg- file
        &foreign_require("net", "net-lib.pl");
	my %conf;
	my $name = $iface->{'virtual'} ne "" ?
			$iface->{'name'}.":".$iface->{'virtual'} :
			$iface->{'name'};
	$conf{'DEVICE'} = $name;
	$conf{'IPADDR'} = $iface->{'address'};
	$conf{'NETMASK'} = $iface->{'netmask'};
	$conf{'NETWORK'} = &net::compute_network($iface->{'address'},
						 $iface->{'netmask'});
	$conf{'BROADCAST'} = $iface->{'broadcast'};
        if ($iface->{'gateway'}) {
                $conf{'GATEWAY'} = $iface->{'gateway'};
                }
	$conf{'ONBOOT'} = 'yes';
	$conf{'ONPARENT'} = 'yes' if ($iface->{'virtual'} ne '');
	$conf{'BOOTPROTO'} = 'none';
	$conf{'NAME'} = $iface->{'desc'};
	my $temp = &transname();
	&write_env_file($temp, \%conf);
	my $idir = "/etc/sysconfig/network-scripts";
	my $err = &put_file_to_server($server, $temp,
				      $idir."/ifcfg-".$iface->{'fullname'});
	&unlink_file($temp);
	return $err;
	}
elsif (&debian_server_type($server)) {
	# Add to /etc/network/interfaces
        &foreign_require("net", "net-lib.pl");
	my $ifile = "/etc/network/interfaces";
	my $temp = &transname();
	my $err = &get_file_from_server($server, $ifile, $temp);
	return $err if ($err);
	my $lref = &read_file_lines($temp);
	push(@$lref, "") if ($lref->[@$lref - 1]);
	push(@$lref, "auto ".$iface->{'fullname'});
	push(@$lref, "");
	push(@$lref, "iface ".$iface->{'fullname'}." inet static");
	push(@$lref, "\t"."address ".$iface->{'address'});
	push(@$lref, "\t"."netmask ".$iface->{'netmask'});
	$iface->{'network'} = &net::compute_network($iface->{'address'},
                                                    $iface->{'netmask'});
	push(@$lref, "\t"."network ".$iface->{'network'});
	if ($iface->{'broadcast'}) {
		push(@$lref, "\t"."broadcast ".$iface->{'broadcast'});
		}
	if ($iface->{'gateway'}) {
		push(@$lref, "\t"."gateway ".$iface->{'gateway'});
		}
	&flush_file_lines($temp);
	my $err = &put_file_to_server($server, $temp, $ifile);
	&unlink_file($temp);
        return $err;
	}
else {
	# Out of luck
	return "Creating boot-time network interfaces on systems of type ".
               $server->{'type'}." is not supported";
	}
}

# delete_boot_server_interface(&server, &iface)
# Delete a boot-time interface, either via Webmin or direct file manipulation
sub delete_boot_server_interface
{
my ($server, $iface) = @_;
if ($server->{'status'} eq 'virt' || $server->{'status'} eq 'novirt') {
	# Get from Webmin and delete it
	$last_remote_error = undef;
	&remote_foreign_require($server, "net", "net-lib.pl");
	return $last_remote_error if ($last_remote_error);
	my @boot = &remote_foreign_call($server, "net", "boot_interfaces");
	my ($boot) = grep { $_->{'fullname'} eq $iface->{'fullname'} } @boot;
	if ($boot) {
		&remote_foreign_call($server, "net", "delete_interface", $boot);
		}
	}
elsif (&redhat_server_type($server)) {
	# Delete ifcfg- file
        &foreign_require("net", "net-lib.pl");
	my $idir = "/etc/sysconfig/network-scripts";
	my $ifile = $idir."/ifcfg-".$iface->{'fullname'};
	if (&stat_file_on_server($server, $ifile)) {
		my $err = &delete_file_on_server($server, $ifile);
		return $err if ($err);
		}
	return undef;
	}
elsif (&debian_server_type($server)) {
	# Delete from /etc/network/interfaces
        &foreign_require("net", "net-lib.pl");
	my $ifile = "/etc/network/interfaces";
	my $temp = &transname();
	my $err = &get_file_from_server($server, $ifile, $temp);
	return $err if ($err);
	my $lref = &read_file_lines($temp);
	my $lnum = 0;
	my ($startline, $endline);
	foreach my $l (@$lref) {
		if ($l =~ /^iface\s+(\S+)/ && $1 eq $iface->{'fullname'}) {
			# Start of interface to remove
			$startline = $endline = $lnum;
			}
		elsif ($l =~ /\S/ && defined($startline)) {
			# Still in interface to remove
			$endline = $lnum;
			}
		$lnum++;
		}
	if (defined($startline)) {
		# Remove interface definition
		if ($startline && $lref->[$startline-1] !~ /\S/) {
			# Take out blank line before too
			$startline--;
			}
		splice(@$lref, $startline, $endline-$startline+1);
		}
	$lnum = 0;
	foreach my $l (@$lref) {
		if ($l =~ /^auto\s+(.*)/) {
			my @autos = split(/\s+/, $1);
			@autos = grep { $_ ne $iface->{'fullname'} } @autos;
			if (@autos) {
				$lref->[$lnum] = "auto ".join(" ", @autos);
				}
			else {
				splice(@$lref, $lnum, 1);
				}
			}
		$lnum++;
		}
	&flush_file_lines($temp);
	my $err = &put_file_to_server($server, $temp, $ifile);
	&unlink_file($temp);
        return $err;
	}
else {
	# Out of luck
	return "Deleting boot-time network interfaces on systems of type ".
               $server->{'type'}." is not supported";
	}
}

# modify_boot_server_interface(&server, &iface, &oldiface)
# Update a boot-time interface, either via Webmin or modifying config files
sub modify_boot_server_interface
{
my ($server, $iface, $oldiface) = @_;
if ($server->{'status'} eq 'virt' || $server->{'status'} eq 'novirt') {
	# Use Webmin
	$last_remote_error = undef;
	&remote_foreign_require($server, "net", "net-lib.pl");
	my @boot = &remote_foreign_call($server, "net", "boot_interfaces");
	my ($boot) = grep { $_->{'fullname'} eq $oldiface->{'fullname'} } @boot;
	if ($boot) {
		$boot->{'address'} = $iface->{'address'};
		$boot->{'netmask'} = $iface->{'netmask'};
		$boot->{'broadcast'} = $iface->{'broadcast'};
		$boot->{'network'} = $iface->{'network'};
		$boot->{'gateway'} = $iface->{'gateway'};
		&remote_foreign_call($server, "net", "save_interface", $boot);
		return $last_remote_error if ($last_remote_error);
		}
	return undef;
	}
elsif (&redhat_server_type($server)) {
	# Update ifcfg- file
	my %conf;
	my $idir = "/etc/sysconfig/network-scripts";
	my $ifile = $idir."/ifcfg-".$iface->{'fullname'};
	if (!&stat_file_on_server($server, $ifile)) {
		# If missing, do nothing
		return undef;
		}
	my $temp = &transname();
	my $err = &get_file_from_server($server, $ifile, $temp);
	return $err if ($err);
	&read_env_file($temp, \%conf);
	$conf{'IPADDR'} = $iface->{'address'};
	$conf{'NETMASK'} = $iface->{'netmask'};
	$conf{'NETWORK'} = &net::compute_network($iface->{'address'},
						 $iface->{'netmask'});
	$conf{'BROADCAST'} = $iface->{'broadcast'};
        if ($iface->{'gateway'}) {
                $conf{'GATEWAY'} = $iface->{'gateway'};
                }
        else {
                delete($conf{'GATEWAY'});
                }
	&write_env_file($temp, \%conf);
	my $err = &put_file_to_server($server, $temp, $ifile);
	&unlink_file($temp);
	return $err;
	}
elsif (&debian_server_type($server)) {
	# Update in from /etc/network/interfaces
	my $ifile = "/etc/network/interfaces";
	my $temp = &transname();
	my $err = &get_file_from_server($server, $ifile, $temp);
	return $err if ($err);
	my $lref = &read_file_lines($temp);
	my $iniface = 0;
	$iface->{'network'} = &net::compute_network($iface->{'address'},
                                                    $iface->{'netmask'});
	foreach my $l (@$lref) {
		if ($l =~ /^iface\s+(\S+)/) {
			# Start of interface, may be the one to edit
			$iniface = $1 eq $iface->{'fullname'} ? 1 : 0;
			}
		elsif ($l =~ /^\s+(address|netmask|network|broadcast|gateway)\s+/ && $iniface && $iface->{$1}) {
			# Some interface parameter to edit
			$l = "\t".$1." ".$iface->{$1};
			}
		}
	&flush_file_lines($temp);
	my $err = &put_file_to_server($server, $temp, $ifile);
	&unlink_file($temp);
        return $err;
	}
else {
	# Out of luck
	return "Modifying boot-time network interfaces on systems of type ".
               $server->{'type'}." is not supported";
	}
}

# list_host_bridges(&vhost)
# Returns the list of names of bridges on some system. Tries brctl show first,
# then ifconfig
sub list_host_bridges
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
			  grep { $_->{'fullname'} =~ /^(xenbr|br)/ &&
				 $_->{'virtual'} eq '' } @$ifaces;
		}
	}
return @rv;
}

# redhat_server_type(&server)
# Returns 1 if a system is some Redhat variant
sub redhat_server_type
{
my ($server) = @_;
return $server->{'type'} eq 'centos' ||
       $server->{'type'} eq 'redhat' ||
       $server->{'type'} eq 'fedora';
}

# debian_server_type(&server)
# Returns 1 if a system is some Debian variant
sub debian_server_type
{
my ($server) = @_;
return $server->{'type'} eq 'debian' ||
       $server->{'type'} eq 'ubuntu';
}

# cloudmin_api_log(&argv, [&server])
# Log an action taken by a Virtualmin command-line API call
sub cloudmin_api_log
{
local ($argv, $server) = @_;

# Parse into flags hash
local (%flags, $lastflag);
local @argv = @$argv;
while(@argv) {
	local $a = shift(@argv);
	if ($a =~ /^\-+(\S+)$/) {
		# A new flag
		$lastflag = $1;
		$flags{$lastflag} = "";
		}
	elsif ($lastflag) {
		# A flag value
		if ($flags{$lastflag} ne "") {
			$flags{$lastflag} .= " ";
			}
		$flags{$lastflag} .= $a;
		}
	if ($a =~ /^[^"' ]+$/) {
		push(@qargv, $a);
		}
	elsif ($a !~ /"/) {
		push(@qargv, "\"$a\"");
		}
	elsif ($a !~ /'/) {
		push(@qargv, "'$a'");
		}
	else {
		push(@qargv, quotameta($a));
		}
	}
$flags{'argv'} = &urlize(join(" ", @qargv));

# Log it
local $script = $0;
$script =~ s/^.*\///;
local $remote_user = "root";
local $WebminCore::remote_user = "root";
local $ENV{'REMOTE_HOST'} ||= "127.0.0.1";
&webmin_log($main::virtualmin_remote_api ||
	    $ENV{'VIRTUALMIN_REMOTE_API'} ? "remote" : "cmd",
	    $script, $server ? $server->{'host'} : undef, \%flags);
}

# list_ports_in_use(&server, [protocol])
# Returns an array ref of TCP ports in use on some system, using lsof, or an
# error message.
sub list_ports_in_use
{
my ($server, $proto) = @_;
$proto ||= "tcp";
if (&has_command_on_server($server, "lsof")) {
	# Parse lsof for LISTEN lines
	my ($out, $ex, $err) = &execute_command_on_server(
				$server, "lsof -i $proto -n -l -P");
	return $err if ($err);
	return $out if ($ex);
	my @rv;
	foreach my $l (split(/\r?\n/, $out)) {
		if ($l =~ /\s+([^:]+):(\d+)\s+\(LISTEN\)/) {
			push(@rv, $2);
			}
		}
	@rv = &unique(@rv);
	return \@rv;
	}
return "Missing lsof command";
}

# copy_cron_sched_keys(&src, &dest)
# Copy keys defining a cron schedule from one hash ref to another
sub copy_cron_sched_keys
{
my ($src, $dst) = @_;
foreach my $k ('mins', 'hours', 'days', 'months', 'weekdays', 'special') {
	$dst->{$k} = $src->{$k};
	}
}

# distance_from_server(&server1, &server2)
# Returns the distance between two systems, defined at :
# 0=Same machine
# 1=Same host system
# 2=Same class C subnet
# 3=Same location group
# 4=Same class B
# 5=Anything else
sub distance_from_server
{
my ($a, $b) = @_;
if ($a->{'id'} eq $b->{'id'}) {
	return 0;
	}
my $vhosta = &get_parent_server($a);
my $vhostb = &get_parent_server($b);
if ($vhosta && $vhostb && $vhosta->{'id'} eq $vhostb->{'id'}) {
	return 1;
	}
my @ipa = split(/\./, &get_server_ip($a));
my @ipb = split(/\./, &get_server_ip($b));
if ($ipa[0] == $ipb[0] && $ipa[1] == $ipb[1] && $ipa[2] == $ipb[2]) {
	return 2;
	}
my $loca = $a->{'location'} || $vhosta->{'location'};
my $locb = $b->{'location'} || $vhostb->{'location'};
if ($loca eq $locb) {
	return 3;
	}
if ($ipa[0] == $ipb[0] && $ipa[1] == $ipb[1]) {
	return 4;
	}
return 5;
}

# get_server_manager_url()
# Returns the base URL for links to Cloudmin, like https://yourserver:10000
sub get_server_manager_url
{
if ($config{'cloudmin_url'}) {
	return $config{'cloudmin_url'};
	}
else {
	my %miniserv;
        &get_miniserv_config(\%miniserv);
        my $proto = $miniserv{'ssl'} ? 'https' : 'http';
	my $host = &get_system_hostname();
        my $port = $miniserv{'port'};
        return $proto."://$host:$port";
	}
}

# list_ip_pools()
# Returns a list of IP allocation ranges, each of which is a hash ref with keys:
#   id - A unique ID for this pool
#   start - Starting IPs, comma-separated
#   end - Ending IPs, comma-separated
#   cidr - Network CIDR
#   desc - Human-readable description
sub list_ip_pools
{
my @rv;
open(POOLS, $pools_file);
while(<POOLS>) {
	s/\r|\n//g;
	my %l = map { my ($k, $v) = split(/=/, $_); ($k, &un_urlize($v)) }
		    split(/\s+/, $_);
	push(@rv, \%l);
	}
close(POOLS);
return @rv;
}

# save_ip_pools(&pools)
# Updates the file of IP pools
sub save_ip_pools
{
my ($rv) = @_;
&open_lock_tempfile(POOLS, ">$pools_file");
foreach my $l (@$rv) {
	&print_tempfile(POOLS,
		join(" ", map { $_."=".&urlize($l->{$_}) }
			      (sort { $a cmp $b } keys %$l)),"\n");
	}
&close_tempfile(POOLS);
}

# hash_ref_differences(&h1, &h2)
# Returns the list of keys that differ between two hash refs
sub hash_ref_differences
{
my ($h1, $h2) = @_;
my @k1 = keys %$h1;
my @k2 = keys %$h2;
my @rv;
foreach my $k (@k1) {
	if (!exists($h2->{$k})) {
		push(@rv, $k);
		}
	else {
		my $v1 = $h1->{$k};
		my $v2 = $h2->{$k};
		if (ref($v1) ne ref($v2)) {
			push(@rv, $k);
			}
		elsif (ref($v1) eq 'ARRAY') {
			my $a1 = join("\0", @$v1);
			my $a2 = join("\0", @$v2);
			push(@rv, $k) if ($a1 ne $a2);
			}
		elsif (ref($v1) eq 'HASH') {
			push(@rv, map { $k.".".$_ }
				&hash_ref_differences($v1, $v2));
			}
		else {
			push(@rv, $k) if ($v1 ne $v2);
			}
		}
	}
foreach my $k (@k2) {
	if (!exists($h1->{$k})) {
		push(@rv, $k);
		}
	}
return @rv;
}

# obtain_lock_server(&server|&servers, [readonly])
# Lock a server for some update. May re-read it from disk if changed.
sub obtain_lock_server
{
my ($server, $ro) = @_;
if (ref($server) eq 'ARRAY') {
	# Do a list
	foreach my $s (@$server) {
		&obtain_lock_server($s);
		}
	}
else {
	# Do one
	if (!$ro) {
		&obtain_lock_anything();
		}
	if ($main::got_lock_server{$server->{'id'}} == 0) {
		my $sfile = $servers::module_config_directory."/".
			    $server->{'id'}.".serv";
		my @stbefore = stat($sfile);
		&lock_file($sfile, $ro);
		my @stafter = stat($sfile);
		if (@stbefore && !@stafter) {
			# No longer exists .. must have been deleted during
			# lock. Give up!
			&error("System $server->{'host'} ID $server->{'id'} ".
			       "deleted while waiting for lock!");
			}
		if (@stbefore && $stbefore[9] != $stafter[9]) {
			# Changed since it was locked .. re-read it
			my $reserver = &get_managed_server($server->{'id'});
			if ($reserver) {
				%$server = %$reserver;
				}
			}
		}
	$main::got_lock_server{$server->{'id'}}++;
	}
}

# release_lock_server(&server)
# Un-lock a server after some update
sub release_lock_server
{
my ($server) = @_;
if (ref($server) eq 'ARRAY') {
	# Do a list
	foreach my $s (@$server) {
		&release_lock_server($s);
		}
	}
else {
	# Un-lock one
	if ($main::got_lock_server{$server->{'id'}} == 1) {
		&unlock_file("$servers::module_config_directory/".
			     "$server->{'id'}.serv");
		}
	$main::got_lock_server{$server->{'id'}}--
		if ($main::got_lock_server{$server->{'id'}});
	}
}

# obtain_lock_anything()
# Should be called before any state-changing action
sub obtain_lock_anything
{
$SIG{'PIPE'} = 'IGNORE';
}

sub test_lock_server
{
my ($server) = @_;
if ($main::got_lock_server{$server->{'id'}}) {
	# Locked already in this process
	return 0;
	}
return &test_lock("$servers::module_config_directory/$server->{'id'}.serv");
}

$done_server_manager_lib_funcs = 1;


1;

