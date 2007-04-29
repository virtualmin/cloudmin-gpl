# Functions for general setup and management of multiple Virtualmin servers
# XXX search if too many servers
# XXX grouping
# XXX for vserver/zones, we don't need to SSH in
# XXX kvm or vservers
# XXX tar.gz installs
# XXX deleting real systems

do '../web-lib.pl';
&init_config();
do '../ui-lib.pl';
&foreign_require("servers", "servers-lib.pl");
&foreign_require("proc", "proc-lib.pl");
&remote_error_setup(\&remote_error_handler);
use Net::Amazon::EC2;

@possible_server_management_types = ( [ "real", undef ],
				      [ "zones", "zones" ],
				      [ "ec2", undef ],
				      [ "vserver", undef ],
				      [ "this", undef ],
				    );
@server_management_types = ( );
foreach my $smt (@possible_server_management_types) {
	if (!$smt->[1] || &foreign_installed($smt->[1])) {
		push(@server_management_types, $smt->[0]);
		do "$smt->[0]-type-lib.pl";
		}
	}

$ssh_keys_dir = "$module_config_directory/keys";
$check_status_cmd = "$module_config_directory/status.pl";
$server_domains_dir = "$module_config_directory/domains";
$server_collected_dir = "$module_config_directory/coll";
$this_server_status = "$module_config_directory/this";

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
	'deb' => 'http://www.webmin.com/download/deb/webmin-current.deb',
	'tgz' => 'http://www.webmin.com/download/webmin-current.tar.gz',
	);

# list_managed_servers()
# Returns a list of all servers managed by this module. These are actually
# just a subset of those from the Webmin Servers Index module
sub list_managed_servers
{
local @rv = grep { $_->{'module'} eq $module_name } &servers::list_servers();
@rv = sort { $a->{'host'} cmp $b->{'host'} } @rv;
if ($config{'show_this'}) {
	local $this = &servers::this_server();
	$this->{'manager'} = 'this';
	$this->{'host'} = &get_system_hostname();
	$this->{'desc'} = $text{'this_this'};
	&read_file($this_server_status, $this);
	splice(@rv, 0, 0, $this);
	}
return @rv;
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
			'status_msg' => $server->{'status_msg'} );
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

# delete_managed_server(&server)
# Remove a managed server object
sub delete_managed_server
{
local ($server) = @_;
if ($server->{'id'}) {
	&servers::delete_server($server->{'id'});
	}
unlink("$server_domains_dir/$server->{'id'}");
unlink("$server_collected_dir/$server->{'id'}");
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
local $cmap = { 'down' => 'ff0000',
		'nossh' => 'ff00ff',
		'nosshlogin' => 'ff00cc',
		'nowebmin' => 'ffff00',
		'downwebmin' => 'ffaa00',
		'nowebminlogin' => 'ffcc00',
		'novirt' => 'aaff00',
		'virt' => '00aa00' };
local $msg = $text{'status_'.$s->{'status'}} || $text{'status_unknown'};
if ($s->{'status'} eq 'virt' && $withdoms) {
	local @doms = &get_server_domains($s);
	if (@doms) {
		$msg .= " (".&text('status_doms', scalar(@doms)).")";
		}
	}
if ($withcol) {
	local $col = $cmap{$s->{'status'}};
	if ($col) {
		return "<font color=#$col>$msg</font>";
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
local $out = `ssh-keygen -y -f $qp 2>/dev/null`;
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
# login, 3=Unknown error, 4=Timeout) and an error message, the Webmin root
# directory (if installed), the Webmin port and the Webmin SSL flag.
sub check_server_ssh_login
{
local ($server) = @_;
local $cmd = "ssh -".$server->{'ssh_protocol'};
if ($server->{'key'}) {
	local ($key) = grep { $_->{'id'} == $server->{'key'} } &list_ssh_keys();
	$cmd .= " -i ".quotemeta($key->{'file'});
	}
$cmd .= " $server->{'ssh_user'}\@$server->{'host'} 'grep ^root= /etc/webmin/miniserv.conf ; grep ^port= /etc/webmin/miniserv.conf ; grep ^ssl= /etc/webmin/miniserv.conf ; echo OK'";
local ($status, $out) = &run_ssh_command($cmd, $server->{'ssh_pass'}, 10);
if ($status == 0) {
	# Connected OK .. check the output to see if we have Webmin
	if ($out !~ /OK/) {
		return (3, $out, undef);
		}
	else {
		local $root = $out =~ /root=(\S+)/ ? $1 : 0;
		local $port = $out =~ /port=(\S+)/ ? $1 : 0;
		local $ssl = $out =~ /ssl=(\S+)/ ? $1 : 0;
		if ($root && $ssl) {
			# Webmin wants SSL .. but can we really provide it?
			local ($sout, $sex) = &execute_command_on_server(
				$server, "perl -e 'use Net::SSLeay'");
			if ($sex) {
				$ssl = 0;	# Missing Perl module
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
	alarm(10);
	$last_remote_error = undef;
	$rfc = &remote_foreign_config($server, "");
	alarm(0);
	};
if ($last_remote_error) {
	local $ec = $last_remote_error =~ /Login\s+to\s+RPC/ ? 2 : 1;
	return ($ec, $last_remote_error);
	}
if ($@) {
	if ($@ =~ /timeout/) {
		# A fast mode failure will look like a timeout .. try in slow
		# mode, if we don't know yet
		if ($fast_try) {
			$server->{'fast'} = 0;
			return &check_server_webmin_login($server);
			}
		return (4, "Webmin failed to complete in 10 seconds");
		}
	else {
		return (3, $@);
		}
	}
return (0, undef, $rfc->{'os_type'}, $rfc->{'real_os_type'});
}

# run_ssh_command(command, password, timeout)
# Attempts to run some ssh or scp command, giving it a password if needed.
# Returns 0 on success, 1 if the connection fails, 2 if the password is wrong,
# or 3 for some other error, 4 for timeout, and the output.
sub run_ssh_command
{
local ($cmd, $pass, $timeout) = @_;
local ($wrong_password, $got_login, $connect_failed);
local $out;
local $ex;
eval {
	local $SIG{'ALRM'} = sub { die "timeout\n" };
	local $main::error_must_die = 1;
	if ($timeout) {
		alarm($timeout);
		}
	local ($fh, $fpid) = &proc::pty_process_exec($cmd);
	while(1) {
		$rv = &wait_for($fh, "password:", "yes\\/no", "(^|\\n)\\s*Permission denied.*\n", "ssh: connect.*\n", ".*\n");
		$out .= $wait_for_input;
		if ($rv == 0) {
			syswrite($fh, "$pass\n");
			}
		elsif ($rv == 1) {
			syswrite($fh, "yes\n");
			}
		elsif ($rv == 2) {
			$wrong_password++;
			last;
			}
		elsif ($rv == 3) {
			$connect_failed++;
			}
		elsif ($rv < 0) {
			last;
			}
		}
	alarm(0);
	close($fh);
	waitpid($fpid, 0);
	$ex = $?;
	};
if ($@) {
	if ($@ =~ /timeout/) {
		return (4, "SSH failed to complete in $timeout seconds");
		}
	else {
		return (3, $@);
		}
	}
if ($wrong_password) {
	return (2, $out);
	}
if ($connect_failed) {
	return (1, $out);
	}
if ($ex) {
	return (3, $out);
	}
return (0, $out);
}

# execute_command_on_server(&server, command, [timeout])
# Runs some command on a managed system (most likely via SSH), and returns
# the output, exit status and error message if it could not be run
sub execute_command_on_server
{
local ($server, $cmd, $timeout) = @_;
local $efunc = "type_".$server->{'manager'}."_execute_command";
if (defined(&$efunc)) {
	# Use type-specific function call
	return &$efunc(@_);
	}
else {
	# Just run via SSH
	local $sshcmd = "ssh -".$server->{'ssh_protocol'};
	local ($key) = grep { $_->{'id'} == $server->{'key'} } &list_ssh_keys();
	$sshcmd .= " -i ".quotemeta($key->{'file'});
	$sshcmd .= " $server->{'ssh_user'}\@$server->{'host'} ".quotemeta($cmd);
	local ($status, $out) = &run_ssh_command($sshcmd, $server->{'ssh_pass'},
						 $timeout);
	if ($status == 0) {
		return ($out, 0, undef);
		}
	elsif ($status == 3) {
		return ($out, 1, undef);
		}
	else {
		return ($out, undef, $text{'status_'.$status});
		}
	}
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

# check_server_status(&server)
# Checks the status of a managed server, and updates the server object. Checks
# SSH login, Webmin login, Virtualmin status, number of domains, memory, disk
# and CPU load.
sub check_server_status
{
local ($server) = @_;

# Do a quick ping
local $pingcmd = $gconfig{'os_type'} =~ /-linux$/ ?
			"ping -c 1 -t 1" : "ping";
local ($out, $timed_out) = &backquote_with_timeout(
				$pingcmd." ".$server->{'host'}." 2>&1", 5, 1);
local $ping = !$timed_out && !$?;

# Check SSH status (if not local)
local $webminroot;
$server->{'statustime'} = time();
if ($server->{'id'} != 0) {
	local ($status, $err, $wr) = &check_server_ssh_login($server);
	if ($status == 2) {
		$server->{'status'} = 'nosshlogin';
		$server->{'status_msg'} = $err;
		return 0;
		}
	elsif ($status && !$ping) {
		$server->{'status'} = 'down';
		$server->{'status_msg'} = $err;
		return 0;
		}
	elsif ($status) {
		$server->{'status'} = 'nossh';
		$server->{'status_msg'} = $err;
		return 0;
		}
	$webminroot = $wr;
	}

# If we have a Webmin login, try it
if ($server->{'user'} || $server->{'id'} == 0) {
	($status, $err) = &check_server_webmin_login($server);
	if ($status == 2) {
		# Webmin replied, but it rejected our login
		$server->{'status'} = 'nowebminlogin';
		$server->{'status_msg'} = $err;
		return 0;
		}
	elsif ($status) {
		# Could not login to Webmin .. which may be because it is down,
		# un-contactable, or not installed
		$server->{'status'} = $webminroot ? 'downwebmin' : 'nowebmin';
		$server->{'status_msg'} = $err;
		return 0;
		}

	# Webmin is OK! Check for Virtualmin
	$server->{'status'} = 'virt';
	$server->{'status_msg'} = undef;
	local $info;
	if (&remote_foreign_check($server, "virtual-server")) {
		# Get and save remote Virtualmin domains
		&remote_foreign_require($server, "virtual-server",
					"virtual-server-lib.pl");
		local @doms = &remote_foreign_call($server, "virtual-server",
						   "list_domains");
		&save_server_domains($server, \@doms);

		# Get and save collected status info
		$info = &remote_foreign_call($server, "virtual-server",
					     "get_collected_info");
		$info->{'minfo'} = &remote_eval($server, "virtual_server",
						"\\\%module_info");
		$info->{'config'} = &remote_foreign_config($server,
							   "virtual-server");
		if (&remote_eval($server, "virtual_server",
				 "defined(\&list_available_features)")) {
			$info->{'features'} = [ &remote_foreign_call($server,
				"virtual-server", "list_available_features") ];
			}
		$info->{'template'} = &remote_foreign_call($server,
				"virtual-server", "get_template", 0);
		}
	else {
		$server->{'status'} = 'novirt';
		$server->{'status_msg'} = undef;
		$info = { };
		}

	# Get common Webmin information
	&remote_foreign_require($server, "webmin", "webmin-lib.pl");
	$info->{'general'}->{'version'} = 
		&remote_foreign_call($server, "webmin", "get_webmin_version");
	$info->{'general'}->{'installtype'} = 
		&remote_foreign_call($server, "webmin", "get_install_type");
	$info->{'general'}->{'theme'} =
		&remote_eval($server, "webmin", "\$current_theme");
	$info->{'general'}->{'tinfo'} =
		&remote_eval($server, "webmin",
			     "\%t=get_theme_info(\$current_theme); \\\%t");

	&save_server_collected($server, $info);
	}
else {
	$server->{'status'} = 'nowebmin';
	$server->{'status_msg'} = undef;
	}

return 1;
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
}

# get_server_domains(&server)
# Returns an array of domain objects from some server
sub get_server_domains
{
local ($server) = @_;
local $ddata = &read_file_contents("$server_domains_dir/$server->{'id'}");
return ( ) if (!$ddata);	# Not collected yet?
local $doms = &unserialise_variable($ddata);
return @$doms;
}

# save_server_collected(&server, &info)
# Writes out the status information collected from some server
sub save_server_collected
{
local ($server, $info) = @_;
if (!-d $server_collected_dir) {
	&make_dir($server_collected_dir, 0700);
	}
&open_tempfile(DOMS, ">$server_collected_dir/$server->{'id'}");
&print_tempfile(DOMS, &serialise_variable($info));
&close_tempfile(DOMS);
$get_server_collected_cache{$server->{'id'}} = $info;
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
# Calls some function on multiple servers, in 10 (by default) processes
sub parallel_server_function
{
local ($servers, $func, $args) = @_;

# Build 10 buckets
local @buckets;
local $procs = $config{'procs'};
for(my $i=0; $i<@servers; $i++) {
	push(@{$buckets[$i % $procs]}, $servers[$i]);
	}

# Fork 10 processes, each doing a bucket
local @pids;
for(my $i=0; $i<$procs; $i++) {
	local @bservers = @{$buckets[$i]};
	next if (!@bservers);
	if (!($pid = fork())) {
		foreach my $server (@bservers) {
			&$func($server, $args);
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
}

# parallel_check_server_status(&servers)
# Checks the status of multiple servers in 10 (by default) processes
sub parallel_check_server_status
{
local ($servers) = @_;
&parallel_server_function($servers,
	sub { &check_server_status($_[0]);
	      &save_managed_server($_[0]); });
}

# parallel_install_package_updates(&servers)
# Updates all packages on multiple servers, in 10 (by default) processes
sub parallel_install_package_updates
{
local ($servers) = @_;
&parallel_server_function($servers,
	sub { my $info = &get_server_collected($_[0]);
	      my @allgot;
	      foreach $p (@{$info->{'poss'}}) {
	          local $got = &install_package_update($_[0], $p);
		  push(@allgot, @$got) if (ref($got));
	          }
              &refresh_server_updates($_[0], \@allgot);
	      &check_server_status($_[0]);
	      &save_managed_server($_[0]);
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
return "<a href='$url' ".($target ? "target=$target" : "").">$d->{'dom'}</a>";
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
			$cmd .= quotemeta($a->[1]);
			}
		}
	&clean_environment();
	$out = &backquote_logged("$cmd 2>&1 </dev/null");
	&reset_environment();
	$ex = $?;
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
	local @lines = split(/\r?\n/, $out);
	return ( $lines[0] || "Unknown error", $out );
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
		"capture_function_output", "package_install", $p->{'name'});
if ($last_remote_error) {
	return $last_remote_error;
	}
else {
	return $rv;
	}
}

# show_confirm_form(message, cgi, &hiddens, ok-message)
# Prints a form for confirming some action
sub show_confirm_form
{
local ($msg, $cgi, $hiddens, $ok) = @_;
print "<center>\n";
print &ui_form_start($cgi, "post");
foreach my $h (@$hiddens) {
	print &ui_hidden($h->[0], $h->[1]);
	}
print $msg,"<p>\n";
print &ui_form_end([ [ "confirm", $ok ] ]);
print "</center>\n";
}

# shutdown_server(&server)
# Remotely shut down some system. Returns undef on success, or an error
# message on failure.
sub shutdown_server
{
local ($server) = @_;
if ($server->{'status'} eq 'virt' || $server->{'status'} eq 'novirt') {
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
if ($server->{'status'} eq 'virt' || $server->{'status'} eq 'novirt') {
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

# Check for rpm and dpkg
local ($rpmout, $rpmex, $rpmerr) =
	&execute_command_on_server($server, "which rpm");
return ( undef, undef, $rpmerr ) if ($rpmerr);
if (!$rpmex) {
	if ($rpmout =~ /rpm/) {
		$type = "rpm";
		}
	else {
		return ( undef, undef, $rpmout );
		}
	}
else {
	local ($debout, $debex, $deberr) =
		&execute_command_on_server($server, "which dpkg");
	if (!$debex) {
		if ($debout =~ /rpm/) {
			$type = "deb";
			}
		else {
			return ( undef, undef, $debout );
			}
		}
	else {
		$type = "tgz";
		}
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

if ($type eq "rpm") {
	# RPM install direct from the URL
	($out, $ex, $err) = &execute_command_on_server($server,
		"rm -f $temp && wget -nv -O $temp $src && rpm -U $temp && rm -f $temp");
	return (undef, $err) if ($err);
	return ($out, "RPM failed") if ($ex);
	$rootdir = "/usr/libexec/webmin";
	}

elsif ($type eq "deb") {
	# Download the deb and install it
	($out, $ex, $err) = &execute_command_on_server($server,
		"rm -f $temp && wget -nv -O $temp $src && dpkg --install $temp && rm -f $temp");
	return (undef, $err) if ($err);
	return ($out, "Debian package failed") if ($ex);
	$rootdir = "/usr/share/webmin";
	}

elsif ($type eq "tgz") {
	# Download the tgz file, then run setup.sh
	# XXX create 'root' user
	$server->{'user'} = 'root';
	$server->{'pass'} = &generate_random_password();
	$rootdir = "/usr/local/webmin";
	# XXX setup in rootdir
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
	if ($server->{'ssh_pass'}) {
		# Root and Webmin passwords are the same
		$server->{'user'} = 'root';
		$server->{'pass'} = $server->{'ssh_pass'};
		$server->{'ssh_pass_same'} = 1;
		}
	else {
		# Need to set, since RPM and Deb installs by default use the
		# real root password, which we don't know
		$server->{'user'} = 'root';
		$server->{'pass'} ||= &generate_random_password();
		local $perr = &set_server_webmin_password(
				$server, $rootdir, "root", $server->{'pass'});
		if ($perr) {
			$out .= "\nFailed to set Webmin password : $perr\n";
			}
		}
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

return ($out, undef);
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

1;

