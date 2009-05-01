# Functions for general setup and management of multiple Virtualmin servers
# XXX allow changing of main IP
#	XXX do virtualmin too
#	XXX support when moving systems
# XXX HVM Xen instances
# XXX ajaxterm instead of java
#	XXX http://antony.lesuisse.org/qweb/trac/wiki/AjaxTerm
# XXX LVM disk support
#	XXX need another disk in sentosa

BEGIN { push(@INC, ".."); };
eval "use WebminCore;";
if ($@) {
	# Old Webmin version
	do '../web-lib.pl';
	do '../ui-lib.pl';
	}

&init_config();
do 'images-lib.pl';
do 'newfeatures-lib.pl';
do 'owners-lib.pl';
do 'login-lib.pl';
do 'domainname-lib.pl';
do 'commands-lib.pl';
do 'filesystem-lib.pl';
do 'history-lib.pl';
if (-r "$module_root_directory/bw-lib.pl") {
	do 'bw-lib.pl';
	}
&foreign_require("servers", "servers-lib.pl");
&foreign_require("proc", "proc-lib.pl");
&foreign_require("net", "net-lib.pl");
&remote_error_setup(\&remote_error_handler);
eval "use Net::Amazon::EC2;";		# Fails if no S3 type
use Time::Local;
%access = &get_module_acl();

@possible_server_management_types = ( "real",
				      "xen",
				      "vserver",
				      "zones",
				      "ec2",
				      "this",
				    );
@server_management_types = ( );
%server_management_types = ( );
foreach my $smt (@possible_server_management_types) {
	if ($config{'show_'.$smt} &&
	    -r $module_root_directory."/".$smt."-type-lib.pl") {
		push(@server_management_types, $smt);
		$server_management_types{$smt} = 1;
		do $smt."-type-lib.pl";
		}
	}

$ssh_keys_dir = "$module_config_directory/keys";
$server_domains_dir = "$module_config_directory/domains";
$server_collected_dir = "$module_config_directory/coll";
$this_server_status = "$module_config_directory/this";

$check_status_cmd = "$module_config_directory/status.pl";
$check_licence_cmd = "$module_config_directory/licence.pl";
$bandwidth_cron_cmd = "$module_config_directory/bandwidth.pl";
@cron_cmds = ( $check_status_cmd, $check_licence_cmd,
	       $bandwidth_cron_cmd );

@standard_virtualmin_features = (
	{ 'feature' => 'dir', 'desc' => 'Home directory',
	  'enabled' => 1, 'default' => 1, 'auto' => 1 },
	{ 'feature' => 'unix', 'desc' => 'Administration user',
	  'enabled' => 1, 'default' => 1, 'auto' => 1 },
	{ 'feature' => 'mail', 'desc' => 'Mail for domain',
	  'enabled' => 1, 'default' => 1 },
	{ 'feature' => 'dns', 'desc' => 'BIND DNS domain',
	  'enabled' => 1, 'default' => 1 },
	{ 'feature' => 'web', 'desc' => 'Apache website',
	  'enabled' => 1, 'default' => 1 },
	{ 'feature' => 'webalizer', 'desc' => 'Webalizer reporting',
	  'enabled' => 1, 'default' => 1 },
	{ 'feature' => 'ssl', 'desc' => 'SSL website',
	  'enabled' => 1, 'default' => 0 },
	{ 'feature' => 'logrotate', 'desc' => 'Log file rotation',
	  'enabled' => 1, 'default' => 1, 'auto' => 1 },
	{ 'feature' => 'mysql', 'desc' => 'MySQL database',
	  'enabled' => 1, 'default' => 1 },
	{ 'feature' => 'postgres', 'desc' => 'PostgreSQL database',
	  'enabled' => 1, 'default' => 1 },
	{ 'feature' => 'ftp', 'desc' => 'ProFTPd server',
	  'enabled' => 1, 'default' => 0 },
	{ 'feature' => 'webmin', 'desc' => 'Webmin login',
	  'enabled' => 1, 'default' => 1 },
	);

%webmin_download_source = (
	'rpm' => 'http://www.webmin.com/download/rpm/webmin-current.rpm',
	'dpkg' => 'http://www.webmin.com/download/deb/webmin-current.deb',
	'pkgadd' => 'http://www.webmin.com/download/webmin-current.pkg.gz',
	'tgz' => 'http://www.webmin.com/download/webmin-current.tar.gz',
	);

@server_statuses = (
	[ 'down' => 'ff0000' ],
	[ 'noping' => 'ff1100' ],
	[ 'alive' => '00ff00' ],
	[ 'paused' => 'aa0000' ],
	[ 'nossh' => 'ff220000' ],
	[ 'nohost' => 'ff440000' ],
	[ 'nosshlogin' => 'ff6600' ],
	[ 'nowebmin' => 'ff00ff' ],
	[ 'downwebmin' => 'ff22ff' ],
	[ 'nowebminlogin' => 'ff44ff' ],
	[ 'novirt' => '008800' ],
	[ 'virt' => '00aa00' ]
	);

$licence_status = "$module_config_directory/licence-status";
$licence_file = "/etc/server-manager-license";
$licence_cache_file = "$module_config_directory/licence-cache";
$vm2_yum_repo = "/etc/yum.repos.d/vm2.repo";
$upgrade_vm2_host = "vm2.virtualmin.com";

$virtualmin_licence_host = "software.virtualmin.com";
$virtualmin_licence_port = 80;
$vm2_licence_prog = "/cgi-bin/slicence.cgi";
$virtualmin_licence_prog = "/cgi-bin/vlicence.cgi";
$virtualmin_licence_ssl = 0;
$virtualmin_installer_prog = "/cgi-bin/install.cgi";
$virtualmin_solaris_installer_prog = "/cgi-bin/install.cgi";
$virtualmin_alllicences_prog = "/cgi-bin/alllicences.cgi";
$virtualmin_gpl_installer_path = "/gpl/scripts/install.sh";

$virtualmin_licences_file = "$module_config_directory/virtualmin-licences";
$serial_cache_file = "$module_config_directory/serial-cache";
$virtualmin_progress_file = "$module_config_directory/progress-licences";

@virtualmin_operating_systems = ( "debian", "ubuntu", "redhat", "fedora",
				  "centos", "solaris" );

$virtualmin_apt_package_key = "http://software.virtualmin.com/lib/RPM-GPG-KEY-virtualmin";
$virtualmin_webmin_apt_package_key = "http://software.virtualmin.com/lib/RPM-GPG-KEY-webmin";

$default_search_file = "$module_config_directory/defaultsearch.$remote_user";

@newfeatures_dirs = ( "$module_root_directory/newfeatures-all" );
$newfeatures_seen_dir = "$module_config_directory/seenfeatures";
$install_times_file = "$module_config_directory/installtimes";

$bandwidth_dir = "$module_config_directory/bandwidth";

$shell_previous_dir = "$module_config_directory/previous";

$login_shell_cmd = "$module_config_directory/login.pl";
$login_home_base = $ENV{'WEBMIN_VAR'}."/login";

$api_helper_command = "/usr/sbin/vm2";

$ping_host_timeout = 2;

# Init all plugins
@confplugins = split(/\s+/, $config{'plugins'});
if ($no_vm2_plugins) {
	@confplugins = ( );
	}
@plugins = ( );
foreach my $pname (@confplugins) {
	if (&foreign_check($pname)) {
		&foreign_require($pname, "vm2_feature.pl");
		push(@plugins, $pname);
		}
	}

&set_all_html_print();

# list_managed_servers()
# Returns a list of all servers managed by this module. These are actually
# just a subset of those from the Webmin Servers Index module
sub list_managed_servers
{
local @rv = grep { $_->{'module'} eq $module_name } &servers::list_servers();
@rv = grep { $server_management_types{$_->{'manager'}} } @rv;
@rv = sort { $a->{'host'} cmp $b->{'host'} } @rv;

foreach my $s (@rv) {
	if ($s->{'manager'} eq 'ec2' && !$s->{'ec2_sgroup'}) {
		# Assume security group is Virtualmin default
		$s->{'ec2_sgroup'} = $ec2_security_group;
		}
	}

if ($config{'show_this'}) {
	# Magically add this system to the list
	local $this = &servers::this_server();
	$this->{'manager'} = 'this';
	$this->{'host'} = &get_system_hostname();
	$this->{'desc'} = $text{'this_this'};
	&read_file($this_server_status, $this);
	splice(@rv, 0, 0, $this);

	# If this system can host Xen and we are in Xen-only mode, allow it to
	# be a host
	if ($module_info{'onehost'} eq 'xen' &&
	    $server_management_types{'xen'} &&
	    ($config{'xen_checked'} || !&check_xen_host_software($this))) {
		$this->{'xen_host'} = 1;
		local $eth0 = &first_ethernet_iface();
		if ($config{'xen_start'}) {
			# Allocation range is set from module config
			$this->{'xen_start'} = $config{'xen_start'};
			$this->{'xen_end'} = $config{'xen_end'};
			}
		else {
			# Range comes from primary interface.
			($this->{'xen_start'}, $this->{'xen_end'}) =
				&first_ethernet_range();
			}
		if ($config{'xen_cidr'}) {
			# Set on Module Config page
			$this->{'xen_cidr'} = $config{'xen_cidr'};
			}
		else {
			# CIDR is same as primary interface
			$this->{'xen_cidr'} = &net::mask_to_prefix(
						$eth0->{'netmask'});
			}
		$this->{'xen_dir'} = $config{'xen_dir'};
		$this->{'xen_zone'} = $config{'xen_zone'};

		# Save flag indicating that we have already checked out Xen
		# on this machine, as doing so can be slow
		$config{'xen_checked'} = 1;
		&save_module_config();
		}
	}

# Compute short hostnames
foreach my $s (@rv) {
	local $shost = $s->{'host'};
	if ($config{'name_max'} && length($shost) > $config{'name_max'}) {
		# Show first and last max/2 chars, with ... between
		local $h = int($config{'name_max'} / 2);
		$shost = substr($shost, 0, $h)."...".substr($shost, -$h);
		}
	$s->{'short_host'} = $shost;
	}

# Fill in creation times
foreach my $s (@rv) {
	if (!$s->{'created'}) {
		if ($s->{'id'} =~ /^(\d{10})/) {
			$s->{'created'} = $1;
			}
		else {
			# Assume created at module install time
			local %itimes;
			&read_file($install_times_file, \%itimes);
			local @vers = sort { $a <=> $b } (keys %itimes);
			if (@vers) {
				$s->{'created'} = $itimes{$vers[0]};
				}
			}
		}
	}

return @rv;
}

# list_managed_servers_sorted()
# Returns servers list, with sorting and possibly 'indent' fields
sub list_managed_servers_sorted
{
local @rv = &list_managed_servers();
foreach my $s (@rv) {
	$s->{'indent'} = 0;
	}
if ($config{'sort_mode'} == 0) {
	# By hostname
	@rv = sort { $a->{'host'} cmp $b->{'host'} } @rv;
	}
elsif ($config{'sort_mode'} == 1) {
	# Under host systems
	local @newrv;
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
elsif ($config{'sort_mode'} == 2) {
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
local @rv = grep { &can_action($_) } &list_managed_servers_sorted();
local %got = map { $_->{'id'}, $_ } @rv;
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

# Returns a unique ID for a new VM2 server
sub server_id
{
return time().$$.($main::server_id_count++);
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
local $eth0 = &first_ethernet_iface();
if (!$eth0) {
	# Fake it
	$eth0 = { 'address' => &to_ipaddress(&get_system_hostname()) ||
			       '127.0.0.1',
		  'netmask' => '255.255.255.0' };
	}
local $ipnum = &net::ip_to_integer($eth0->{'address'});
local $netnum = &net::ip_to_integer($eth0->{'netmask'});
local $netstart = ($ipnum & $netnum) + 1;
local $netsize = ~$netnum;
local $netend = ($ipnum & $netnum) + $netsize - 1;
return ( &net::integer_to_ip($netstart),
	 &net::integer_to_ip($netend) );
}

# get_managed_server_by(key, value)
# Returns a list of servers which have a field matching some search key
sub get_managed_server_by
{
local ($key, $value) = @_;
local @rv = grep { $_->{$key} eq $value } &list_managed_servers();
return wantarray ? @rv : $rv[0];
}

# save_managed_server(&server)
# Create or update a managed server object. It will be added to both this
# module and Webmin Servers Index
sub save_managed_server
{
local ($server) = @_;
if ($server->{'id'} eq '0') {
	# Special case - saving info about this system
	local %this = ( 'status' => $server->{'status'},
			'statustime' => $server->{'statustime'},
			'status_msg' => $server->{'status_msg'},
			'group' => $server->{'group'},
			'virtualmin_checked' => $server->{'virtualmin_checked'},
			'virtualmin_err' => $server->{'virtualmin_err'},
			'virtualmin_poss' => $server->{'virtualmin_poss'},
			'virtualmin_domains' => $server->{'virtualmin_domains'},
			'virtualmin_serial' => $server->{'virtualmin_serial'},
			'virtualmin_key' => $server->{'virtualmin_key'},
		      );
	# Save all VM2 type-specific details
	foreach my $t (@server_management_types) {
		foreach my $k (keys %$server) {
			if ($k =~ /^\Q$t\E_/) {
				$this{$k} = $server->{$k};
				}
			}
		}
	&write_file($this_server_status, \%this);
	}
else {
	if (!$server->{'id'}) {
		local ($same) = grep { $_->{'host'} eq $server->{'host'} }
				     &servers::list_servers();
		$server->{'id'} = $same ? $same->{'id'} : time();
		}
	$server->{'module'} = $module_name;
	&servers::save_server($server);
	}
}

# delete_managed_server(&server, [keep-info])
# Remove a managed server object
sub delete_managed_server
{
local ($server, $keep) = @_;
&delete_login_user($server);
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
	}
}

# find_managed_servers(all, &hostnames, &groupnames, &managers, &types)
# Finds all servers matching some selection criteria
sub find_managed_servers
{
local ($all, $hosts, $groups, $managers, $types) = @_;
local @rv;
local %wantgroups = map { lc($_), 1 } @$groups;
foreach my $s (&list_managed_servers()) {
	local ($ingroup) = grep { $wantgroup{lc($_)} }
				split(/\t/, $s->{'group'});
	if ($all ||
	    $ingroup ||
	    &indexoflc($s->{'host'}, @$hosts) >= 0 ||
	    &indexoflc($s->{'manager'}, @$managers) >= 0 ||
	    &indexoflc($s->{'type'}, @$types) >= 0) {
		push(@rv, $s);
		}
	}
return @rv;
}

# describe_os(os)
# Converts an OS code as used by the 'servers' module into a name
sub describe_os
{
local ($t) = @_;
local ($type) = grep { $_->[0] eq $t } @servers::server_types;
return $type->[1];
}

# describe_status(&server, [withcolor], [withdomains])
# Returns a string describing the status of some server (down, nossh,
# nologin, nowebmin, nowebminlogin, novirt, virt)
sub describe_status
{
local ($s, $withcol, $withdoms) = @_;
local %cmap = map { $_->[0], $_->[1] } @server_statuses;
local $msg = $text{'status_'.$s->{'status'}} || $text{'status_unknown'};
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
	local $col = $cmap{$s->{'status'}};
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

# list_ssh_keys()
# Returns a list of SSH keys used to login to servers
sub list_ssh_keys
{
local @rv;
opendir(DIR, $ssh_keys_dir);
foreach my $f (readdir(DIR)) {
	next if ($f !~ /^(\S+)\.info$/i);
	local %key;
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
local ($key) = @_;
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
local %nodata = %$key;
delete($nodata{'keydata'});
&write_file("$ssh_keys_dir/$key->{'id'}.info", \%nodata);
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
local ($key) = @_;
&unlink_logged("$ssh_keys_dir/$key->{'id'}.info");
if (!$key->{'external'}) {
	&unlink_logged($key->{'file'});
	}
}

# generate_public_key(&key)
# Returns the public key string for some key
sub generate_public_key
{
local ($key) = @_;
local $qp = quotemeta($key->{'file'});
local $out = &backquote_command("ssh-keygen -y -f $qp 2>/dev/null");
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
local ($text) = @_;
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

# generate_ssh_key()
# Create a new SSH private key, in the default format
sub generate_ssh_key
{
local $temp = &transname();
local $out = &backquote_command("ssh-keygen -f $temp -N '' 2>&1");
if ($? || !-r $temp) {
	&error("<tt>$out</tt>");
	}
local $data = &read_file_contents($temp);
unlink($temp, $temp.".pub");
return $data;
}

# wrap_long_line(text, cols)
# If any lines in text are longer than cols, wrap them onto the next line.
# Returns the resulting wrapped text as a single string.
sub wrap_long_line
{
local ($text, $cols) = @_;
local @lines = split(/\r?\n/, $text);
local @rv;
foreach my $text (@lines) {
	while($text) {
		local $l = substr($text, 0, $cols);
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
local ($name, $type, $value) = @_;
local @keys = sort { $a->{'desc'} cmp $b->{'desc'} } &list_ssh_keys();
local @allkeys = @keys;
if ($type) {
	# Limit to keys suitable for this server type
	local $kfunc = "type_${type}_ssh_key_grep";
	if (defined(&$kfunc)) {
		@keys = grep { &$kfunc($_) } @keys;
		}
	}
if (@keys) {
	return &ui_select($name, $value,
		[ map { [ $_->{'id'}, $_->{'desc'} ] } @keys ]);
	}
else {
	local $msg = @keys == @allkeys ? $text{'add_nokeys'}
				       : $text{'add_nokeys2'};
	return &ui_select($name, undef,
		[ [ undef, $text{'add_nokeys'} ] ]);
	}
}

sub cleanup_key_data
{
local ($text) = @_;
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
# (if installed), the Webmin port and the Webmin SSL flag.
sub check_server_ssh_login
{
local ($server) = @_;

# Check if the server type has its own login check function, and if so
# call it
local $sfunc = "type_".$server->{'manager'}."_check_login";
if (defined(&$sfunc)) {
	# Type has defined it's own function for checking the status
	local @rv = &$sfunc($server);
	return @rv if (scalar(@rv));
	}

# Need to really SSH
local $cmd = "ssh -x -".$server->{'ssh_protocol'};
if ($server->{'key'}) {
	local ($key) = grep { $_->{'id'} == $server->{'key'} } &list_ssh_keys();
	$cmd .= " -i ".quotemeta($key->{'file'});
	}
if ($server->{'ssh_port'}) {
	$cmd .= " -p ".$server->{'ssh_port'};
	}
$cmd .= " $server->{'ssh_user'}\@$server->{'host'} 'grep ^root= /etc/webmin/miniserv.conf ; grep ^port= /etc/webmin/miniserv.conf ; grep ^ssl= /etc/webmin/miniserv.conf ; id -a ; echo OK'";
local ($status, $out) = &run_ssh_command($cmd, $server->{'ssh_pass'}, 30);
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
		local $root = $out =~ /root=(\S+)/ ? $1 : 0;
		local $port = $out =~ /port=(\S+)/ ? $1 : 0;
		local $ssl = $out =~ /ssl=(\S+)/ ? $1 : 0;
		if ($root && $ssl) {
			# Webmin wants SSL .. but can we really provide it?
			if (!$server->{'has_net_ssleay'}) {
				local $pp = &get_file_data_from_server($server,
						"/etc/webmin/perl-path");
				chop($pp);
				$pp ||= "perl";
				local ($sout, $sex) =
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
		return (0, $out, $root, $port, $ssl);
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
local ($server) = @_;
local $fast_try = 0;
if (!defined($server->{'fast'})) {
	# Try fast mode first
	$fast_try = 1;
	$server->{'fast'} = 1;
	}
local $rfc;
eval {
	local $SIG{'ALRM'} = sub { die "timeout\n" };
	local $main::error_must_die = 1;
	alarm(20);
	$last_remote_error = undef;
	$rfc = &remote_foreign_config($server, "");
	alarm(0);
	};
if ($last_remote_error) {
	local $ec = $last_remote_error =~ /Login\s+to\s+RPC/ ? 2 : 1;
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
local ($cmd, $pass, $timeout, $leave) = @_;
local ($wrong_password, $got_login, $connect_failed, $given_password);
local $out;
local $ex;
local ($fh, $fpid);
eval {
	local $SIG{'ALRM'} = sub { die "timeout\n" };
	local $main::error_must_die = 1;
	if ($timeout) {
		alarm($timeout);
		}
	($fh, $fpid) = &proc::pty_process_exec($cmd);
	while(1) {
		local $rv = &wait_for($fh, "password:", "yes\\/no", "(^|\\n)\\s*Permission denied.*\n", "ssh: connect.*\n", ".*\n", $leave ? ( $leave ) : ( ));
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
		elsif ($rv == 5) {
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
local ($server, $cmd, $timeout, $leave) = @_;
local $efunc = "type_".$server->{'manager'}."_execute_command";
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
	local $sshcmd = "ssh -q -x -".$server->{'ssh_protocol'};
	if ($server->{'key'}) {
		local ($key) = grep { $_->{'id'} == $server->{'key'} }
				    &list_ssh_keys();
		$sshcmd .= " -i ".quotemeta($key->{'file'});
		}
	if ($server->{'ssh_port'}) {
		$sshcmd .= " -p ".$server->{'ssh_port'};
		}
	if ($leave) {
		$sshcmd .= " -t";	# Force allocation of pty
		$cmd = "echo SERVER_MANAGER_LOGIN_DONE ; $cmd";
		}
	$sshcmd .= " $server->{'ssh_user'}\@$server->{'host'} ".quotemeta($cmd);
	local ($status, $out, $fh, $fpid) =
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

# get_file_from_server(&server, remotefile, localfile)
# Transfers a file from the given server to this system. May use scp or some
# type-specific method
sub get_file_from_server
{
local ($server, $remotefile, $localfile) = @_;
local $gfunc = "type_".$server->{'manager'}."_get_file";
if (defined(&$gfunc)) {
	# Use type-specific function call
	local $rv = &$gfunc(@_);
	return $rv if ($rv ne 'FALLBACK');	# Type-specific function has
						# asked to fallback to scp
	}
if ($server->{'ssh_nologin'}) {
	return "SSH logins are not available";
	}

# Just scp down
local $sshcmd = "scp -r";
$sshcmd .= " -o Protocol=".$server->{'ssh_protocol'};
if ($server->{'key'}) {
	local ($key) = grep { $_->{'id'} == $server->{'key'} }
			    &list_ssh_keys();
	$sshcmd .= " -i ".quotemeta($key->{'file'});
	}
if ($server->{'ssh_port'}) {
	$sshcmd .= " -P ".$server->{'ssh_port'};
	}
$sshcmd .= " $server->{'ssh_user'}\@$server->{'host'}:".
	   quotemeta($remotefile)." ".quotemeta($localfile);
local ($status, $out) = &run_ssh_command($sshcmd,$server->{'ssh_pass'});
return $status ? $out : undef;
}

# get_file_data_from_server(&server, remotefile)
# Returns the contents of some file
sub get_file_data_from_server
{
local ($server, $remotefile) = @_;
local $temp = &transname();
local $err = &get_file_from_server($server, $remotefile, $temp);
return undef if ($err);
local $data = &read_file_contents($temp);
&unlink_file($temp);
return $data;
}

# put_file_to_server(&server, localfile, remotefile)
# Transfers a file from this system to the given server. May use scp or some
# type-specific method
sub put_file_to_server
{
local ($server, $localfile, $remotefile) = @_;
local $pfunc = "type_".$server->{'manager'}."_put_file";
if (defined(&$pfunc)) {
	# Use type-specific function call
	local $rv = &$pfunc(@_);
	return $rv if ($rv ne 'FALLBACK');	# Type-specific function has
						# asked to fallback to scp
	}
if ($server->{'ssh_nologin'}) {
	return "SSH logins are not available";
	}

# Just scp up
local $sshcmd = "scp -r";
$sshcmd .= " -o Protocol=".$server->{'ssh_protocol'};
if ($server->{'key'}) {
	local ($key) = grep { $_->{'id'} == $server->{'key'} }
			    &list_ssh_keys();
	$sshcmd .= " -i ".quotemeta($key->{'file'});
	}
if ($server->{'ssh_port'}) {
	$sshcmd .= " -P ".$server->{'ssh_port'};
	}
$sshcmd .= " ".quotemeta($localfile).
	   " $server->{'ssh_user'}\@$server->{'host'}:".
	   quotemeta($remotefile);
local ($status, $out) = &run_ssh_command($sshcmd,$server->{'ssh_pass'});
return $status ? $out : undef;
}

# put_file_data_to_server(&server, data, remotefile)
# Writes the given data to some remote file. Returns an error message on failure
# or undef on success.
sub put_file_data_to_server
{
local ($server, $data, $remotefile) = @_;
local $temp = &transname();
&open_tempfile(TEMP, ">$temp", 0, 1);
&print_tempfile(TEMP, $data);
&close_tempfile(TEMP);
local $err = &put_file_to_server($server, $temp, $remotefile);
&unlink_file($temp);
return $err;
}

# transfer_file_between_servers(&source-server, &dest-server,
#				source-file, dest-file)
# Copy a file from one system to another, directly if possible. Returns undef
# if OK, or an error message on failure.
sub transfer_file_between_servers
{
local ($srcserver, $destserver, $src, $dest) = @_;
if ($srcserver->{'id'} eq $destserver->{'id'}) {
	# Self to self - just copy
	local ($out, $ex, $err) = &execute_command_on_server($srcserver,
		"cp ".quotemeta($src)." ".quotemeta($dest));
	return $err ? $err : $ex ? $out : undef;
	}
elsif ($srcserver->{'id'} == 0) {
	# Copying from VM2 master - just upload
	return &put_file_to_server($destserver, $src, $dest);
	}
elsif ($destserver->{'id'} == 0) {
	# Copying to VM2 master - just download
	return &get_file_from_server($srcserver, $src, $dest);
	}
else {
	# Both are remote! First try scp on source to dest
	# First build scp command
	if ($destserver->{'ssh_nologin'}) {
		return "SSH logins on target system are not available";
		}
	local $sshcmd = "scp -r";
	$sshcmd .= " -o Protocol=".$destserver->{'ssh_protocol'};
	local $keytemp;
	if ($destserver->{'key'}) {
		# A key is needed - copy it to the source system
		local ($key) = grep { $_->{'id'} == $destserver->{'key'} }
				    &list_ssh_keys();
		$keytemp = $key->{'file'};
		$keytemp =~ s/^.*[\\\/]//;
		$keytemp = "/tmp/$keytemp";
		&put_file_to_server($srcserver, $key->{'file'}, $keytemp);
		$sshcmd .= " -i ".quotemeta($keytemp);
		}
	if ($destserver->{'ssh_port'}) {
		$sshcmd .= " -P ".$destserver->{'ssh_port'};
		}
	$sshcmd .= " ".quotemeta($src);
	$sshcmd .= " $destserver->{'ssh_user'}\@$destserver->{'host'}:".
		   quotemeta($dest);
	if ($keytemp) {
		$sshcmd .= " ; rm -f ".quotemeta($keytemp);
		}

	# Then execute on the source system
	local ($out, $ex, $err, $status, $fh, $fpid) =
		&execute_command_on_server($srcserver, $sshcmd, undef, 1);
	if (!$err && !$ex) {
		# Started OK .. wait for a password prompt
		$out = undef;
		local ($given_password, $wrong_password, $connect_failed);
		while(1) {
			local $rv = &wait_for($fh, "password:", "yes\\/no", "(^|\\n)\\s*Permission denied.*\n", "ssh: connect.*\n", ".*\n");
			if ($rv == 0) {
				syswrite($fh, "$destserver->{'ssh_pass'}\n");
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
			elsif ($rv < 0) {
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
		    !$connect_failed) {
			# Looks like it did!
			return undef;
			}
		}
	if ($keytemp) {
		&delete_file_on_server($srcserver, $keytemp);
		}

	# Fall back to fetching to master and uploading
	local $srcfile = $src;
	$srcfile =~ s/^.*[\\\/]//;
	local $temp = &transname($srcfile);
	local $err = &get_file_from_server($srcserver, $src, $temp);
	return "Download to VM2 master failed : $err" if ($err);
	$err = &put_file_to_server($destserver, $temp, $dest);
	&unlink_file($temp);
	return "Upload from VM2 master failed : $err" if ($err);
	return undef;
	}
}

# delete_file_on_server(&server, remotefile)
# Deletes a file on a managed server. Returns undef on success, or an error
# message on failure.
sub delete_file_on_server
{
local ($server, $remotefile) = @_;
local $dfunc = "type_".$server->{'manager'}."_delete_file";
if (defined(&$dfunc)) {
	# Use type-specific function call
	local $rv = &$dfunc(@_);
	return $rv if ($rv ne 'FALLBACK');	# Type-specific function has
						# asked to fallback to scp
	}

# Just run rm via SSH
local ($out, $ex, $err) = &execute_command_on_server($server,
				"rm -rf ".quotemeta($remotefile));
return $err ? $err : $ex ? $out : undef;
}

# stat_file_on_server(&server, remotefile)
# Returns the stat structure for a file on a server.
# If something failed, returns a 1-element array containing the error.
# If the file doesn't exist, returns an empty array.
sub stat_file_on_server
{
local ($server, $remotefile) = @_;
local $gfunc = "type_".$server->{'manager'}."_stat_file";
if (defined(&$gfunc)) {
	# Use type-specific function call
	local @rv = &$gfunc(@_);
	return @rv if ($rv[0] ne 'FALLBACK');
	}

if ($server->{'status'} eq 'virt' || $server->{'status'} eq 'novirt') {
	# If the remote system has Webmin, ask it to stat
	$last_remote_error = undef;
	&remote_foreign_require($server, "webmin", "webmin-lib.pl");
	return ( $last_remote_error ) if ($last_remote_error);
	local $st = &remote_eval($server, "webmin", "[ stat('$remotefile') ]");
	return $st ? @$st : "Stat via Webmin failed";
	}
else {
	# Use perl, stat command, or in worst case ls -l
	local ($out, $ex, $err) = &execute_command_on_server($server,
		"perl -e 'print join(\":\", stat(\@ARGV[0]))' ".
		quotemeta($remotefile));
	return ( $err ) if ($err);
	if (!$ex) {
		$out =~ s/\r|\n//g;
		return split(/:/, $out);
		}

	# Now try stat
	local ($out, $ex, $err) = &execute_command_on_server($server,
		"stat -t ".quotemeta($remotefile));
	return ( $err ) if ($err);
	if ($out =~ /No such file/i) {
		return ( );
		}
	elsif (!$ex && $out =~ /^\Q$remotefile\E\s/) {
		# Parse stat command output
		local @w = split(/\s+/, $out);
		local @st;
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

	# Finally, use ls .. which gives less info :-(
	local ($out, $ex, $err) = &execute_command_on_server($server,
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
		local @now = localtime(time());
		local @w = split(/\s+/, $out);
		local @st;
		$st[3] = $w[1];			# Links
		$st[4] = $w[2];			# UID
		$st[5] = $w[3];			# GID
		$st[7] = $w[4];			# Size
		if ($w[7] =~ /^(\d+):(\d+)$/) {
			# Time is month day hour:minute
			local @tm = ( 0, $2, $1, $w[6],
				      &month_to_number($w[5]), $now[5] );
			$st[8] = $st[9] = $st[10] = timelocal(@tm);
			}
		elsif ($w[7] =~ /^\d+$/) {
			# Time is month day year
			local @tm = ( 0, 0, 0, $w[6],
				      &month_to_number($w[5]), $w[7]-1900 );
			$st[8] = $st[9] = $st[10] = timelocal(@tm);
			}
		$st[2] = 0;			# Permissions
		local @p = reverse(split(//, $w[0]));
		for(my $i=0; $i<9; $i++) {
			if ($p[$i] ne '-') {
				$st[2] += (1<<$i);
				}
			}
		return @st;
		}
	}
}

# has_command_on_server(&server, command)
# Returns the full path to some command, or undef if missing
sub has_command_on_server
{
local ($server, $cmd) = @_;
local ($out, $ex, $err) = &execute_command_on_server($server, "which $cmd");
if ($ex || $out =~ /no\s+\Q$cmd\E\s+in/) {
	# Failed .. but maybe we don't even have the which command??
	if ($out =~ /which:\s+command\s+not\s+found/i) {
		if ($cmd =~ /^\//) {
			# Full path given, so just look for it
			local (undef, $tex, undef) = &execute_command_on_server(
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

# list_processes_on_server(&server)
# Returns a list of running processes, in a format similar to
# proc::list_processes. Only the pid, user and args are guaranteed though.
# Return an array ref on success, or an error string on failure.
sub list_processes_on_server
{
local ($server) = @_;
local @procs;
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
local ($out, $ex, $err);
foreach my $cmd (
	[ "ps --cols 500 -e -o pid,user,args", 3, [ 0, 1, 2 ] ],  # Linux
	[ "ps -e -o pid,user,args", 3, [ 0, 1, 2 ] ],		  # Solaris
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
local $msg = $err || $out;
return "Failed to list processes : $msg";
}

sub remote_error_handler
{
$last_remote_error = join("", @_);
}

sub nice_error_status
{
local ($status) = @_;
return $text{'status_'.int($status)};
}

# os_to_server_type(os-code, real-os-type)
# Returns an OS type as used by the Webmin Servers Index module
sub os_to_server_type
{
local ($os, $realos) = @_;
local $type = 'unknown';
foreach my $s (@servers::server_types) {
	if ($s->[2] && $os =~ /^$s->[2]$/ || $s->[3] && $realos =~ /$s->[3]/) {
		$type = $s->[0];
		last;
		}
	}
return $type;
}

# ping_server_host(hostname|ip)
# Returns 1 if some host responds to a ping in 2 seconds
sub ping_server_host
{
local ($host) = @_;
local $pingcmd = $gconfig{'os_type'} =~ /-linux$/ ? "ping -c 1" : "ping";
local ($out, $timed_out) = &backquote_with_timeout(
	$pingcmd." ".$host." 2>&1", $ping_host_timeout, 1);
return !$timed_out && !$? ? 1 : 0;
}

# check_server_status(&server, [re-generate-collected], [skip-info], [time])
# Checks the status of a managed server, and updates the server object. Checks
# SSH login, Webmin login, Virtualmin status, number of domains, memory, disk
# and CPU load.
sub check_server_status
{
local ($server, $regen, $skipinfo, $time) = @_;

# Check if a status update is already happening
local $file = "$servers::module_config_directory/$server->{'id'}.serv";
if (&test_lock($file)) {
	# Already locked .. wait till free, and get new status from file
	local $c = 0;
	while(&test_lock($file)) {
		sleep(1);
		$c++;
		if ($c > 120) {
			# Too slow!
			&error("Pending status update for $server->{'host'} ".
			       "took more than 2 minutes");
			}
		}
	local ($newserver) = grep { $_->{'id'} eq $server->{'id'} }
				  &list_managed_servers();
	foreach my $k ('statustime', 'status', 'status_msg') {
		$server->{$k} = $newserver->{$k};
		}
	return $server->{'status'} eq 'virt' ||
	       $server->{'status'} eq 'novirt';
	}
else {
	# Lock to prevent concurrent access
	&lock_file($file);
	}

# Do a quick ping, if this is a non-virtual system.
# Don't ping if the virtual system type (ie Xen) has it's own function to 
# detect status though, unless SSH logins are disabled
$server->{'statustime'} = time();
local $clfunc = "type_".$server->{'manager'}."_check_login";
local $ping = &ping_server_host($server->{'host'});

# If SSH logins are disabled, go no further
if ($server->{'ssh_nologin'}) {
	local $status;
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
local $rv = 0;
local ($status, $err, $webminroot, $webminport, $webminssl) =
	&check_server_ssh_login($server);
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

# If we have a Webmin login, try it
local ($got_memory, $got_disk, $got_kernel);
if ($server->{'user'} || $server->{'id'} == 0) {
	local ($status, $err, $ostype, $real_ostype) =
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
	local $info;
	local $webmin_timeout = $regen ? 180 : 60;
	eval {
		local $SIG{'ALRM'} = sub { die "timeout\n" };
		local $main::error_must_die = 1;
		alarm($webmin_timeout);
		$server->{'status'} = 'virt';
		$server->{'status_msg'} = undef;
		if (&remote_foreign_check($server, "virtual-server") &&
		    !$server->{'novirtualmin'}) {
			# Get and save remote Virtualmin domains
			goto SKIPINFO if ($skipinfo);
			&remote_foreign_require($server, "virtual-server",
						"virtual-server-lib.pl");
			alarm($webmin_timeout * 3);	# Give this longer,
							# as connect worked
			local @doms = &remote_foreign_call($server,
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

			# Get and save serial number
			delete($info->{'serial'});
			if ($info->{'minfo'}->{'version'} !~ /gpl/) {
				local $serial = &remote_eval($server,
					"virtual_server",
					"\&read_env_file(\$virtualmin_license_file, \\\%serial); return \\\%serial");
				if ($serial->{'SerialNumber'} ne 'GPL') {
				    $info->{'serial'} =
					{ 'serial' => $serial->{'SerialNumber'},
					  'key' => $serial->{'LicenseKey'} };
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
		else {
			# Doesn't have Virtualmin
			&save_server_domains($server, [ ]);
			$server->{'status'} = 'novirt';
			$server->{'status_msg'} = undef;
			delete($server->{'virtualmin_domains'});
			delete($server->{'virtualmin_poss'});
			goto SKIPINFO if ($skipinfo);
			$info = { };

			# Make some direct Webmin calls to get info, starting
			# with memory total and used
			if (&remote_foreign_check("proc")) {
				&remote_foreign_require($server, "proc",
					"proc-lib.pl");
				local @load = &remote_foreign_call($server,
					"proc", "get_cpu_info");
				if (@load) {
					$info->{'load'} = \@load;
					}
				local @mem = &remote_foreign_call($server,
					"proc", "get_memory_info");
				if (@mem) {
					$info->{'mem'} = \@mem;
					$got_memory = 1;
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
		local $ifunc = "type_".$server->{'manager'}."_list_interfaces";
		if (!defined(&$ifunc) &&
		    &remote_foreign_check($server, "net")) {
			&remote_foreign_require($server, "net", "net-lib.pl");
			$info->{'ifaces'} = [ &remote_foreign_call(
				$server, "net", "active_interfaces") ];
			}

		# Refresh software packages, if enabled
		if (&get_server_cluster_software($server) > 0) {
			&refresh_server_cluster_software($server);
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
	$server->{'status'} = 'downwebmin';
	$server->{'status_msg'} = "Webmin login disabled";
	}
else {
	# Webmin is not available
	$server->{'status'} = $webminroot ? 'nowebminlogin' : 'nowebmin';
	$server->{'status_msg'} = undef;
	}

# If we couldn't get memory or disk from Webmin, get it via SSH
local $info = &get_server_collected($server);
local $got_more_info;
if (!$got_memory) {
	local ($out, $ex, $err) = &execute_command_on_server($server, "free");
	if (!$ex && !$err) {
		local @mem;
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
			$got_more_info = 1;
			}
		}
	local ($out, $ex, $err) = &execute_command_on_server($server, "uptime");
	if (!$ex && !$err &&
	    $out =~ /average:\s+([0-9\.]+),\s*([0-9\.]+),\s*([0-9\.]+)/i) {
		$info->{'load'} = [ $1, $2, $3 ];
		$got_more_info = 1;
		}
	}
if (!$got_disk) {
	local ($out, $ex, $err) = &execute_command_on_server($server, "df -kl");
	if (!$ex && !$err) {
		local @lines = split(/\r?\n/, $out);
		local ($total, $free);
		for(my $i=0; $i<@lines; $i++) {
			local $l = $lines[$i];
			if ($l =~ /^\/\S+$/) {
				# Filesystem name on own line
				$l .= $lines[++$i];
				}
			if ($l =~ /^\// && $l !~ /^\/platform\//) {
				local ($fs, $blocks, $used, $avail) =
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
	local ($out, $ex, $err) = &execute_command_on_server($server, 
		"uname -r ; uname -m ; uname -s");
	if (!$ex && !$err) {
		local ($r, $m, $o) = split(/\r?\n/, $out);
		$info->{'kernel'} = { 'version' => $r,
				      'arch' => $m,
				      'os' => $o };
		}
	}

&save_server_collected($server, $info);

$rv = 1;

# Call any type-specific post-refresh function
DONECHECK:
local $rfunc = "type_".$server->{'manager'}."_post_refresh";
if (defined(&$rfunc)) {
	&$rfunc($server);
	}

# Call any host-type-specific post-refresh function
foreach my $p (&is_parent_server($server)) {
	local $rfunc = "type_".$p."_post_host_refresh";
	if (defined(&$rfunc)) {
		&$rfunc($server);
		}
	}

# Add disk usage, CPU and memory to historic stats, if we got them
&add_historic_collected_info($info, $time || $server->{'statustime'}, $server);

&unlock_file($file);
return $rv;
}

# save_server_domains(&server, &domains)
# Writes out the list of domains hosted by some server
sub save_server_domains
{
local ($server, $doms) = @_;
if (!-d $server_domains_dir) {
	&make_dir($server_domains_dir, 0700);
	}
&open_tempfile(DOMS, ">$server_domains_dir/$server->{'id'}");
&print_tempfile(DOMS, &serialise_variable($doms));
&close_tempfile(DOMS);
$get_server_domains_cache{$server->{'id'}} = $doms;
}

# get_server_domains(&server)
# Returns an array of domain objects from some server
sub get_server_domains
{
local ($server) = @_;
if (!$get_server_domains_cache{$server->{'id'}}) {
	local $ddata = &read_file_contents(
			"$server_domains_dir/$server->{'id'}");
	return ( ) if (!$ddata);	# Not collected yet?
	local $doms = &unserialise_variable($ddata);
	$get_server_domains_cache{$server->{'id'}} = $doms;
	}
return @{$get_server_domains_cache{$server->{'id'}}};
}

# save_server_collected(&server, &info)
# Writes out the status information collected from some server
sub save_server_collected
{
local ($server, $info) = @_;
if (!-d $server_collected_dir) {
	&make_dir($server_collected_dir, 0700);
	}
if ($info) {
	# Have info to write
	&open_tempfile(DOMS, ">$server_collected_dir/$server->{'id'}");
	&print_tempfile(DOMS, &serialise_variable($info));
	&close_tempfile(DOMS);
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
local ($server) = @_;
return $get_server_collected_cache{$server->{'id'}}
	if ($get_server_collected_cache{$server->{'id'}});
local $idata = &read_file_contents("$server_collected_dir/$server->{'id'}");
return undef if (!$idata);	# Not collected yet?
local $rv = &unserialise_variable($idata);
$get_server_collected_cache{$server->{'id'}} = $rv;
return $rv;
}

# parallel_server_function(&servers, &function, [&args])
# Calls some function on multiple servers, in 10 (by default) processes.
# Returns an array of the return values from the functions in those processes.
sub parallel_server_function
{
local ($servers, $func, $args) = @_;

# Build 10 buckets
local @buckets;
local $procs = $config{'procs'};
for(my $i=0; $i<@$servers; $i++) {
	push(@{$buckets[$i % $procs]}, $servers->[$i]);
	}

# Create results dir
my $resdir = &transname();
&make_dir($resdir, 0700);

# Fork 10 processes, each doing a bucket
local @pids;
for(my $i=0; $i<$procs; $i++) {
	local @bservers = @{$buckets[$i]};
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
	local $pid = wait();
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

# parallel_check_server_status(&servers, [re-generate])
# Checks the status of multiple servers in 10 (by default) processes
sub parallel_check_server_status
{
local ($servers, $regen) = @_;
local $time = time();
return &parallel_server_function($servers,
	sub { &check_server_status($_[0], $regen, 0, $time);
	      &save_managed_server($_[0]);
	      return ( $_[0]->{'status'}, $_[0]->{'status_msg'},
		       $_[0]->{'virtualmin_domains'},
		       $_[0]->{'virtualmin_error'} );
	    });
}

# parallel_install_package_updates(&servers)
# Updates all packages on multiple servers, in 10 (by default) processes.
# Each element of the per-server return array is an hash ref with status,
# packages and error fields.
sub parallel_install_package_updates
{
local ($servers) = @_;
return &parallel_server_function($servers,
	sub { my $info = &get_server_collected($_[0]);
	      my @allgot;
	      foreach $p (&sort_package_updates(@{$info->{'poss'}})) {
	          local $got = &install_package_update($_[0], $p);
		  my $status = { 'name' => $p->{'name'},
				 'version' => $p->{'version'} };
		  if (ref($got)) {
		    # Installed something
                    $status->{'status'} = 1;
                    $status->{'updates'} = $got;
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
	    });
}

# refresh_server_updates(&server, &newly-gotten)
# Tell some server to refresh its list of installed packages
sub refresh_server_updates
{
local ($server, $got) = @_;
&remote_foreign_require($server, "virtual-server", "virtual-server-lib.pl");
&remote_foreign_call($server, "virtual-server",
		     "refresh_possible_packages", $got);
}

# domain_link(&server, &domain)
# Returns HTML for a link to edit a domain on some server
sub domain_link
{
local ($s, $d) = @_;
local $prot = $s->{'ssl'} ? 'https' : 'http';
local $target;
if ($s->{'id'} == 0) {
	# Link to Virtualmin on this server
	$url = "../virtual-server/edit_domain.cgi?dom=$d->{'id'}";
	}
else {
	# On another server
	local $info = &get_server_collected($s);
	local $path;
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
local ($server) = @_;
local $prot = $server->{'ssl'} ? 'https' : 'http';
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
local ($server, $prog, $args) = @_;
local ($out, $ex);

if ($server->{'id'} == 0) {
	# Local .. so we can just run the program
	local $mrd = &module_root_directory("virtual-server");
	local $cmd = "$mrd/$prog.pl";
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
	local $path = "/virtual-server/remote.cgi?program=$prog";
	foreach my $a (@$args) {
		$path .= "&".&urlize($a->[0])."=".&urlize($a->[1]);
		}
	local $herr;
	&http_download($server->{'host'}, $server->{'port'}, $path, \$out,
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
	local @lines = grep { /\S/ } split(/\r?\n/, $out);
	local $err;
	if ($out =~ /usage:/i) {
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
local ($server) = @_;
return 1024;	# Guess for now
}

# install_package_update(&server, &package)
# Installs an updated package on some system, and returns the array ref of new
# packages installed, or an error message
sub install_package_update
{
local ($server, $p) = @_;
$last_remote_error = undef;
&remote_foreign_require($server, "security-updates", "security-updates-lib.pl");
local ($out, $rv) = &remote_foreign_call($server, "security-updates",
		"capture_function_output", "security_updates::package_install",
		$p->{'update'} || $p->{'name'}, $p->{'system'});
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
local ($msg, $cgi, $hiddens, $ok, $post) = @_;
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
local ($server, $force) = @_;
local $sfunc = "type_".$server->{'manager'}."_shutdown";
if (defined(&$sfunc)) {
	# Type provides a shutdown function
	return &$sfunc($server, $force);
	}
elsif ($server->{'status'} eq 'virt' || $server->{'status'} eq 'novirt') {
	# Can use Webmin API call
	$last_remote_error = undef;
	&remote_foreign_require($server, "init", "init-lib.pl");
	local $iconfig = &remote_foreign_config($server, "init");
	&remote_foreign_call($server, "init", "execute_command",
			     $iconfig->{'shutdown_command'});
	return $last_remote_error;
	}
else {
	# Need to try SSHing in
	local %iconfig = &foreign_config("init");
	local ($out, $ex, $err) = &execute_command_on_server($server,
		"$iconfig{'shutdown_command'} || shutdown now || shutdown -i 5 -g 0 -y");
	return $err ? $err : $ex ? $out : undef;
	}
}

# reboot_server(&server)
# Remotely reboot some system. Returns undef on success, or an error
# message on failure.
sub reboot_server
{
local ($server) = @_;
local $rfunc = "type_".$server->{'manager'}."_reboot";
if (defined(&$rfunc)) {
	# Type provides a reboot function
	return &$rfunc($server);
	}
elsif ($server->{'status'} eq 'virt' || $server->{'status'} eq 'novirt') {
	# Can use Webmin API call
	$last_remote_error = undef;
	&remote_foreign_require($server, "init", "init-lib.pl");
	local $iconfig = &remote_foreign_config($server, "init");
	&remote_foreign_call($server, "init", "execute_command",
			     $iconfig->{'reboot_command'});
	return $last_remote_error;
	}
else {
	# Need to try SSHing in
	local %iconfig = &foreign_config("init");
	local ($out, $ex, $err) = &execute_command_on_server($server,
		"$iconfig{'reboot_command'} || shutdown -r now || reboot");
	return $err ? $err : $ex ? $out : undef;
	}
}

# startup_server(&server)
# Start up some virtual system by calling it's type-specific function.
# Returns a status code (0=failed, 1=OK, 2=No ping, 3=No SSH) and an error
# message.
sub startup_server
{
local ($server) = @_;
local $sfunc = "type_".$server->{'manager'}."_startup";
local ($ok, $err) = &$sfunc($server);
return ($ok, $err) if (!$ok);

# If the server has Webmin, wait for it to come up
if ($server->{'user'} && $ok != 2) {
	local $wtries = 0;
	while($wtries++ < 60) {
		sleep(1);
		local $werr;
		&open_socket($server->{'host'}, $server->{'port'} || 10000,
			     WTEST, \$werr);
		if (!$werr) {
			close(WTEST);
			last;
			}
		}
	}
return (1, undef);
}

sub server_in
{
local ($server) = @_;
#return &text('server_in', "<tt>$server->{'host'}</tt>");
return "<tt>$server->{'host'}</tt>";
}

# get_install_webmin_source(&server)
# Works out where to install Webmin from on some server, based on it's support
# for RPM or Debian packages.
sub get_install_webmin_source
{
local ($server) = @_;
local $type;

# Check what package system the host uses
local ($type, $update, $os) = &get_server_package_system($server);
if (!$type || $type eq "pkgadd") {
	# Don't use Solaris package of Webmin, as upgrading sucks
	$type = "tgz";
	}

# Work out download URL
local $source = $config{'download_'.$type} ||
		$webmin_download_source{$type};
return ($source, $type, undef);
}

# install_webmin_server(&server, src, type, set-password)
# Attempt to install Webmin on some system, from the given source and type.
# Returns the output and an error message on failure.
sub install_webmin_server
{
local ($server, $src, $type, $setpass) = @_;
local ($out, $ex, $err);
$src =~ /\/([^\/]+)$/;
local $temp = "/tmp/$1";
local $rootdir;

# Try to install Perl and other dependencies
if (!&has_command_on_server($server, "perl") ||
    !&has_command_on_server($server, "wget")) {
	local ($pstatus, $pout) = &install_package_on_server($server,
							     "perl", "wget");
	if (!$pstatus && $pout) {
		return ($pout, "Failed to install required packages");
		}
	elsif (!$pstatus) {
		return (undef, "Perl and Wget are required to install Webmin, but cannot be automatically installed");
		}
	}

# Make sure the system has Perl
local $perlpath = &has_command_on_server($server, "perl");
$perlpath || return (undef, "Perl is not installed");

if ($type eq "rpm") {
	# RPM install direct from the URL
	local ($wout, $wex, $werr) = &execute_command_on_server($server,
		"rm -f $temp && wget -nv -O $temp $src && rpm -U --nodeps $temp && rm -f $temp");
	return (undef, $werr) if ($werr);
	return ($wout, "RPM failed") if ($wex);
	$rootdir = "/usr/libexec/webmin";
	$out .= $wout;
	}

elsif ($type eq "dpkg") {
	# Download the deb and install it
	local ($wout, $wex, $werr) = &execute_command_on_server($server,
		"rm -f $temp && wget -nv -O $temp $src && dpkg --install --force-depends $temp && rm -f $temp");
	return (undef, $werr) if ($werr);
	return ($wout, "Debian package failed") if ($wex);
	$rootdir = "/usr/share/webmin";
	$out .= $wout;

	# Satisfy any Debian dependencies created by Webmin, if possible
	local ($dout, $dex, $derr) = &execute_command_on_server($server,
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
	local $crypt = $server->{'ssh_pass'} ? 'x' : 'fixlater';
	local $basedir = $server->{'manager'} eq 'zones' ? "/opt"
							 : "/usr/local";
	$rootdir = "$basedir/webmin";
	local ($wout, $wex, $werr) = &execute_command_on_server($server,
	    "wget -nv -O $temp $src && mkdir -p $basedir && cd $basedir && gunzip -c $temp | tar xf - && echo webmin-*/version && rm -f $temp");
	return (undef, $werr) if ($werr);
	return ($wout, "Tar file download or extraction failed") if ($wex);
	local $tardir;
	if ($wout =~ /(webmin-([0-9\.]+))\/version/) {
		$tardir = $1;
		}
	else {
		return ($wout, "Tar extraction failed");
		}
	local ($wout, $wex, $werr) = &execute_command_on_server($server,
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
local ($sshstatus, $ssherr, $wroot, $wport, $wssl) =
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
		local $perr = &set_server_webmin_password(
				$server, $rootdir, "root", $server->{'pass'});
		if ($perr) {
			$out .= "\nFailed to set Webmin password : $perr\n";
			}
		}
	}

# Call type-specific post configuration function
local $wfunc = "type_".$server->{'manager'}."_post_webmin";
if (defined(&$wfunc)) {
	&$wfunc($server, $wroot, $wport, $wssl);
	}

# Make sure Webmin is running OK, and get the OS
local ($wstatus, $werr, $wos, $wrealos) = &check_server_webmin_login($server);
if ($wstatus == 0) {
	$server->{'type'} = &os_to_server_type($wos, $wrealos);
	}
else {
	# Argh .. could not connect after all that work :(
	$out .= "\nWebmin installed, but could not connect : $werr\n";
	}

return ($out, undef, $wroot);
}

# wait_webmin_server(&server, timeout)
# Wait for Webmin to start accepting connections on some server. Returns undef
# if OK, or the last error message on timeout.
sub wait_webmin_server
{
local ($server, $timeout) = @_;
local $start = time();
local $err;
while(time() - $start < $timeout) {
	local $fh = "WEBMINSOCK";
	if (&open_socket($server->{'host'}, $server->{'port'}, $fh, \$err)) {
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
local $pass;
while(length($pass) < 8) {
	$pass .= chr(int(rand()*26)+97);
	}
return $pass;
}

# set_server_webmin_password(&server, webminroot, user, pass)
# Change the Webmin password on some server
sub set_server_webmin_password
{
local ($server, $webmindir, $user, $pass) = @_;
local ($pout, $pex, $perr) = &execute_command_on_server($server,
	"$webmindir/changepass.pl /etc/webmin $user ".quotemeta($pass));
return $perr ? $perr : $pex ? $pout : undef;
}

# set_server_webmin_password_crypt(&server, user, crypted)
# Sets the password for some user in Webmin to an encrypted string
sub set_server_webmin_password_crypt
{
local ($server, $user, $crypted) = @_;

# Get the miniserv.users file
local $passfile = "/etc/webmin/miniserv.users";
local $temp = &transname();
local $err = &get_file_from_server($server, $passfile, $temp);
return $err if ($err);

# Patch the line for the user
local $found;
local $lref = &read_file_lines($temp);
foreach my $l (@$lref) {
	local @w = split(/:/, $l);
	if ($w[0] eq $user) {
		$w[1] = $crypted;
		$l = join(':', @w);
		$found = 1;
		}
	}
&flush_file_lines($temp);
$found || return "Webmin user $user does not exist";

# Upload to server
local $err = &put_file_to_server($server, $temp, $passfile);
return $err if ($err);

# Update Webmin to apply the change
if ($server->{'status'} eq 'virt' ||
    $server->{'status'} eq 'novirt' ||
    $server->{'status'} eq 'nowebminlogin') {
	local ($out, $ex, $err) = &execute_command_on_server($server,
		"kill -USR1 `cat /var/webmin/miniserv.pid`");
	return $err if ($err);
	return "Failed to reload Webmin : $out" if ($ex);
	}

return undef;
}

# list_bind_zones()
# Returns a list of BIND master zones that we can add vserver hostnames to
sub list_bind_zones
{
if (&foreign_installed("bind8")) {
	&foreign_require("bind8", "bind8-lib.pl");
	return sort { $a->{'name'} cmp $b->{'name'} }
		 grep { $_->{'type'} eq 'master' &&
		        $_->{'name'} !~ /in-addr/i } &bind8::list_zone_names();
	}
return ( );
}

# add_bind8_record(dnsname, ip, zonename)
# Adds a DNS record for some new virtual system to the given zone, if it exists
sub add_bind8_record
{
local ($dnsname, $ip, $zonename) = @_;
&foreign_require("bind8", "bind8-lib.pl");

local @zones = &list_bind_zones();
local ($zone) = grep { $_->{'name'} eq $zonename } @zones;
if ($zone) {
	&$first_print(&text('create_vserverdns', $dnsname, $ip));
	local @recs = &bind8::read_zone_file($zone->{'file'}, $zone->{'name'});
	local ($aready) = grep { $_->{'name'} eq $dnsname } @recs;
	if (!$already) {
		# Need to add
		&bind8::create_record($zone->{'file'}, $dnsname, undef,
				      "IN", "A", $ip);
		&bind8::bump_soa_record(\@recs);

		# See if we can add to a reverse too
		local ($rfn, $rrecs, $arpa, $rzone) =
			&get_reverse_dns_zone($ip);
		if ($rfn) {
			my ($old) = grep { $_->{'values'}->[0] eq $dnsname }
					 @$rrecs;
			if (!$old) {
				&bind8::create_record($rfn, $arpa.".", undef,
						      "IN", "PTR", $dnsname);
				&bind8::bump_soa_record($rrecs);
				}
			}

		&bind8::restart_bind();
		&$second_print($text{'create_done'});
		return 1;
		}
	else {
		&$second_print($text{'create_vserverdnsalready'});
		}
	}
return 0;
}

# delete_bind8_record(dnsname, zonename, ip)
# Deletes the DNS record that belonged to some server
sub delete_bind8_record
{
local ($dnsname, $zonename, $ip) = @_;
&foreign_require("bind8", "bind8-lib.pl");
local @zones = &list_bind_zones();
local ($zone) = grep { $_->{'name'} eq $zonename } @zones;
if ($zone && $dnsname) {
	local @recs = &bind8::read_zone_file($zone->{'file'}, $zone->{'name'});
	local ($r) = grep { $_->{'name'} eq $dnsname } @recs;
	if ($r) {
		# Can remove
		&bind8::delete_record($zone->{'file'}, $r);
		&bind8::bump_soa_record(\@recs);

		# See if we can remove a reverse too
		local ($rfn, $rrecs, $arpa, $rzone) =
			&get_reverse_dns_zone($ip);
		if ($ip && $rfn) {
			my ($old) = grep { $_->{'values'}->[0] eq $dnsname }
					 @$rrecs;
			if ($old) {
				&bind8::delete_record($rfn, $old);
				&bind8::bump_soa_record($rrecs);
				}
			}

		&bind8::restart_bind();
		}
	}
}

# get_reverse_dns_zone(ip)
# Returns the records file and list of records for the domain for some IP
sub get_reverse_dns_zone
{
local ($ip) = @_;
local $conf = &bind8::get_config();
local @zones = &bind8::find("zone", $conf);
foreach my $v (&bind8::find("view", $conf)) {
	push(@zones, &bind8::find("zone", $v->{'members'}));
	}
local $arpa = &bind8::ip_to_arpa($ip);
$arpa =~ s/\.$//;
local ($z) = grep { $arpa =~ /\.$_->{'value'}$/i } @zones;
return ( ) if (!$z);
local $file = &bind8::find("file", $z->{'members'});
local $fn = $file->{'values'}->[0];
local @recs = &bind8::read_zone_file($fn, $config{'domain'});
return ( $fn, \@recs, $arpa, $z->{'value'} );
}

sub bind_module_link
{
return "<a href=../bind8/index.cgi>$text{'index_bindlink'}</a>";
}

# find_server_dependencies(&server)
# Returns a list of other servers that depend on this one
sub find_server_dependencies
{
local ($server) = @_;
local @allservers = &list_managed_servers();
local @rv;
foreach my $t (@server_management_types) {
	local $dfunc = "type_".$t."_depends";
	if (defined(&$dfunc)) {
		push(@rv, grep { local $_; $_->{'id'} != $server->{'id'} &&
				 &$dfunc($server, $_) } @allservers);
		}
	}
return @rv;
}

# allocate_ip_address(start-ips, end-ips, cidrs)
# Returns an IP address from the given range that is not in use or pingable,
# and a CIDR. If not IP could be allocated, returns undef.
sub allocate_ip_address
{
local ($startips, $endips, $cidrs) = @_;
local @startips = split(/\s+/, $startips);
local @endips = split(/\s+/, $endips);
local @cidrs = split(/\s+/, $cidrs);
local %used = &used_ip_addresses();
for(my $i=0; $i<@startips; $i++) {
	local $start = &net::ip_to_integer($startips[$i]);
	local $end = &net::ip_to_integer($endips[$i]);
	for(my $n=$start; $n<=$end; $n++) {
		local $ip = &net::integer_to_ip($n);
		if (!$used{$ip} && !&ping_server_host($ip)) {
			return ($ip, $cidrs[$i]);
			}
		}
	}
return ( );
}

# describe_ip_range(start-ips, end-ips)
# Turns space-separated strings of ranges into a nicer format
sub describe_ip_range
{
local ($startips, $endips, $cidrs) = @_;
local @startips = split(/\s+/, $startips);
local @endips = split(/\s+/, $endips);
local @rv;
for(my $i=0; $i<@startips; $i++) {
	if ($startips[$i] eq $endips[$i]) {
		push(@rv, $startips[$i]);
		}
	else {
		local @so = split(/\./, $startips[$i]);
		local @eo = split(/\./, $endips[$i]);
		if ($so[0] == $eo[0] && $so[1] == $eo[1] && $so[2] == $eo[2]) {
			push(@rv, "$so[0].$so[1].$so[2].$so[3]-$eo[3]");
			}
		else {
			push(@rv, $startips[$i]."-".$endips[$i]);
			}
		}
	}
return join(", ", @rv);
}

# used_ip_addresses()
# Returns a hash of all IP addresses used by managed systems
sub used_ip_addresses
{
local %used;
foreach my $s (&list_managed_servers()) {
	$used{&to_ipaddress($s->{'host'})} = $s;
	local $ifunc = "type_".$s->{'manager'}."_list_interfaces";
	local $cfunc = "type_".$s->{'manager'}."_can_interfaces";
	local $should = !defined(&$cfunc) ? 0 :
			&$cfunc($s) == 0 ? 0 :
			&$cfunc($s) == 2 ? ($s->{'status'} eq 'virt' ||
					    $s->{'status'} eq 'novirt') :
					   $s->{'status'} ne 'nohost';
	if ($should) {
		# Get from server manager virtual interfaces
		local $ifaces = &$ifunc($s);
		if (ref($ifaces)) {
			foreach my $iface (@$ifaces) {
				$used{$iface->{'address'}} = $s;
				}
			}
		}
	else {
		# Get from active IPs, from last poll
		local $coll = &get_server_collected($s);
		if ($coll->{'ifaces'}) {
			foreach my $iface (@{$coll->{'ifaces'}}) {
				if ($iface->{'address'}) {
					$used{$iface->{'address'}} = $s;
					}
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
local ($server) = @_;
local ($pkg, $update, $os);
local $cache = $server_package_system_cache{$server->{'id'}};
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
	local ($out, $ex, $err) = &execute_command_on_server($server,
		"uname -s");
	if ($out =~ /SunOS|Solaris/i) {
		$os = "solaris";
		}
	}
if (!$os || $os eq 'unknown') {
	# Could not get OS, so check useful system files
	# XXX this should really be done with os_list.txt
	local ($out, $ex, $err) = &execute_command_on_server($server,
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
local ($server, @names) = @_;
local ($pkg, $update, $os) = &get_server_package_system($server);

# Try to use the software module to resolve names
local $lib = &module_root_directory("software")."/".$update."-lib.pl";
if (-r $lib) {
	if (!$done_require{$lib}++) {
		require $lib;
		}
	if (defined(&update_system_resolve)) {
		local @newnames;
		foreach my $n (@names) {
			push(@newnames,
			     split(/\s+/, &update_system_resolve($n)));
			}
		@names = @newnames;
		}
	}

local $names = join(" ", map { quotemeta($_) } @names);
if ($update eq "apt") {
	# Use apt-get
	&execute_command_on_server($server, "apt-get update");
	local ($pout, $pex, $perr) = &execute_command_on_server(
		$server, "apt-get -y -f --force-yes install $names </dev/null | cat");
	return $pex ? (0, $pout) : $perr ? (0, $perr) : (1, $pout);
	}
elsif ($update eq "yum") {
	# Use YUM
	local ($pout, $pex, $perr) = &execute_command_on_server(
		$server, "yum -y install $names </dev/null");
	return $pex ? (0, $pout) : $perr ? (0, $perr) : (1, $pout);
	}
elsif ($update eq "csw") {
	# Use blastwave, in full auto mode
	&execute_command_on_server(
	    $server, "cp -p /var/pkg-get/admin /var/pkg-get/admin-old");
	&execute_command_on_server(
	    $server, "cp -p /var/pkg-get/admin-fullauto /var/pkg-get/admin");
	local ($pout, $pex, $perr) = &execute_command_on_server(
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
local ($server, $setpass, $serial, $key) = @_;

# Check for a supported OS
local ($pkg, $update, $os) = &get_server_package_system($server);
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
	local ($osinfo) = grep { $_->[0] eq $os } @servers::server_types;
	foreach my $s (@virtualmin_operating_systems) {
		local ($sosinfo) = grep { $_->[0] eq $s }
					@servers::server_types;
		push(@supp, $sosinfo->[1]);
		}
	return &text('virtualmin_eos2', $osinfo->[1], join(", ", @supp));
	}

if (!$serial) {
	return $text{'virtualmin_elicence'};
	}

# Download the installer
local $itemp = &transname("virtualmin-install.sh");
local $error;
&http_download($virtualmin_licence_host,
	       $virtualmin_licence_port,
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
local $script = "/virtualmin-install.sh";
local $err = &put_file_to_server($server, $itemp, $script);
unlink($itemp);
return &text('virtualmin_ecopy', $err) if ($err);

# Call type-specific pre function
local $pfunc = "type_".$server->{'manager'}."_pre_virtualmin";
if (defined(&$pfunc)) {
	local $err = &$pfunc($server, $pkg, $update, $os, $script);
	return $err if ($err);
	}

# Install perl, wget and fuser, if needed
if (!&has_command_on_server($server, "wget")) {
	local ($wok, $werr) = &install_package_on_server($server, "wget");
	if (!$wok) {
		return $werr ? &text('virtualmin_ewget', $werr, "wget") :
			       $text{'virtualmin_ewget2', "wget"};
		}
	}
if (!&has_command_on_server($server, "perl")) {
	local ($wok, $werr) = &install_package_on_server($server, "perl");
	if (!$wok) {
		return $werr ? &text('virtualmin_ewget', $werr, "perl") :
			       $text{'virtualmin_ewget2', "perl"};
		}
	}
if (!&has_command_on_server($server, "fuser")) {
	local ($wok, $werr) = &install_package_on_server($server, "psmisc");
	if (!$wok) {
		return $werr ? &text('virtualmin_ewget', $werr, "wget") :
			       $text{'virtualmin_ewget2', "wget"};
		}
	}

# Run the install script, capturing output to a file
local $temp = "/tmp/virtualmin-install.out";
$server->{'virtualmin_temp'} = $temp;
local ($out, $ex, $err) = &execute_command_on_server($server,
	"chmod +x $script ; ((echo y ; echo $server->{'host'}) | $script && echo SERVER-MANAGER-COMPLETE) >$temp 2>&1 &");

return undef;
}

# install_virtualmin_server_done(&server)
# Checks the status of the Virtualmin install one some server. Returns OK
# when done, undef if still waiting, or an error message on failure.
sub install_virtualmin_server_done
{
local ($server) = @_;

# Check if the installer is still running
local $temp = $server->{'virtualmin_temp'};
local ($out) = &execute_command_on_server($server, "fuser $temp");
local @pids;
while($out =~ /(\d+)(.*)/) {
	push(@pids, $1);
	$out = $2;
	}
if (@pids) {
	# Yes .. try again later
	return undef;
	}

# Remove the install script
local $script = "/virtualmin-install.sh";
&execute_command_on_server($server, "rm -f ".quotemeta($script));

# Done .. but did it work?
local ($tout, $tex, $terr) = &execute_command_on_server($server,
				"tail -20 $temp ; rm -f $temp");
if ($tout !~ s/SERVER-MANAGER-COMPLETE//) {
	# Looks like it didn't ..
	return "<pre>".&html_escape($tout)."</pre>";
	}

# Make sure it REALLY got installed, by looking for Webmin
local ($sstatus, $serr, $webminroot, $webminport, $webminssl) =
	&check_server_ssh_login($server);
if (!$webminroot) {
	return "<pre>".&html_escape($tout)."</pre>";
	}
$server->{'port'} = $webminport;
$server->{'ssl'} = $webminssl;

# And check for Virtualmin root
local ($out, $ex, $err) = &execute_command_on_server($server,
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
	local $perr = &set_server_webmin_password(
			$server, $webminroot, "root", $server->{'pass'});
	if ($perr) {
		return &text('virtualmin_epass', $perr);
		}
	}

# At end, do a config check
&remote_foreign_require($server, "virtual-server", "virtual-server-lib.pl");
local $cerr = &remote_foreign_call($server, "virtual-server",
				   "check_virtual_server_config");
if ($cerr) {
	$server->{'virtualmin_checked'} = 0;
	$server->{'virtualmin_error'} = 1;
	}
else {
	$server->{'virtualmin_checked'} = 1;
	}

# Call type-specific post function
local $pfunc = "type_".$server->{'manager'}."_post_virtualmin";
if (defined(&$pfunc)) {
	local $perr = &$pfunc($server, $pkg, $update, $os);
	return $perr if ($perr);
	}

return "OK";
}

sub licence_error_message
{
local ($lstatus, $lexpiry, $lerr, $lservers) = &check_server_manager_licence();
return undef if (!$lerr);
local $rv = "<table width=100%><tr bgcolor=#ff8888><td align=center>";
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

# check_server_manager_licence()
# Checks the licence for this module, by looking for a file with the
# licence flag set. In this function, the status from the most recent check
# from Cron is used.
sub check_server_manager_licence
{
local %licence;
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
local $id;
if (&has_command("hostid")) {
	chop($id = `hostid 2>/dev/null`);
	}
if (!$id) {
	local ($iface) = grep { $_->{'fullname'} eq $config{'iface'} }
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
local ($licence) = @_;
$licence->{'expiry'} = undef;
$licence->{'servers'} = 0;
$licence->{'last'} = time();

# Do we have a licence file?
local ($serial, $key) = &get_server_manager_serial();
if (!$serial || !$key) {
	# No!
	$licence->{'status'} = 1;
	$licence->{'err'} = $text{'licence_efile'};
	return;
	}

# Work out a host ID, from the hostid command or MAC address or hostname
local $id = &get_host_id();

# Phone home to see if it is valid
local ($status, $err, $expiry, $servers) =
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
local ($id, $serial, $key) = @_;
local ($out, $error);
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
local ($server, $noreq) = @_;
if ($server->{'status'} eq 'virt') {
	if (!$noreq) {
		&remote_foreign_require($server, "virtual-server",
						 "virtual-server-lib.pl");
		}
	local $cerr = &remote_foreign_call($server, "virtual-server",
				   "set_all_null_print");
	local $cerr = &remote_foreign_call($server, "virtual-server",
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

# get_interface_use(&server, &info, &domains, &iface)
# Returns a code and string describing what some interface is for. Codes
# are 0=none, 1=default IP for Virtualmin, 2=For domain
sub get_interface_use
{
local ($server, $info, $doms, $iface) = @_;
if ($iface->{'address'} eq $info->{'defip'}) {
	return (1, $text{'iface_default'});
	}
else {
	local @ipdoms = grep { $_->{'ip'} eq $iface->{'address'} } @$doms;
	if (@ipdoms) {
		return (2,
			@ipdoms > 4 ? &text('iface_many', scalar(@ipdoms)) :
			@ipdoms == 1 ? &text('iface_dom', 
					     "<tt>$ipdoms[0]->{'dom'}</tt>") :
			&text('iface_doms', 
		          join(", ", map { "<tt>$_->{'dom'}</tt>" } @ipdoms)) );
		}
	elsif ($iface->{'address'} eq &to_ipaddress($server->{'host'})) {
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
local ($server) = @_;
local ($key) = grep { $_->{'id'} eq $server->{'key'} } &list_ssh_keys();
local $authkeys = &setup_authorized_keys($server);
local $temp = &transname();
&open_tempfile(AUTH, ">$temp");
&print_tempfile(AUTH, &generate_public_key($key),"\n");
&close_tempfile(AUTH);
&set_ownership_permissions(undef, undef, 0700, $temp);
return &put_file_to_server($server, $temp, $authkeys);
}

# setup_authorized_keys(&server)
# Ensure that ~/.ssh exists, and return the path to  the authorized_keys file
sub setup_authorized_keys
{
local ($server) = @_;

# Work out root's home dir
local $roothome;
local $data = &get_file_data_from_server($server, "/etc/passwd");
foreach my $l (split(/\r?\n/, $data)) {
	local @w = split(/:/, $l);
	if ($w[0] eq 'root') {
		$roothome = $w[5];
		last;
		}
	}
$roothome ||= "/root";

# Create .ssh dir if missing
local $sshdir = "$roothome/.ssh";
local @st = &stat_file_on_server($server, "$sshdir");
if (!@st) {
	local $temp = &transname();
	&make_dir($temp, 0700);
	&put_file_to_server($server, $temp, $sshdir);
	}

return "$roothome/.ssh/authorized_keys";
}

# set_shadow_root_password(&server, pass)
# Sets the root password for a server by directly editing /etc/shadow
sub set_shadow_root_password
{
local ($server, $pass) = @_;

# If this is an EC2 server, the default SSHd config doesn't allow password-less
# root logins! Fix that (in advanced, so that the new password works)
if ($server->{'manager'} eq 'ec2') {
	&fix_ssh_root_login($server);
	&execute_command_on_server($server, "killall -HUP sshd");
	}

local $shadow = &transname();
local $passfile = "/etc/shadow";
local $err = &get_file_from_server($server, $passfile, $shadow);
if ($err) {
	# Perhaps it has /etc/passwd?
	$passfile = "/etc/passwd";
	$err = &get_file_from_server($server, $passfile, $shadow);
	}
if (!$err) {
	local $lref = &read_file_lines($shadow);
	foreach my $l (@$lref) {
		local @w = split(/:/, $l, -1);
		if ($w[0] eq "root") {
			local $salt = substr(time(), -2);
			$w[1] = &unix_crypt($pass, $salt);
			$l = join(':', @w);
			}
		}
	&flush_file_lines($shadow);
	$err = &put_file_to_server($server, $shadow, $passfile);
	}

return $err;
}

# clear_authorized_key(&server)
# Delete root's authorized_keys file from a server
sub clear_authorized_key
{
local ($server) = @_;
local ($out, $ex, $err) = &execute_command_on_server($server,
				"rm -f .ssh/authorized_keys ; ".
				"rm -f .ssh/authorized_keys2");
return $err ? $err : $ex ? $out : undef;
}

# has_addnew_keys(&server)
# Returns 1 if there are any extra SSH keys to add for this server
sub has_addnew_keys
{
local ($server) = @_;
local @keys = grep { $_->{'id'} ne $server->{'key'} && $_->{'addnew'} }
		   &list_ssh_keys();
return @keys ? 1 : 0;
}

# addnew_authorized_keys(&server)
# Add extra authorized keys to a new server
sub addnew_authorized_keys
{
local ($server) = @_;
local $authkeys = &setup_authorized_keys($server);
local $temp = &transname();
&get_file_from_server($server, $authkeys, $temp);	# OK if missing
local $missing = -r $temp ? 0 : 1;
&open_tempfile(AUTH, ">>$temp");
foreach my $key (grep { $_->{'id'} ne $server->{'key'} && $_->{'addnew'} }
		      &list_ssh_keys()) {
	&print_tempfile(AUTH, &generate_public_key($key),"\n");
	}
&close_tempfile(AUTH);
&set_ownership_permissions(undef, undef, 0700, $temp) if ($missing);
return &put_file_to_server($server, $temp, $authkeys);
}

# check_domain_move(&serverdoms, &destserver, delete, direct, re-allocate-ip)
# Checks if the given set of virtual servers can be moved together, and returns
# an error message if not.
sub check_domain_move
{
local ($serverdoms, $dest, $delete, $direct, $realloc) = @_;
local @destdoms = &get_server_domains($dest);
local %sources;

foreach my $sd (@$serverdoms) {
	local ($server, $d) = @$sd;
	$sources{$server->{'id'}} ||= $server;
	if ($d->{'parent'}) {
		# This is a sub-server .. either the parent must be on the
		# target already, or in the list of those to move.
		local ($pd) = grep { $_->[1]->{'id'} == $d->{'parent'} }
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
			local @srcdoms = &get_server_domains($server);
			local @children = grep { $_->{'parent'} == $d->{'id'} }
					       @srcdoms;
			foreach my $cd (@children) {
				local ($inlist) =
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
	local ($idclash) = grep { $_->{'id'} eq $d->{'id'} } @destdoms;
	if ($idclash) {
		return &text('dmass_emoveclash', $d->{'dom'});
		}
	local ($clash) = grep { $_->{'dom'} eq $d->{'dom'} } @destdoms;
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
		local ($out, $ex, $err) = &execute_command_on_server($server,
			"ssh -o PasswordAuthentication=no -x ".
			"-".$dest->{'ssh_protocol'}." ".
			($dest->{'ssh_port'} ? " -p ".$dest->{'ssh_port'} : "").
			$dest->{'ssh_user'}."\@".$dest->{'host'}." echo OK");
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
local ($serverdoms, $dest) = @_;
local @rv;
local $info = &get_server_collected($dest);
foreach my $sd (@$serverdoms) {
	local ($server, $d) = @$sd;
	local $sinfo = &get_server_collected($server);
	foreach my $f (@{$sinfo->{'features'}}) {
		local ($dgot) = grep { $_->{'feature'} eq $f->{'feature'} }
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
local ($serverdoms, $dest, $delete, $direct, $realloc) = @_;
local (@refresh, %refreshed);
$direct = 0 if ($dest->{'id'} == 0);	# Transferring to master

# Sort list so that parents come first
local @sorted = sort { $a->[1]->{'parent'} <=> $b->[1]->{'parent'} ||
		       $a->[1]->{'alias'} <=> $b->[1]->{'alias'} } @$serverdoms;

local (%failed, %donebackup, %sourcetemp);
foreach my $sd (@sorted) {
	local ($server, $d) = @$sd;

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
	local $tmpdir = $sourcetemp{$server->{'id'}};
	if (!$tmpdir) {
		local $temp = &remote_foreign_call($server, "webmin",
					"tempname", "$d->{'dom'}.tar.gz");
		$tmpdir = $temp;
		$tmpdir =~ s/\/([^\/]+)$//;
		}

	# Find a temp file on the target, if needed
	local $desttemp;
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

	local @args = ( [ "domain", $d->{'dom'} ],
			[ "all-features" ],
			[ "option", "mail mailfiles 1" ],
			[ "newformat" ],
		      );
	if ($direct) {
		# Backup to dest via SSH directly
		local $pa = $dest->{'ssh_port'} ? ":".$dest->{'ssh_port'} : "";
		push(@args, [ "dest", "ssh://$dest->{'ssh_user'}:$dest->{'ssh_pass'}$pa\@$dest->{'host'}$desttemp" ]);
		}
	else {
		# Backup to a temp file on the target
		push(@args, [ "dest", $tmpdir ]);
		}
	local ($err, $out) = &call_virtualmin_api(
		$server, "backup-domain", \@args);
	if ($err) {
		&$second_print(&text('move_ebackup', $err));
		$failed{$d->{'id'}} = $sd;
		next;
		}

	# Work out the resulting filename and size
	local (@st, $filename, $statserver, $statdir);
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
		local $st = &remote_eval($statserver, "webmin",
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
	&$second_print(&text('move_backed', &nice_size($st[7])));

	# Transfer to master system, if not already there
	local ($localtemp, @st);
	if (!$direct) {
		if ($server->{'id'} != 0) {
			&$first_print(&text('move_download',
					    $d->{'dom'}, $filename));
			$localtemp = &transname($filename);
			local $err = &get_file_from_server($server,
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
			local $err = &put_file_to_server($dest, $localtemp,
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
foreach my $sd (@sorted) {
	local ($server, $d) = @$sd;

	# Skip if not done
	next if (!$donebackup{$d->{'id'}});

	# Skip if the parent has already been done, or has failed
	next if ($d->{'parent'} && $donebackup{$d->{'parent'}});
	next if ($d->{'parent'} && $failed{$d->{'parent'}});

	if ($delete == 2) {
		# Disable on source
		&$first_print(&text('move_disable', $d->{'dom'},
						    $server->{'host'}));
		local @args = ( [ "domain", $d->{'dom'} ] );
		local ($err, $out) = &call_virtualmin_api(
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
			}
		}
	elsif ($delete == 1) {
		# Delete on source
		&$first_print(&text('move_delete', $d->{'dom'},
						   $server->{'host'}));
		local @args = ( [ "domain", $d->{'dom'} ] );
		local ($err, $out) = &call_virtualmin_api(
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
	local ($server, $d) = @$sd;

	# Skip if failed
	next if ($failed{$d->{'id'}});

	# Restore on destination
	my $desttemp = $donebackup{$d->{'id'}};
	&$first_print(&text('move_restore', $d->{'dom'}, $dest->{'host'}));
	local @args = ( [ "source", $desttemp ],
			[ "all-features" ],
			[ "option", "dns fixip 1" ],
			[ "option", "web fixip 1" ],
			[ "option", "ssl fixip 1" ],
			[ "option", "mail mailfiles 1" ],
			[ "domain", $d->{'dom'} ] );
	if ($realloc && $d->{'virt'}) {
		push(@args, [ "allocate-ip" ]);
		}
	local ($err, $out) = &call_virtualmin_api($dest,
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
		&$block_print($out);
		&$second_print(&text('move_erestore', $err));
		if ($delete == 1) {
			&$second_print(&text('move_ewarning', $d->{'dom'},
					     $desttemp, $server->{'host'}));
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
local ($serverdoms) = @_;
local @rv;
foreach my $sd (@serverdoms) {
	local ($server, $d) = @$sd;
	local @doms = &get_server_domains($server);
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
local ($serverdoms) = @_;
local %done;
return grep { !$done{$_->[0]->{'id'},$_->[1]->{'id'}}++ } @$serverdoms;
}

# create_allocate_ip(&server)
# Bring up a new virtual interface on the given server, and return the address.
# Returns the interface object on success, or an error string on failure.
sub create_allocate_ip
{
local ($server) = @_;
local $pfunc = "type_".$server->{'manager'}."_list_parent_interfaces";
local $parents = &$pfunc($server);
ref($parents) || return "Failed to get parent network interfaces : $parents";
local ($piface) = grep { $_->{'name'} !~ /^lo/ &&
			 $_->{'virtual'} eq '' } @$parents;
local $iface = { 'name' => $piface->{'name'},
		 'netmask' => $piface->{'netmask'} };
local $ifunc = "type_".$server->{'manager'}."_create_interface";
local $err = &$ifunc($server, $iface);
return $err ? $err : $iface;
}

# get_domain_interface(&server, &domain)
# On systems that support interface management, find the private interface
# used for some domain.
sub get_domain_interface
{
local ($server, $d) = @_;
return undef if (!$d->{'virt'});	# Has no private IP
local $ifunc = "type_".$server->{'manager'}."_list_interfaces";
return undef if (!defined(&$ifunc));	# Server doesn't so interfaces
local $ifaces = &$ifunc($server);
return $ifaces if (!ref($ifaces));
local ($iface) = grep { $_->{'address'} eq $d->{'ip'} } @$ifaces;
return $iface;
}

# get_server_default_gateway(&server)
# Returns the default gateway IP address for some system. Uses Webmin if
# possible, netstat otherwise.
sub get_server_default_gateway
{
local ($server) = @_;
local $gw;
if ($server->{'manager'} eq 'this') {
        # Just call own module
        &foreign_require("net", "net-lib.pl");
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
local ($out, $ex, $err) = &execute_command_on_server($server, "netstat -rn");
foreach my $l (split(/\r?\n/, $out)) {
	local @w = split(/\s+/, $l);
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
local ($virtcount) = @_;
local (@glinks, @gtitles, @gicons, @gcats);

if ($virtcount) {
	# Virtualmin domains
	push(@glinks, "list_domains.cgi");
	push(@gtitles, $text{'domains_title'});
	push(@gicons, "images/domains.gif");
	push(@gcats, "virtualmin");
	}

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
    $server_management_types{'vserver'} ||
    $server_management_types{'zones'}) {
	push(@glinks, "list_images.cgi");
	push(@gtitles, $text{'images_title'});
	push(@gicons, "images/images.gif");
	push(@gcats, "settings");
	}

# Bandwidth monitoring
if ($server_management_types{'xen'} ||
    $server_management_types{'vserver'} ||
    $server_management_types{'zones'}) {
	push(@glinks, "edit_bw.cgi");
	push(@gtitles, $text{'bw_title'});
	push(@gicons, "images/bw.gif");
	push(@gcats, "settings");

	if ($config{'bw_enabled'}) {
		push(@glinks, "bwgraph.cgi");
		push(@gtitles, $text{'graph_title2'});
		push(@gicons, "images/graph.gif");
		push(@gcats, "settings");
		}
	}

# Historic graphs for all systems
push(@glinks, "history.cgi");
push(@gtitles, $text{'history_title'});
push(@gicons, "images/hist.gif");
push(@gcats, "settings");

# System owners
push(@glinks, "list_owners.cgi");
push(@gtitles, $text{'owners_title'});
push(@gicons, "images/owners.gif");
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
push(@gcats, "virtualmin");

# Plugins
push(@glinks, "list_plugins.cgi");
push(@gtitles, $text{'plugins_title'});
push(@gicons, "images/plugins.gif");
push(@gcats, "settings");

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
return (\@glinks, \@gtitles, \@gicons, \@gcats);
}

# get_available_create_links()
# Returns a list of link objects for creation actions available to the
# current user
sub get_available_create_links
{
local @rv;
foreach $t (@server_manager::server_management_types) {
	$lfunc = "server_manager::type_".$t."_create_links";
	if (defined(&$lfunc)) {
		foreach $l (&$lfunc()) {
			$l->{'type'} = $t;
			local $cfunc = $l->{'create'} ? \&can_create_server
						      : \&can_add_server;
			if (&$cfunc($t)) {
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
local ($server) = @_;
local $status = $server->{'status'};
local $t = $server->{'manager'};
local @rv;

# Work out what we can and cannot do
local $nfunc = "type_".$server->{'manager'}."_no_image";
local $noimage = defined(&$nfunc) && &$nfunc($server) ||
		 $status eq 'nohost';
local $mfunc = "type_".$server->{'manager'}."_can_move";
local $canmove = defined(&$mfunc) && &$mfunc($server);
local $sfunc = "type_".$t."_no_shutdown";
local $noshut = defined(&$sfunc) && &$sfunc($server);
local $rfunc = "type_".$t."_no_reboot";
local $noreboot = defined(&$rfunc) && &$rfunc($server);
local $tfunc = "type_".$t."_can_transfer";
local $cantransfer = defined(&$tfunc) && &$tfunc($server);
local $cfunc = "type_".$t."_get_console_output";
local $canconsole = defined(&$cfunc);
local $clfunc = "type_".$t."_supports_console_login";
local $canlogin = defined(&$clfunc) && &$clfunc($server);

# Start with links to edit_serv.cgi
local $ed = "edit_serv.cgi?id=$server->{'id'}";
if (&can_action($server, "edit")) {
	push(@rv, { 'id' => 'edit',
		    'desc' => $text{'edit_link_edit'},
		    'cat' => '',
		    'link' => $ed,
		    'priority' => 1 });
	if ($server->{'virtualmin_poss'}) {
		push(@rv, { 'id' => 'update',
			    'desc' => &text('edit_link_update',
					    $server->{'virtualmin_poss'}),
			    'cat' => '',
			    'link' => "edit_update.cgi?id=$server->{'id'}" });
		}
	if ($status eq 'virt') {
		push(@rv, { 'id' => 'doms',
			    'desc' => $text{'edit_link_doms'},
			    'cat' => 'system',
			    'link' => "edit_domains.cgi?id=$server->{'id'}" });
		}
	local $ifunc = "type_".$t."_list_interfaces";
	local $cfunc = "type_".$t."_can_interfaces";
	if (defined(&$ifunc) && &$cfunc($server) &&
	    $status ne 'paused' && $status ne 'alive' && $status ne 'nohost') {
		push(@rv, { 'id' => 'ifaces',
			    'desc' => $text{'edit_link_ifaces'},
			    'cat' => 'system',
			    'link' => "list_ifaces.cgi?id=$server->{'id'}" });
		}
	if (&can_edit_limits($server)) {
		push(@rv, { 'id' => 'limits',
			    'desc' => $text{'edit_link_limits'},
			    'cat' => 'system',
			    'link' => "edit_limits.cgi?id=$server->{'id'}" });
		}
	}
elsif (&can_action($server, "view")) {
	# Or link to view details
	push(@rv, { 'id' => 'view',
		    'desc' => $text{'edit_link_view'},
		    'cat' => '',
		    'link' => "edit_serv.cgi?id=$server->{'id'}",
		    'priority' => 1 });
	}

if ($status eq 'down' || $status eq 'nossh' || $status eq 'nohost' ||
    $status eq 'paused' || $status eq 'noping') {
	# Actions are limited when system is down
	local $sfunc = "type_".$t."_no_startup";
	local $nostart = defined(&$sfunc) && &$sfunc($server) ||
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
	local $wurl = &webmin_link($server);
	if (&can_action($server, "refresh")) {
		push(@rv, { 'id' => 'refresh',
			    'desc' => $text{'edit_refresh'},
			    'cat' => '' });
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
			local $prot = $server->{'ssl'} ? 'https' : 'http';
			local $durl = "$prot://$server->{'host'}:$server->{'port'}/";
			push(@rv, { 'id' => 'webmin',
				    'desc' => $text{'edit_webmin3'},
				    'cat' => '',
				    'target' => '_new',
				    'link' => $durl });
			}
		}
	push(@rv, undef);	# Spacer
	if (&can_action($server, "pass")) {
		push(@rv, { 'id' => 'pass',
			    'desc' => $text{'edit_setpass'},
			    'cat' => 'manage',
			    'link' => "edit_pass.cgi?id=$server->{'id'}" });
		}
	if (($status eq 'novirt' || $status eq 'nowebmin') &&
	    $server->{'manager'} ne 'this' &&
	    &can_action($server, "installvirt")) {
		push(@rv, { 'id' => 'installvirt',
			    'desc' => $text{'edit_installvirt'},
			    'cat' => 'manage' });
		}
	if ($status eq 'nowebmin' &&
	    &can_action($server, "installwebmin")) {
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
	}
if ($status ne 'nohost' && $status ne 'paused') {
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

# Pause/un-pause link
local $pfunc = "type_".$t."_can_pause";
if (defined(&$pfunc) && &can_action($server, "pause")) {
	local $p = &$pfunc($server);
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

# Package management link
if (&get_server_cluster_software($server) > 0) {
	push(@rv, { 'id' => 'packages',
		    'desc' => $text{'edit_packages'},
		    'cat' => 'manage',
		    'link' => "/cluster-software/edit_host.cgi?id=$server->{'id'}" });
	}

# Complex pages associated with system
local $dfunc = "type_".$t."_can_disks";
if (defined(&$dfunc) && &$dfunc($server) && $status ne 'paused' &&
    &can_action($server, "disks")) {
	push(@rv, { 'id' => 'disks',
		    'desc' => $text{'edit_disks'},
		    'cat' => 'res',
		    'link' => "list_disks.cgi?id=$server->{'id'}" });
	}

# Virtual CPUs
local $vfunc = "type_".$t."_can_vcpus";
if (defined(&$vfunc) && &$vfunc($server) &&
    &can_action($server, "vcpus")) {
	push(@rv, { 'id' => 'vcpus',
		    'desc' => $text{'edit_vcpus'},
		    'cat' => 'res',
		    'link' => "list_vcpus.cgi?id=$server->{'id'}" });
	}

# Bandwidth graph
local $rfunc = "type_".$t."_real_interfaces";
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
local @par = &is_parent_server($server);
foreach my $p (@par) {
	if (-r "$module_root_directory/list_${p}s.cgi" &&
	    &can_action(undef, "global")) {
		# Edit Xen/whatever host details
		push(@rv, { 'id' => 'host',
			    'desc' => $text{$p.'_edit'},
			    'cat' => 'manage',
			    'link' => "edit_${p}.cgi?id=$server->{'id'}" });
		}
	local $ffunc = "type_".$p."_find_servers";
	if (defined(&$ffunc) && &can_action(undef, "global")) {
		# Find hosted systems
		push(@rv, { 'id' => 'find',
			    'desc' => $text{'find_title_'.$p},
			    'cat' => 'manage',
			    'link' => "find_form.cgi?id=$server->{'id'}&type=$p" });
		}
	}

# Add type-specific actions
local $afunc = "type_".$t."_server_actions";
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
# request to www.virtualmin.com, with some local caching. Returns 1 if yes
# (and the number of domains and servers in an array context), 0 if no,
# -1 if could not tell
sub check_virtualmin_serial
{
local ($serial, $key) = @_;
local $id = &get_host_id();

# First check out positive responses cache
local %serialcache;
&read_file($serial_cache_file, \%serialcache);
local $skh = join(" ", $serial, $key, $id);
if (defined($serialcache{$shk})) {
	($lastcheck, $domains, $servers) = split(/\s+/, $serialcache{$shk});
	if ($lastcheck > time()-60*60) {
		return (1, $domains, $servers);
		}
	}

# Need to really query Virtualmin
local ($out, $error);
&http_download($virtualmin_licence_host,
	       $virtualmin_licence_port,
	       "$virtualmin_licence_prog?id=$id&serial=$key",
	       \$out, \$error, undef, $virtualmin_licence_ssl);
local @rv;
if ($out =~ /^OK\s+(\S+)\s+(\S+)\s+(\S+)/) {
	@rv = ( 1, $2, $3 );
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
# Returns the serial number and key for this VM2 install
sub get_server_manager_serial
{
local %serial;
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
local ($vm2) = @_;
local @lics = &list_virtualmin_licences();
local ($first) = grep { $_->{'vm2'} == $vm2 &&
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
local ($name, $nonone, $gpl) = @_;
local @opts;
local ($cansame, $canalloc);
if (!$nonone) {
	push(@opts, [ 0, $text{'virtualmin_smode0'}."<br>" ]);
	}
push(@opts, [ 1, &text('virtualmin_smode1',
		       &ui_textbox($name."_serial", undef, 20),
		       &ui_textbox($name."_key", undef, 20))."<br>" ]);
local ($vaserial, $vakey) = &allocate_virtualmin_serial(1);
if ($vaserial) {
	$cansame = 1;
	push(@opts, [ 2, $text{'virtualmin_smode2'}."<br>" ]);
	}
local ($aserial, $akey) = &allocate_virtualmin_serial(0);
if ($aserial) {
	push(@opts, [ 3, $text{'virtualmin_smode3'}."<br>" ]);
	$canalloc = 1;
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
local ($name, $in) = @_;
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
	local $lok = &check_virtualmin_serial($in{$name."_serial"},
					      $in{$name."_key"});
	$lok > 0 || return (undef, $text{'virtualmin_evalid'});
	return ($in{$name."_serial"}, $in{$name."_key"});
	}
elsif ($in->{$name} == 2) {
	# Same as VM2
	return &get_server_manager_serial();
	}
elsif ($in->{$name} == 3) {
	# Allocate from pool
	local ($aserial, $akey) = &allocate_virtualmin_serial(0);
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

# If the VM2 licence can also be used for Virtualmin, start with it
&lock_file($virtualmin_licences_file);
local @rv;
local ($vm2serial, $vm2key) = &get_server_manager_serial();
local %vm2cache;
&read_file($licence_cache_file, \%vm2cache);
if ($vm2cache{'max_last'} &&
    time() - $vm2cache{'max_last'} < 24*60*60) {
	# Use cached version
	push(@rv, \%vm2cache);
	}
else {
	# Check VM2 licence for real
	local ($lok, $ldoms, $lservers) =
		&check_virtualmin_serial($vm2serial, $vm2key);
	if ($lok > 0) {
		%vm2cache = ( 'serial' => $vm2serial,
			      'key' => $vm2key,
			      'domains' => $ldoms,
			      'servers' => $lservers,
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
	local %lic = map { split(/=/, $_) } split(/\s+/, $_);
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
		local ($lok, $ldoms, $lservers) =
			&check_virtualmin_serial($l->{'serial'}, $l->{'key'});
		if ($lok == 0) {
			# Invalid!
			$l->{'invalid'} = 1;
			}
		elsif ($lok > 0) {
			delete($l->{'invalid'});
			$l->{'domains'} = $ldoms;
			$l->{'servers'} = $lservers;
			}
		$l->{'max_last'} = time();
		$changed = 1;
		}
	$l->{'users'} = [ ];
	}

# For each licence, find out which systems it is used on
local @servers = &list_managed_servers();
local %lmap = map { $_->{'serial'}, $_ } @rv;
foreach my $s (@servers) {
	if ($s->{'virtualmin_serial'}) {
		local $l = $lmap{$s->{'virtualmin_serial'}};
		if ($l) {
			push(@{$l->{'users'}}, $s);
			}
		}
	}

# For each licence, find in-progress installs and decrease the free count
&lock_file($virtualmin_progress_file);
local %progress;
&read_file($virtualmin_progress_file, \%progress);
foreach my $l (@rv) {
	$l->{'progress'} = 0;
	local @newprog;
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

# save_virtualmin_licences(&licences)
# Updates the Virtualmin licence pool
sub save_virtualmin_licences
{
local ($licences) = @_;
&open_tempfile(LIC, ">$virtualmin_licences_file");
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
local ($serial, $key) = @_;
local %progress;
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
local ($serial, $key) = @_;
local %progress;
&lock_file($virtualmin_progress_file);
&read_file($virtualmin_progress_file, \%progress);
$progress{$serial} = join(' ', grep { $_ != $$ }
				    split(/\s+/, $progress{$serial}));
&write_file($virtualmin_progress_file, \%progress);
&unlock_file($virtualmin_progress_file);
}

# fetch_virtualmin_licences()
# Checks for new Virtualmin licences associated with the VM2 licence, and
# adds them. Returns an error message on failure, or a list of added licenses
# on success.
sub fetch_virtualmin_licences
{
local $id = &get_host_id();
local ($serial, $key) = &get_server_manager_serial();
local ($out, $error);
&http_download($virtualmin_licence_host,
	       $virtualmin_licence_port,
	       "$virtualmin_alllicences_prog?id=$id&serial=$key",
	       \$out, \$error, undef, $virtualmin_licence_ssl);
if ($out =~ /^BAD\s+(.*)/) {
	return $1;
	}
elsif ($out =~ /^OK\s+(\d+)/) {
	local @lics = &list_virtualmin_licences();
	local %got = map { $_->{'serial'}, $_ } @lics;
	local @lines = split(/\r?\n/, $out);
	shift(@lines);
	local @rv;
	foreach my $l (@lines) {
		local ($vserial, $vkey, $vend, $vdoms, $vservers) =
			split(/\s+/, $l);
		local $got = $got{$vserial};
		if ($got) {
			# Update existing details, to be one the safe side
			$got->{'domains'} = $vdoms;
			$got->{'servers'} = $vservers;
			}
		else {
			# Add to list
			local $lic = { 'serial' => $vserial,
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
# Returns 1 if current VM2 license can be used to fetch associated Virtualmin
# licenses. Not true for EC2 shared keys.
sub can_all_licenses
{
local ($serial, $key) = &get_server_manager_serial();
return $key !~ /^AMAZON/i;
}

# remove_server_ssh_keys(&server)
# Delete from root's ~/.ssh/authorized_keys* files any entries for a new system
sub remove_server_ssh_keys
{
local ($server) = @_;
local $ip = &to_ipaddress($server->{'host'});
local @uinfo = getpwnam("root");
&make_dir("$uinfo[7]/.ssh", 0700);
foreach my $f ("$uinfo[7]/.ssh/known_hosts",
	       "$uinfo[7]/.ssh/known_hosts2") {
	local $lref = &read_file_lines($f);
	for(my $i=0; $i<@$lref; $i++) {
		local @w = split(/\s+/, $lref->[$i]);
		foreach my $hn (split(/,/, $w[0])) {
			if ($hn eq $server->{'host'} ||
			    $ip && $hn eq $ip) {
				# Found one to remove
				splice(@$lref, $i--, 1);
				last;
				}
			}
		}
	&flush_file_lines($f);
	}
}

# list_all_script_updates(&servers)
# Fetch all possible script upgrades from multiple systems. Returns a list of
# hashes, each containing the details of one upgrade in one domain on one system
sub list_all_script_updates
{
local ($servers) = @_;
local @rv;
local @canservers = grep { $_->{'status'} eq 'virt' &&
			   $_->{'virtualmin_serial'} } @$servers;
local $temp = &transname();
&parallel_server_function(\@canservers, \&fetch_all_script_updates, $temp);
foreach my $s (@canservers) {
	local $data = &read_file_contents($temp.".".$s->{'id'});
	next if (!$data);
	local $updates = &unserialise_variable($data);
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
local ($server, $tempbase) = @_;
$last_remote_error = undef;
&remote_foreign_require($server, "virtual-server", "virtual-server-lib.pl");
return undef if ($last_remote_error);
local $updates = &remote_eval($server, "virtual-server",
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
local ($server, $updates) = @_;
local @rv;
foreach my $u (@$updates) {
	# Build API call args
	local @args = ( [ 'domain', $u->{'dom'}->{'dom'} ],
			[ 'type', $u->{'script'}->{'name'} ],
			[ 'upgrade', $u->{'sinfo'}->{'id'} ],
			[ 'version', $u->{'ver'} ],
		      );
	local ($err, $out) = &call_virtualmin_api($server, "install-script",
						  \@args);
	push(@rv, [ $u, $err, $out ]);
	}
return @rv;
}

sub can_edit_limits
{
local ($server) = @_;
local $cfunc = "type_".$server->{'manager'}."_can_cpu";
local $mfunc = "type_".$server->{'manager'}."_can_memory";
local $vfunc = "type_".$server->{'manager'}."_can_vcpus";
local $rfunc = "type_".$server->{'manager'}."_real_interfaces";
return defined(&$cfunc) && &$cfunc($server) ||
       defined(&$mfunc) && &$mfunc($server) ||
       defined(&$vfunc) && &$vfunc($server) ||
       defined(&$rfunc) && $config{'bw_enabled'};
}

# run_system_script(&system, when, action)
# Run the pre/post creation/deletion script, if defined, and tell the user
sub run_system_script
{
local ($server, $when, $action) = @_;
local $cmd = $config{$when.'_'.$action.'_cmd'};
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
	local $parent = &get_parent_server($server);
	if ($parent) {
		foreach my $k (keys %$parent) {
			$ENV{'SERVERMANAGER_PARENT_'.uc($k)} = $parent->{$k};
			}
		}
	}

&$first_print($text{'run_'.$when.'_'.$action});
local $out = &backquote_logged("($cmd) 2>&1 </dev/null");
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
local ($server) = @_;
local $pfunc = "type_".$server->{'manager'}."_parent";
if (defined(&$pfunc)) {
	return &$pfunc($server);
	}
return undef;
}

# is_parent_server(&server)
# Returns a list of the system types this server hosts
sub is_parent_server
{
local ($server) = @_;
local @rv;
foreach my $t ('xen', 'vserver', 'zone') {
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
local ($server) = @_;
foreach my $t ('xen', 'vserver', 'zones') {
	return $t if ($server->{'manager'} eq $t);
	}
return undef;
}

# list_child_servers(&server, [&all-servers])
# Returns a list of other servers this one hosts. For each type it can host,
# check all other servers of that type to see if their parent is this one.
sub list_child_servers
{
local ($server, $allservers) = @_;
local @servers = $allservers ? @$allservers : &list_managed_servers();
local @rv;
foreach my $p (&is_parent_server($server)) {
	$p = "zones" if ($p eq "zone");
	local $pfunc = "type_".$p."_parent";
	if (defined(&$pfunc)) {
		foreach my $s (grep { $_->{'manager'} eq $p } @servers) {
			local $par = &$pfunc($s, \@servers);
			if ($par && $par->{'id'} eq $server->{'id'}) {
				push(@rv, $s);
				}
			}
		}
	}
return @rv;
}

# show_ip_range_input(starts, ends, cidrs)
# Returns HTML for entering 1 or more IP allocation ranges
sub show_ip_range_input
{
local ($starts, $ends, $cidrs) = @_;
local @starts = split(/\s+/, $starts);
local @ends = split(/\s+/, $ends);
local @cidrs = split(/\s+/, $cidrs);
local $table = &ui_columns_start([ $text{'range_start'},
				   $text{'range_end'},
				   $text{'range_cidr'} ]);
for(my $i=0; $i<=@starts; $i++) {
	$table .= &ui_columns_row([
		&ui_textbox("start_$i", $starts[$i], 20),
		&ui_textbox("end_$i", $ends[$i], 20),
		&ui_textbox("cidr_$i", $cidrs[$i], 20),
		]);
	}
$table .= &ui_columns_end();
return $table;
}

# parse_ip_range_input(&in)
# Parse the form generated by show_ip_range_input, and return lists of start,
# end and cidr addresses.
sub parse_ip_range_input
{
local ($in) = @_;
local (@starts, @ends, @cidrs);
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
	}
@starts || &error($text{'range_enone'});
return (join(" ", @starts), join(" ", @ends), join(" ", @cidrs));
}

# show_disk_reboot_message(&server, &disk)
# Prints a form prompting for a reboot if needed after some disk change
sub show_disk_reboot_message
{
local ($server, $disk) = @_;
local $rfunc = "type_".$server->{'manager'}."_need_disk_reboot";
if ($server->{'status'} ne 'down' &&
    defined(&$rfunc) && &$rfunc($server, $disk)) {
	print &ui_form_start("save_serv.cgi");
	print &ui_hidden("id", $in{'id'});
	print &ui_hidden("reboot", 1);
	print &ui_hidden("confirm", 1);
	print "<b>$text{'disk_needreboot'}</b><p>\n";
	print &ui_form_end([ [ undef, $text{'limits_reboot'} ] ]);
	}
}

# find_server_manager_cron_job(command, [&jobs], [user])
# Returns the cron job object that runs some command (perhaps with redirection)
sub find_server_manager_cron_job
{
local ($cmd, $jobs, $user) = @_;
if (!$jobs) {
	&foreign_require("cron", "cron-lib.pl");
	$jobs = [ &cron::list_cron_jobs() ];
	}
$user ||= "root";
local @rv = grep { $_->{'user'} eq $user &&
	     $_->{'command'} =~ /(^|[ \|\&;])\Q$cmd\E($|[ \|\&><;])/ } @$jobs;
return wantarray ? @rv : $rv[0];
}

# get_global_from_address(&server)
# Returns the from address to use when sending email to some server.
sub get_global_from_address
{
local ($server) = @_;
&foreign_require("mailboxes", "mailboxes-lib.pl");
local $rv = $config{'from_addr'} || &mailboxes::get_from_address();
return $rv;
}

# host_free_desc(&vhost)
# Returns a string listing free disk space and RAM for some host
sub host_free_desc
{
local ($vhost) = @_;
local $vinfo = &get_server_collected($vhost);
local @rv;
if ($vinfo && $vinfo->{'disk_free'}) {
	push(@rv, &text('create_hostdisk', &nice_size($vinfo->{'disk_free'})));
	}
if ($vinfo && $vinfo->{'mem'}) {
	push(@rv, &text('create_hostmem',
			&nice_size($vinfo->{'mem'}->[1]*1024)));
	}
return @rv ? " (".join(", ", @rv).")" : "";
}

# get_provider_link()
# Returns HTML for the logo that should be displayed in the theme for the
# Virtualmin hosting provider. In an array context, also returns the image
# URL and link URL, if set.
sub get_provider_link
{
# Does this owner have a logo
local ($logo, $link);
($logo, $link) = ($access{'theme_image'}, $access{'theme_link'});
if (!$logo) {
        # Call back to global config
        $logo = $config{'theme_image'} || $gconfig{'vm2_theme_image'};
        $link = $config{'theme_link'} || $gconfig{'vm2_theme_link'};
        }
if ($logo && $logo ne "none") {
        local $html;
        $html .= "<a href='$link' target=_new>" if ($link);
        $html .= "<img src='$image' border=0>";
        $html .= "</a>" if ($link);
        return wantarray ? ( $html, $logo, $link ) : $html;
        }
else {
        return wantarray ? ( ) : undef;
        }
}

# move_system(&system, &dest)
# Moves a virtual system to a host hosting server, which is assumed to be
# able to support it. Calls the appropriate type-specific move function to
# do most of the work. Returns undef on success or an error message on failure.
# May print stuff.
sub move_system
{
local ($server, $dest) = @_;
local @pars = &is_parent_server($dest);
local $dfunc = "type_".$server->{'manager'}."_desc";
local $desc = &$dfunc($server);
&indexof($server->{'manager'}, @pars) >= 0 ||
	return "Destination system $dest->{'host'} cannot host $desc systems";
local $vhost = &get_parent_server($server);
$vhost->{'id'} ne $dest->{'id'} ||
	return "Source and destination host systems are the same!";

# Check if moving is supported, then do it
local $cfunc = "type_".$server->{'manager'}."_can_move";
if (!defined(&$cfunc) || !&$cfunc($server, $dest)) {
	return "The $desc system $server->{'host'} cannot be moved to $dest->{'host'}";
	}
local $mfunc = "type_".$server->{'manager'}."_move_system";
local $err = &$mfunc($server, $dest);

# Refresh status
if (!$err) {
	&$first_print($text{'save_refreshing'});
	}
&check_server_status($server, 0, 1);
&save_managed_server($server);
if (!$err) {
	&$second_print(&text('save_refreshdone2',
		&describe_status($server, 1, 1)));
	}

return $err;
}

# get_server_cluster_software(&server)
# Returns 1 if some server is having software packages managed by the VM2
# master, 0 if not, -1 if not possible
sub get_server_cluster_software
{
local ($server) = @_;
if ($server->{'manager'} ne 'this' &&
    ($server->{'status'} eq 'virt' || $server->{'status'} eq 'novirt') &&
    (!$remote_user || &foreign_available("cluster-software"))) {
	# Can use in theory
	return -d "$config_directory/cluster-software/hosts/$server->{'id'}" ?
		1 : 0;
	}
return -1;
}

# save_server_cluster_software(&server, enabled?)
# Either turns on or off cluster software management. When enabling for the
# first time, packages are fetched from the host.
# Returns undef on success or an error message on failure.
sub save_server_cluster_software
{
local ($server, $enabled) = @_;
if (!&foreign_check("cluster-software")) {
	return "The Cluster Software Packages module is not installed";
	}
if ($remote_user && !&foreign_available("cluster-software")) {
	return "The Cluster Software Packages module is not available to you";
	}
if ($enabled &&
    $server->{'status'} ne 'virt' && $server->{'status'} ne 'novirt') {
	return "Webmin is not installed on the remote system";
	}
local $hdir = "$config_directory/cluster-software/hosts/$server->{'id'}";
if ($enabled && !-d $hdir) {
	# Enable and fetch packages
	&foreign_require("cluster-software", "cluster-software-lib.pl");
	local ($ok, $msg) = &cluster_software::add_managed_host($server);
	return $msg if (!$ok);
	}
elsif (!$enabled && -d $hdir) {
	&foreign_require("cluster-software", "cluster-software-lib.pl");
	&cluster_software::delete_software_host($server);
	}
return undef;
}

# refresh_server_cluster_software(&server)
# Re-fetch software packages from some server. Returns undef on success or an
# error message on failure.
sub refresh_server_cluster_software
{
local ($server) = @_;
if (!&foreign_check("cluster-software")) {
	return "The Cluster Software Packages module is not installed";
	}
if ($server->{'status'} ne 'virt' && $server->{'status'} ne 'novirt') {
	return "Webmin is not installed on the remote system";
	}
&foreign_require("cluster-software", "cluster-software-lib.pl");
local ($h) = grep { $_->{'id'} eq $server->{'id'} }
		  &cluster_software::list_software_hosts();
local ($rv) = &cluster_software::refresh_packages([ $h ]);
return ref($rv) ? undef : $rv;
}

# substitute_virtualmin_template(string, &hash)
# Just exists to be called from newfeatures-lib.pl
sub substitute_virtualmin_template
{
local ($str, $hash) = @_;
return &substitute_template($str, $hash);
}

# show_search_form(&in, &candiate-servers)
# Return a grid of inputs for searching for systems, with fields filled in
sub show_search_form
{
local ($in, $servers) = @_;
local @grid = ( );

sub highlight_field
{
local ($msg, $but) = @_;
$msg = "<b>$msg</b>";
$msg = "<i>$msg</i>" if ($in->{$but});
return $msg;
}

# Search by hostname or desc
push(@grid, &highlight_field($text{'index_search'}, "ok"));
push(@grid, &ui_textbox("search", $in->{'search'}, 30).
	    " ".&ui_submit($text{'index_searchok'}, "ok"));

# Search by group
local @groups = &unique(map { split(/\t/, $_->{'group'}) } @$servers);
if (@groups) {
	push(@grid, &highlight_field($text{'index_gsearch'}, "gok"));
	push(@grid, &ui_select("gsearch", $in->{'gsearch'}, \@groups).
		    " ".&ui_submit($text{'index_searchgok'}, "gok"));
	}

# Search by host system
local @parents = grep { &is_parent_server($_) } @$servers;
if (@parents) {
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
if ($in->{'eok'}) {
	push(@grid, &highlight_field($text{'index_esearch'}, "eok"));
	push(@grid, &ui_select("esearch", $in->{'esearch'},
	    [ map { [ $_->{'id'}, $_->{'account'} ] }
		  &list_ec2_accounts() ]).
		    " ".&ui_submit($text{'index_searcheok'}, "eok"));
	}

return &ui_grid_table(\@grid, 4, 100,
	[ "width=10%", "width=40%", "width=10%", "width=40%" ]);
}

# apply_search_form(&in, &servers)
# Given a list of servers and a search criteria from show_search_form, return
# only those servers which match
sub apply_search_form
{ 
local ($in, $servers) = @_;
if ($in->{'gok'}) {
	# Search by group
	return grep { my @g = split(/\t/, $_->{'group'});
			&indexof($in->{'gsearch'}, @g) >= 0 } @$servers;
	}
elsif ($in->{'pok'}) {
	# Search by parent
	local ($parent) = grep { $_->{'id'} eq $in->{'psearch'} } @$servers;
	return grep { my $p = &get_parent_server($_);
		  $p && $p->{'id'} eq $parent->{'id'} } @$servers;
	}
elsif ($in->{'eok'}) {
	# Search by EC2 account
	local ($ec2) = grep { $_->{'id'} == $in->{'esearch'} }
		      &list_ec2_accounts();
	return grep { $_->{'ec2'} == $in->{'esearch'} } @$servers;
	}
elsif ($in->{'sok'}) {
	# Search by status
	local @sts;
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
		return grep { $_->{'virtualmin_poss'} } @$servers;
		}
	else {
		# By regular status
		return grep { &indexof($_->{'status'}, @sts) >= 0 }
				@$servers;
		}
	}
else {
	# By hostname
	local $s = $in->{'search'};
	return grep { $_->{'host'} =~ /\Q$s\E/i ||
		      $_->{'desc'} =~ /\Q$s\E/i } @$servers;
	}
}

# show_webmin_login_form([&server], [type])
# Outputs fields for selecting the Webmin login and password for a system
sub show_webmin_login_form
{
local ($server, $type) = @_;
$type ||= $server->{'manager'} if ($server);
local $sfunc = "type_".$type."_no_ssh";
local $no_ssh = defined(&$sfunc) && &$sfunc();
local $newserver = !$server || !$server->{'id'};

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
local ($in, $server) = @_;

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
local ($src, $dst) = @_;
foreach my $f ('user', 'pass', 'ssh_pass_same', 'ssl', 'port') {
	$dst->{$f} = $src->{$f};
	}
}

# show_ssh_login_form([&server], [type])
# Outputs fields for selecting the SSH login and password or key for a system.
# May not output anything if the system type doesn't support or need SSH.
sub show_ssh_login_form
{
local ($server, $type) = @_;
$type ||= $server->{'manager'} if ($server);

local $sfunc = "type_".$type."_no_ssh";
local $no_ssh = defined(&$sfunc) && &$sfunc();
return if ($no_ssh);

# Root password / key
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
local ($in, $server) = @_;
return undef if (!defined($in->{'auth_mode'}));		# No SSH mode

$in->{'uuser'} =~ /^[a-z0-9\.\-\_]+$/i || return $text{'add_euuser'};
$server->{'ssh_user'} = $in->{'uuser'};
if (!$in->{'uport_def'}) {
	$in->{'uport'} =~ /^\d+$/ && $in->{'uport'} > 0 &&
	    $in->{'uport'} < 65536 || return $text{'add_euport'};
	$server->{'ssh_port'} = $in->{'uport'};
	}
if ($in->{'auth_mode'} == 0) {
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
local ($src, $dst) = @_;
foreach my $f ('ssh_user', 'ssh_port', 'ssh_pass', 'ssh_nologin',
	       'ssh_protocol') {
	$dst->{$f} = $src->{$f};
	}
}

# plugin_call(module, function, [arg, ...])
# If some plugin function is defined, call it and return the result,
# otherwise return undef
sub plugin_call
{
local ($mod, $func, @args) = @_;
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
local $pkg = $_[0];
$pkg =~ s/[^A-Za-z0-9]/_/g;
local $func = "${pkg}::$_[1]";
return defined(&$func);
}

# strip_html_tags(html)
# Removes all HTML tags from a string, returning plain text
sub strip_html_tags
{
local ($html) = @_;
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

sub html_tags_to_text
{
local ($rv) = @_;
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

# These functions store and retrieve the current print commands
sub push_all_print
{
push(@print_function_stack, [ $first_print, $second_print,
			      $indent_print, $outdent_print, $block_print ]);
&set_all_null_print();
}
sub pop_all_print
{
local $p = pop(@print_function_stack);
($first_print, $second_print, $indent_print, $outdent_print, $block_print) =@$p;
}

# Temporary function until Webmin 1.430 is out
sub vm2_js_redirect
{
local ($url) = @_;
if (defined(&js_redirect)) {
	return &js_redirect(@_);
	}
elsif (defined(&theme_js_redirect)) {
	return &theme_js_redirect(@_);
	}
else {
	return "<script>window.location = '".&quote_escape($url)."';</script>\n";
	}
}

1;

