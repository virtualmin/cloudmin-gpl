# Functions for talking to a the console of a virtual system

# create_console_user(&server)
# Create a special user whose shell runs the needed console command on the
# remote system. Returns undef if done, or an error message on failure.
sub create_console_user
{
local ($server) = @_;
if (&foreign_check("useradmin")) {
	&foreign_require("useradmin", "user-lib.pl");
	&foreign_require("cron", "cron-lib.pl");
	local $uname = $server->{'manager'}."-".$server->{'host'}."-console";
	&useradmin::lock_user_files();
	local @users = &useradmin::list_users();
	local ($clash) = grep { $_->{'user'} eq $uname } @users;
	return "A user named $uname already exists" if ($clash);
	local $pass = $server->{'ssh_pass'} || &random_password(16);
	&cron::create_wrapper($login_shell_cmd, $module_name, "login.pl");
	local $uinfo = { 'user' => $uname,
			 'uid' => 0,
			 'gid' => 0,
			 'pass' => &useradmin::encrypt_password($pass),
			 'passmode' => 3,
			 'plainpass' => $pass,
			 'real' => 'Console user for '.$server->{'host'},
			 'shell' => $login_shell_cmd,
			 'home' => $login_home_base.'/'.$server->{'host'} };
	&useradmin::set_user_envs($user, 'CREATE_USER', $pass);
	&useradmin::making_changes();
	&useradmin::create_user($uinfo);
	&useradmin::made_changes();
	&useradmin::clear_envs();
	&useradmin::unlock_user_files();
	if (!-d $login_home_base) {
		&make_dir($login_home_base, 0755);
		}
	if (!-d $uinfo->{'home'}) {
		&make_dir($uinfo->{'home'}, 0755);
		}
	$server->{'login_user'} = $uname;
	$server->{'login_pass'} = $pass;
	return undef;
	}
return "Users and Groups module is not installed or not supported";
}

# delete_login_user(&server)
# Deletes the console Unix user for a server
sub delete_login_user
{
local ($server) = @_;
if (!$server->{'login_user'}) {
	# Was never setup
	return undef;
	}
if (&foreign_check("useradmin")) {
	&foreign_require("useradmin", "user-lib.pl");
	&useradmin::lock_user_files();
	local @users = &useradmin::list_users();
	local ($uinfo) = grep { $_->{'user'} eq $server->{'login_user'} }
			      @users;
	return "User $server->{'login_user'} does not exist" if (!$uinfo);
	&useradmin::set_user_envs($user, 'DELETE_USER');
	&useradmin::making_changes();
	&useradmin::delete_user($uinfo);
	&useradmin::made_changes();
	&useradmin::clear_envs();
	&useradmin::unlock_user_files();
	delete($server->{'login_user'});
	delete($server->{'login_pass'});
	if (&is_under_directory($login_home_base, $uinfo->{'home'})) {
		&unlink_file($uinfo->{'home'});
		}
	return undef;
	}
return "Users and Groups module is not installed or not supported";
}

# has_login_user(&server)
# Retuens 1 if the special console user exists, 0 if not
sub has_login_user
{
local ($server) = @_;
local $uname = $server->{'manager'}."-".$server->{'host'}."-console";
return defined(getpwnam($uname)) ? 1 : 0;
}

# random_password([len])
# Returns a random password of the specified length, or the configured default
sub random_password
{
&seed_random();
&foreign_require("useradmin", "user-lib.pl");
local $random_password;
local $len = $_[0] || 16;
foreach (1 .. $len) {
	$random_password .= $useradmin::random_password_chars[
			rand(scalar(@useradmin::random_password_chars))];
	}
return $random_password;
}

# get_ssh_host_port()
# Returns the SSH hostname and port number for the VM2 master, and a list of
# SSH protocol versions accepted.
sub get_ssh_host_port
{
local $host = $ENV{'HTTP_HOST'} || $ENV{'SERVER_NAME'} ||
	      &get_system_hostname();
$host =~ s/:\d+$//;
local $port;
local @protos;
if (&foreign_check("sshd")) {
	# Ask the SSH server module for the port
	&foreign_require("sshd", "sshd-lib.pl");
	local $conf = &sshd::get_sshd_config();
	$port = &sshd::find_value("Port", $conf);
	local $protos = &sshd::find_value("Protocol", $conf);
	@protos = split(/,/, $protos);
	}
$port ||= 22;
@protos = (1,2) if (!@protos);
return ($host, $port, \@protos);
}

# forward_console_data(fh)
# Forward traffic from STDIN/OUT to and from a console file handle
sub forward_console_data
{
local ($fh) = @_;

# Turn off echo on STDIN
eval "use IO::Stty";
if (!$@) {
	IO::Stty::stty(\*STDIN, 'raw', '-echo');
	}

# Pass all input back and forth
select($fh); $| = 1; select(STDOUT);
$| = 1;
while(1) {
	local $rmask = undef;
	vec($rmask, fileno(STDIN), 1) = 1;
	vec($rmask, fileno($fh), 1) = 1;
	local $sel = select($rmask, undef, undef, 0);
	if (vec($rmask, fileno(STDIN), 1)) {
		# Got something from SSH client
		my $buf;
		$ok = sysread(STDIN, $buf, 1024);
		last if ($ok <= 0);	# End of the client
		syswrite($fh, $buf, length($buf));
		}
	if (vec($rmask, fileno($fh), 1)) {
		# Got something from console
		my $buf;
		$ok = sysread($fh, $buf, 1024);
		last if ($ok <= 0);	# End of the client
		syswrite(STDOUT, $buf, length($buf));
		}
	}
}

1;

