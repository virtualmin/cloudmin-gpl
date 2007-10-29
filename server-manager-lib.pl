# Functions for general setup and management of multiple Virtualmin servers
# XXX move servers
# XXX refresh should be in dependency order
# XXX resource management
#	XXX xen disk sizes
#	XXX edit memory allocations
#	XXX cpu limits
# XXX backup and restore managed systems? Use Backup Configuration Files module
# XXX can we work out CIDRs automatically?
# XXX create new Xen images with updates
# XXX flag images that are being downloaded (with PID to clear?)
#
# XXX cut-down version for just EC2?
#	XXX should this grant access to Virtualmin AMI? No ..
# XXX version just for local Xen
#	XXX add this system automatically
#	XXX install kernel and dependencies
#	XXX special licence
#	XXX installer should include and setup BIND

do '../web-lib.pl';
&init_config();
do '../ui-lib.pl';
do 'images-lib.pl';
&foreign_require("servers", "servers-lib.pl");
&foreign_require("proc", "proc-lib.pl");
&foreign_require("net", "net-lib.pl");
&remote_error_setup(\&remote_error_handler);
use Net::Amazon::EC2;

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
@cron_cmds = ( $check_status_cmd, $check_licence_cmd );

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

$virtualmin_licence_host = "software.virtualmin.com";
$virtualmin_licence_port = 80;
$vm2_licence_prog = "/cgi-bin/slicence.cgi";
$virtualmin_licence_prog = "/cgi-bin/vlicence.cgi";
$virtualmin_licence_ssl = 0;
$virtualmin_installer_prog = "/cgi-bin/install.cgi";
$virtualmin_alllicences_prog = "/cgi-bin/alllicences.cgi";

$virtualmin_licences_file = "$module_config_directory/virtualmin-licences";
$serial_cache_file = "$module_config_directory/serial-cache";
$virtualmin_progress_file = "$module_config_directory/progress-licences";

@virtualmin_operating_systems = ( "debian", "ubuntu", "redhat", "fedora",
				  "centos" );

$virtualmin_apt_package_key = "http://software.virtualmin.com/lib/RPM-GPG-KEY-virtualmin";
$virtualmin_webmin_apt_package_key = "http://software.virtualmin.com/lib/RPM-GPG-KEY-webmin";

&set_all_html_print();

# list_managed_servers()
# Returns a list of all servers managed by this module. These are actually
# just a subset of those from the Webmin Servers Index module
sub list_managed_servers
{
local @rv = grep { $_->{'module'} eq $module_name } &servers::list_servers();
@rv = grep { $server_management_types{$_->{'manager'}} } @rv;
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
	$msg .= " (".&text('status_doms', $s->{'virtualmin_domains'}).")";
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
# login, 3=Unknown error, 4=Timeout, 5=Host down, 6=Virtual system down) and
# an error message, the Webmin root directory (if installed), the Webmin
# port and the Webmin SSL flag.
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
local $cmd = "ssh -q -x -".$server->{'ssh_protocol'};
if ($server->{'key'}) {
	local ($key) = grep { $_->{'id'} == $server->{'key'} } &list_ssh_keys();
	$cmd .= " -i ".quotemeta($key->{'file'});
	}
$cmd .= " $server->{'ssh_user'}\@$server->{'host'} 'grep ^root= /etc/webmin/miniserv.conf ; grep ^port= /etc/webmin/miniserv.conf ; grep ^ssl= /etc/webmin/miniserv.conf ; echo OK'";
local ($status, $out) = &run_ssh_command($cmd, $server->{'ssh_pass'}, 30);
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
			local $pp = &get_file_data_from_server($server,
					"/etc/webmin/perl-path");
			chop($pp);
			$pp ||= "perl";
			local ($sout, $sex) = &execute_command_on_server(
				$server, "$pp -e 'use Net::SSLeay'");
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

# run_ssh_command(command, password, timeout)
# Attempts to run some ssh or scp command, giving it a password if needed.
# Returns 0 on success, 1 if the connection fails, 2 if the password is wrong,
# or 3 for some other error, 4 for timeout, and the output.
sub run_ssh_command
{
local ($cmd, $pass, $timeout) = @_;
local ($wrong_password, $got_login, $connect_failed, $given_password);
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
		local $rv = &wait_for($fh, "password:", "yes\\/no", "(^|\\n)\\s*Permission denied.*\n", "ssh: connect.*\n", ".*\n");
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
		elsif ($rv < 0) {
			last;
			}
		else {
			$out .= $wait_for_input;
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
	local $sshcmd = "ssh -q -x -".$server->{'ssh_protocol'};
	if ($server->{'key'}) {
		local ($key) = grep { $_->{'id'} == $server->{'key'} }
				    &list_ssh_keys();
		$sshcmd .= " -i ".quotemeta($key->{'file'});
		}
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

# Just scp down
local $sshcmd = "scp -r -".$server->{'ssh_protocol'};
if ($server->{'key'}) {
	local ($key) = grep { $_->{'id'} == $server->{'key'} }
			    &list_ssh_keys();
	$sshcmd .= " -i ".quotemeta($key->{'file'});
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

# Just scp up
local $sshcmd = "scp -r -".$server->{'ssh_protocol'};
if ($server->{'key'}) {
	local ($key) = grep { $_->{'id'} == $server->{'key'} }
			    &list_ssh_keys();
	$sshcmd .= " -i ".quotemeta($key->{'file'});
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
# Returns 1 if some host responds to a ping in 5 seconds
sub ping_server_host
{
local ($host) = @_;
local $pingcmd = $gconfig{'os_type'} =~ /-linux$/ ?
			"ping -c 1 -t 1" : "ping";
local ($out, $timed_out) = &backquote_with_timeout(
				$pingcmd." ".$host." 2>&1", 2, 1);
return !$timed_out && !$?;
}

# check_server_status(&server, [re-generate-collected])
# Checks the status of a managed server, and updates the server object. Checks
# SSH login, Webmin login, Virtualmin status, number of domains, memory, disk
# and CPU load.
sub check_server_status
{
local ($server, $regen) = @_;

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

# Do a quick ping, if this is a non-virtual system
$server->{'statustime'} = time();
local $clfunc = "type_".$server->{'manager'}."_check_login";
local $ping;
if (!defined(&$clfunc)) {
	$ping = &ping_server_host($server->{'host'});
	}

# Check if we can login
local ($status, $err, $webminroot, $webminport, $webminssl) =
	&check_server_ssh_login($server);
if ($status == 2) {
	# Could not login via SSH
	$server->{'status'} = 'nosshlogin';
	$server->{'status_msg'} = $err;
	&unlock_file($file);
	return 0;
	}
elsif ($status == 5) {
	# Hosting system is down
	$server->{'status'} = 'nohost';
	$server->{'status_msg'} = $err;
	&unlock_file($file);
	return 0;
	}
elsif ($status == 6) {
	# Virtual system down
	$server->{'status'} = 'down';
	$server->{'status_msg'} = $err;
	&unlock_file($file);
	return 0;
	}
elsif ($status && !$ping && !defined(&$clfunc)) {
	# Could not SSH or ping, so assume totally down (for real systems)
	$server->{'status'} = 'down';
	$server->{'status_msg'} = $err;
	&unlock_file($file);
	return 0;
	}
elsif ($status) {
	# Could not SSH, but can ping or the virtual system reports that
	# it should be up
	$server->{'status'} = 'nossh';
	$server->{'status_msg'} = $err;
	&unlock_file($file);
	return 0;
	}

# Fix up Webmin port and SSL flag to reflect reality
if ($webminport && $server->{'id'} != 0) {
	$server->{'port'} = $webminport;
	$server->{'ssl'} = $webminssl;
	if (!$server->{'user'}) {
		# SSH says we have Webmin, but we don't know the login! Most
		# likely it was installed behind our back, so assume login is
		# same as root.
		$server->{'user'} = 'root';
		$server->{'pass'} = $server->{'ssh_pass'};
		$server->{'ssh_pass_same'} = $server->{'ssh_pass'} ? 1 : 0;
		}
	}

# If we have a Webmin login, try it
if ($server->{'user'} || $server->{'id'} == 0) {
	local ($status, $err, $ostype, $real_ostype) =
		&check_server_webmin_login($server);
	if ($status == 2) {
		# Webmin replied, but it rejected our login
		$server->{'status'} = 'nowebminlogin';
		$server->{'status_msg'} = $err;
		&unlock_file($file);
		return 0;
		}
	elsif ($status) {
		# Could not login to Webmin .. which may be because it is down,
		# un-contactable, or not installed
		$server->{'status'} = $webminroot ? 'downwebmin' : 'nowebmin';
		$server->{'status_msg'} = $err;
		&unlock_file($file);
		return 0;
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
			&remote_foreign_require($server, "virtual-server",
						"virtual-server-lib.pl");
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
			# one yet
			if (!$server->{'virtualmin_checked'}) {
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
			&save_server_domains($server, [ ]);
			$server->{'status'} = 'novirt';
			$server->{'status_msg'} = undef;
			delete($server->{'virtualmin_domains'});
			delete($server->{'virtualmin_poss'});
			$info = { };
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
else {
	$server->{'status'} = $webminroot ? 'nowebminlogin' : 'nowebmin';
	$server->{'status_msg'} = undef;
	}

&unlock_file($file);
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
for(my $i=0; $i<@$servers; $i++) {
	push(@{$buckets[$i % $procs]}, $servers->[$i]);
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

# parallel_check_server_status(&servers, [re-generate])
# Checks the status of multiple servers in 10 (by default) processes
sub parallel_check_server_status
{
local ($servers, $regen) = @_;
&parallel_server_function($servers,
	sub { &check_server_status($_[0], $regen);
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
	      foreach $p (&sort_package_updates(@{$info->{'poss'}})) {
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
			$cmd .= " ".quotemeta($a->[1]);
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
		"capture_function_output", "package_install",
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

# shutdown_server(&server)
# Remotely shut down some system. Returns undef on success, or an error
# message on failure.
sub shutdown_server
{
local ($server) = @_;
local $sfunc = "type_".$server->{'manager'}."_shutdown";
if (defined(&$sfunc)) {
	# Type provides a shutdown function
	return &$sfunc($server);
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
# Start up some virtual system by calling it's type-specific function. Returns
# undef on success, or an error message on failure.
sub startup_server
{
local ($server) = @_;
local $sfunc = "type_".$server->{'manager'}."_startup";
return &$sfunc($server);
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
		"apt-get -y -f --force-yes install </dev/null | cat");
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
	    "wget -nv -O $temp $src && cd $basedir && gunzip -c $temp | tar xf - && echo webmin-*/version && rm -f $temp");
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

# delete_bind8_record(dnsname, zonename)
# Deletes the DNS record that belonged to some server
sub delete_bind8_record
{
local ($dnsname, $zonename) = @_;
local @zones = &list_bind_zones();
local ($zone) = grep { $_->{'name'} eq $zonename } @zones;
if ($zone && $dnsname) {
	local @recs = &bind8::read_zone_file($zone->{'file'}, $zone->{'name'});
	local ($r) = grep { $_->{'name'} eq $dnsname } @recs;
	if ($r) {
		&bind8::delete_record($zone->{'file'}, $r);
		&bind8::bump_soa_record(\@recs);
		&bind8::restart_bind();
		}
	}
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
		push(@rv, grep { $_->{'id'} != $server->{'id'} &&
				 &$dfunc($server, $_) } @allservers);
		}
	}
return @rv;
}

# allocate_ip_address(start-ip, end-ip)
# Returns an IP address from the given range that is not in use or pingable
sub allocate_ip_address
{
local ($startip, $endip) = @_;
local %used = &used_ip_addresses();
local $start = &net::ip_to_integer($startip);
local $end = &net::ip_to_integer($endip);
for(my $n=$start; $n<=$end; $n++) {
	local $ip = &net::integer_to_ip($n);
	if (!$used{$ip} && !&ping_server_host($ip)) {
		return $ip;
		}
	}
return undef;
}

# used_ip_addresses()
# Returns a hash of all IP addresses used by managed systems
sub used_ip_addresses
{
local %used;
foreach my $s (&list_managed_servers()) {
	$used{&to_ipaddress($s->{'host'})} = $s;
	local $ifunc = "type_".$s->{'manager'}."_list_interfaces";
	if (defined(&$ifunc)) {
		# Get from server manager virtual interfaces
		local $ifaces = &$ifunc($s);
		if (ref($ifaces)) {
			foreach my $iface (@$ifaces) {
				$used{$iface->{'address'}} = $s;
				}
			}
		}
	elsif ($s->{'status'} eq 'virt' || $s->{'status'} eq 'novirt') {
		# Get from active IPs
		&remote_foreign_require($s, "net", "net-lib.pl");
		foreach my $iface (&remote_foreign_call($s, "net",
						"active_interfaces")) {
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
	foreach my $cmd ("rpm", "dpkg", "pkgadd") {
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
if ($pkg ne "rpm" && $pkg ne "dpkg") {
	return $text{'virtualmin_epkg'};
	}
if ($update ne "apt" && $update ne "yum" && $update ne "up2date") {
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

# Get our licence details
# XXX parameterize
local ($serial, $key) = &get_server_manager_serial();
if (!$serial) {
	return $text{'virtualmin_elicence'};
	}

# Download the installer
local $itemp = &transname("virtualmin-install.sh");
local $error;
&http_download($virtualmin_licence_host,
	       $virtualmin_licence_port,
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
$rv .= &ui_form_start("/$module_name/licence.cgi");
$rv .= &ui_submit($text{'licence_recheck'});
$rv .= &ui_form_end();
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
local ($out, $error);
&http_download($virtualmin_licence_host,
	       $virtualmin_licence_port,
	       "$vm2_licence_prog?id=$id&serial=$key",
	       \$out, \$error, undef, $virtualmin_licence_ssl);
if ($error) {
	$licence->{'status'} = 2;
	$licence->{'err'} = "Failed to contact licence server : $error";
	}
elsif ($out =~ /^EXP\s+(\S+)\s+(\S+)/) {
	$licence->{'status'} = 3;
	$licence->{'err'} = "The licence for this system expired on $1";
	}
elsif ($out =~ /^ERR\s+(.*)/) {
	$licence->{'status'} = 2;
	$licence->{'err'} = "An error occurred checking the licence : $1";
	}
elsif ($out =~ /^OK\s+(\S+)\s+(\S+)/) {
	$licence->{'status'} = 0;
	$licence->{'err'} = undef;
	$licence->{'expiry'} = $1;
	$licence->{'servers'} = $2;
	}
else {
	$licence->{'status'} = 1;
	$licence->{'err'} = "No valid licence was found for your host ID $_[0] and license key $key";
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
			@ipdoms > 5 ? &text('iface_many', scalar(@ipdoms)) :
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
local ($roothome, $ex, $err) = &execute_command_on_server($server, "echo ~");
$roothome =~ s/\r|\n//g;
$roothome ||= "/root";
&execute_command_on_server($server,
	"mkdir $roothome/.ssh ; chmod 700 $roothome/.ssh");
local $temp = &transname();
&open_tempfile(AUTH, ">$temp");
&print_tempfile(AUTH, &generate_public_key($key),"\n");
&close_tempfile(AUTH);
&set_ownership_permissions(undef, undef, 0700, $temp);
local $err = &put_file_to_server($server, $temp,
				 "$roothome/.ssh/authorized_keys");
return $err;
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

# check_domain_move(&serverdoms, &destserver)
# Checks if the given set of virtual servers can be moved together, and returns
# an error message if not.
sub check_domain_move
{
local ($serverdoms, $dest, $delete) = @_;
local @destdoms = &get_server_domains($dest);

foreach my $sd (@$serverdoms) {
	local ($server, $d) = @$sd;
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
	# the source system to work
	if ($d->{'virt'} && !$d->{'virtalready'} && $delete != 1) {
		return &text('dmass_evirtdelete', $d->{'dom'}, $d->{'ip'});
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

# move_domains_to_server(&serverdoms, &destserver)
# Transfers domains from source systems to a single destination. Calls 
# $first_print and friends to display progress.
sub move_domains_to_server
{
local ($serverdoms, $dest, $delete) = @_;
local (@refresh, %refreshed);

# Sort list so that parents come first
local @sorted = sort { $a->[1]->{'parent'} <=> $b->[1]->{'parent'} ||
		       $a->[1]->{'alias'} <=> $b->[1]->{'alias'} } @$serverdoms;

local %failed;
foreach my $sd (@sorted) {
	local ($server, $d) = @$sd;

	# Find a good temp dir on the source
	&$first_print(&text('move_backing', $d->{'dom'}, $server->{'host'}));
	$last_remote_error = undef;
	&remote_foreign_require($server, "webmin", "webmin-lib.pl");
	if ($last_remote_error) {
		&$second_print(&text('move_ewebmin', $last_remote_error));
		$failed{$d->{'id'}} = $sd;
		next;
		}
	local $temp = &remote_foreign_call($server, "webmin", "tempname",
					   "$d->{'dom'}.tar.gz");
	local $tmpdir = $temp;
	$tmpdir =~ s/\/([^\/]+)$//;

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

	# Backup to a temp file on the target
	local @args = ( [ "domain", $d->{'dom'} ],
			[ "all-features" ],
			[ "option", "mail mailfiles 1" ],
			[ "newformat" ],
			[ "dest", $tmpdir ] );
	local ($err, $out) = &call_virtualmin_api($server, "backup-domain", \@args);
	if ($err) {
		&$second_print(&text('move_ebackup', $err));
		$failed{$d->{'id'}} = $sd;
		next;
		}

	# Get the resulting size
	local (@st, $filename);
	foreach my $p ("$d->{'dom'}.tar.gz",
		       "$d->{'dom'}.tar.bz2",
		       "$d->{'dom'}.tar") {
		local $st = &remote_eval($server, "webmin",
					"[ stat('$tmpdir/$p') ]");
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
	if ($server->{'id'} != 0) {
		&$first_print(&text('move_download', $d->{'dom'}, $filename));
		$localtemp = &transname($filename);
		local $err = &get_file_from_server($server, "$tmpdir/$filename",
						   $localtemp);
		&execute_command_on_server($server,
				   "rm -f ".quotemeta("$tmpdir/$filename"));
		if ($err) {
			&$second_print(&text('move_edownload', $err));
			$failed{$d->{'id'}} = $sd;
			next;
			}
		@st = stat($localtemp);
		&$second_print(&text('move_downloaded', &nice_size($st[7])));
		}
	else {
		$localtemp = "$tmpdir/$filename";
		@st = stat($localtemp);
		}

	# Transfer to destination (if not already there)
	local $desttemp;
	if ($dest->{'id'} != 0) {
		&$first_print(&text('move_upload', $d->{'dom'}, $filename,
						   $dest->{'host'}));
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
		local $err = &put_file_to_server($dest, $localtemp, $desttemp);
		unlink($localtemp);
		if ($err) {
			&$second_print(&text('move_eupload', $err));
			$failed{$d->{'id'}} = $sd;
			next;
			}
		&$second_print(&text('move_uploaded', &nice_size($st[7])));
		}
	else {
		$desttemp = $localtemp;
		}

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

	# Restore on destination
	&$first_print(&text('move_restore', $d->{'dom'}, $dest->{'host'}));
	local @args = ( [ "source", $desttemp ],
			[ "all-features" ],
			[ "option", "dns fixip 1" ],
			[ "option", "web fixip 1" ],
			[ "option", "ssl fixip 1" ],
			[ "option", "mail mailfiles 1" ],
			[ "domain", $d->{'dom'} ] );
	local ($err, $out) = &call_virtualmin_api($dest, "restore-domain", \@args);
	if ($delete != 1) {
		&execute_command_on_server($server, "rm -f ".quotemeta($desttemp));
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

	$done{$d->{'id'}} = 1;
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
if ($server->{'status'} eq 'virt' || $server->{'status'} eq 'novirt') {
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
# Returns 3 array refs, for links, titles and icons
sub get_global_links
{
local ($virtcount) = @_;
local (@glinks, @gtitles, @gicons);

# Show icons for global settings
if ($virtcount) {
	# Virtualmin domains
	push(@glinks, "list_domains.cgi");
	push(@gtitles, $text{'domains_title'});
	push(@gicons, "images/domains.gif");

	# Default features
	push(@glinks, "list_features.cgi");
	push(@gtitles, $text{'features_title'});
	push(@gicons, "images/features.gif");
	}

# Virtualmin licences
push(@glinks, "list_licences.cgi");
push(@gtitles, $text{'licences_title'});
push(@gicons, "images/licences.gif");

# SSH key management
push(@glinks, "list_keys.cgi");
push(@gtitles, $text{'keys_title'});
push(@gicons, "images/keys.gif");

# Server images
if ($server_management_types{'xen'} ||
    $server_management_types{'vserver'} ||
    $server_management_types{'zones'}) {
	push(@glinks, "list_images.cgi");
	push(@gtitles, $text{'images_title'});
	push(@gicons, "images/images.gif");
	}

# Type-defined icons
foreach my $t (@server_management_types) {
	my $gfunc = "type_".$t."_global_links";
	if (defined(&$gfunc)) {
		foreach my $g (&$gfunc()) {
			push(@glinks, $g->{'link'});
			push(@gtitles, $g->{'title'});
			push(@gicons, $g->{'icon'});
			}
		}
	}

return (\@glinks, \@gtitles, \@gicons);
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
local $sfunc = "type_".$t."_no_shutdown";
local $noshut = defined(&$sfunc) && &$sfunc($server);
local $rfunc = "type_".$t."_no_reboot";
local $noreboot = defined(&$rfunc) && &$rfunc($server);
local $tfunc = "type_".$t."_can_transfer";
local $cantransfer = defined(&$tfunc) && &$tfunc($server);

if ($status eq 'down' || $status eq 'nossh' || $status eq 'nohost') {
	# Actions are limited when system is down
	local $sfunc = "type_".$t."_no_startup";
	local $nostart = defined(&$sfunc) && &$sfunc($server) ||
		   	 $status eq 'nohost';
	push(@rv, [ "refresh", $text{'edit_refresh'} ]);
	if ($cantransfer) {
		push(@rv, [ "transfer", $text{'edit_transfer'} ]);
		}
	push(@rv, [ "startup", $text{'edit_startup'} ]) if (!$nostart);
	if ($status eq 'nossh' && !$noshut) {
		push(@rv, [ "shutdown", $text{'edit_shutdown'} ]);
		}
	}
else {
	# Most actions are only for up servers
	local $wurl = &webmin_link($server);
	push(@rv, [ "refresh", $text{'edit_refresh'} ],
		  undef,
		  [ "shell", $text{'edit_shell'} ]);
	if ($cantransfer) {
		push(@rv, [ "transfer", $text{'edit_transfer'} ]);
		}
	if (($status eq 'novirt' || $status eq 'virt') && $server->{'id'}) {
		push(@rv, [ "webmin", $text{'edit_webmin2'}, 1, $wurl ]);
		}
	push(@rv, undef);	# Spacer
	push(@rv, [ "pass",  $text{'edit_setpass'} ]);
	if (($status eq 'novirt' || $status eq 'nowebmin') &&
	    $server->{'manager'} ne 'this') {
		push(@rv, [ "installvirt", $text{'edit_installvirt'} ]);
		}
	if ($status eq 'nowebmin') {
		push(@rv, [ "installwebmin", $text{'edit_installwebmin'} ]);
		}
	if ($status eq 'virt' && $server->{'virtualmin_error'}) {
		push(@rv, [ "recheck", $text{'edit_recheck'} ]);
		}
	if (!$noreboot) {
		push(@rv, [ "reboot", $text{'edit_reboot'} ]);
		}
	if (!$noshut) {
		push(@rv, [ "shutdown", $text{'edit_shutdown'} ]);
		}
	}
if ($t ne 'real' && $t ne 'this') {
	push(@rv, [ "delete", $text{'edit_delete'} ]);
	}
if (!$noimage) {
	push(@rv, [ "image", $text{'edit_image'} ]);
	}
# Add type-specific actions
local $afunc = "type_".$t."_server_actions";
if (defined(&$afunc)) {
	push(@rv, &$afunc($server));
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

# virtualmin_licence_form(name, no-none)
# Returns HTML for selecting a Virtualmin licence
sub virtualmin_licence_form
{
local ($name, $nonone) = @_;
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
else {
	return (undef, "Unknown licence mode!");
	}
}

# list_virtualmin_licences()
# Returns a list of serial numbers and keys that have been pre-registered
# for use by Virtualmin
sub list_virtualmin_licences
{
# If the VM2 licence can also be used for Virtualmin, start with it
&lock_file($virtualmin_licences_file);
local @rv;
local ($vm2serial, $vm2key) = &get_server_manager_serial();
local ($lok, $ldoms, $lservers) = &check_virtualmin_serial($vm2serial, $vm2key);
if ($lok > 0) {
	push(@rv, { 'serial' => $vm2serial,
		    'key' => $vm2key,
		    'domains' => $ldoms,
		    'servers' => $lservers,
		    'max_last' => time(),
		    'vm2' => 1 });
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
	if (!$l->{'max'} || time() - $l->{'max_last'} >= 24*60*60) {
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

1;

