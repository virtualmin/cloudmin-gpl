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



1;

