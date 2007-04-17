# Functions for general setup and management of multiple Virtualmin servers
# XXX search if too many servers
# XXX grouping
# XXX for zones, we don't need to SSH in

do '../web-lib.pl';
&init_config();
do '../ui-lib.pl';
&foreign_require("servers", "servers-lib.pl");
&remote_error_setup(\&remote_error_handler);
use Net::Amazon::EC2;

@possible_server_management_types = ( [ "real", undef ],
				      [ "zones", "zones" ],
				      [ "ec2", undef ],
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
if ($server->{'id'}) {
	&servers::delete_server($server->{'id'});
	}
}

# describe_os(os)
# Converts an OS code as used by the 'servers' module into a name
sub describe_os
{
local ($t) = @_;
local ($type) = grep { $_->[0] eq $t } @servers::server_types;
return $type->[1];
}

# describe_status(&server, [withcolor])
# Returns a string describing the status of some server (down, nossh,
# nologin, nowebmin, nowebminlogin, novirt, virt)
sub describe_status
{
local ($s, $withcol) = @_;
local $cmap = { 'down' => 'ff0000',
		'nossh' => 'ff00ff',
		'nosshlogin' => 'ff00cc',
		'nowebmin' => 'ffff00',
		'nowebminlogin' => 'ffcc00',
		'novirt' => 'aaff00',
		'virt' => '00aa00' };
local $msg = $text{'status_'.$s->{'status'}} || $text{'status_unknown'};
if ($s->{'status'} eq 'virt') {
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

# ssh_key_menu()
# Returns a menu for selecting an SSH key
sub ssh_key_menu
{
local ($name) = @_;
local @keys = sort { $a->{'desc'} cmp $b->{'desc'} } &list_ssh_keys();
if (@keys) {
	return &ui_select($name, undef,
		[ map { [ $_->{'id'}, $_->{'desc'} ] } @keys ]);
	}
else {
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
# login, 3=Unknown error, 4=Timeout) and an error message.
sub check_server_ssh_login
{
local ($server) = @_;
local $cmd = "ssh -".$server->{'ssh_protocol'};
if ($server->{'key'}) {
	local ($key) = grep { $_->{'id'} == $server->{'key'} } &list_ssh_keys();
	$cmd .= " -i ".quotemeta($key->{'file'});
	}
$cmd .= " $server->{'ssh_user'}\@$server->{'host'} echo OK";
return &run_ssh_command($cmd, $server->{'ssh_pass'}, 10);
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
# or 3 for some other error, 4 for timeout.
sub run_ssh_command
{
local ($cmd, $pass, $timeout) = @_;
&foreign_require("proc", "proc-lib.pl");
local ($wrong_password, $got_login, $connect_failed);
local $out;
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
	local $got = waitpid($fpid, 0);
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
if ($got) {
	return (3, $out);
	}
return (0, $out);
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

# Check SSH status
local ($status, $err) = &check_server_ssh_login($server);
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

# If we have a Webmin login, try it
if ($server->{'user'} || $server->{'id'} == 0) {
	($status, $err) = &check_server_webmin_login($server);
	if ($status == 2) {
		$server->{'status'} = 'nowebminlogin';
		$server->{'status_msg'} = $err;
		return 0;
		}
	elsif ($status) {
		$server->{'status'} = 'nowebmin';
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
}

# get_server_collected(&server)
# Returns the hash ref of collected stats info from some server
sub get_server_collected
{
local ($server) = @_;
local $idata = &read_file_contents("$server_collected_dir/$server->{'id'}");
return undef if (!$idata);	# Not collected yet?
return &unserialise_variable($idata);
}

# parallel_check_serve_status(&servers)
# Checks the status of multiple servers in 10 (by default) processes
sub parallel_check_serve_status
{
local ($servers) = @_;

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
			&check_server_status($server);
			&save_managed_server($server);
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

1;

