# Functions for managing the server itself

sub type_this_desc
{
return $text{'this_desc'};
}

sub type_this_no_shutdown
{
return 1;	# Don't let the system shut itself down
}

sub type_this_no_reboot
{
return 1;	# Don't let the system reboot itself
}

sub type_this_no_startup
{
return 1;	# This system cannot start itself up!
}

sub type_this_no_ssh
{
return 1;		# We never need to SSH into vservers
}

# type_this_execute_command(&server, comand, [timeout])
# Just runs a command locally
sub type_this_execute_command
{
local ($server, $cmd, $timeout) = @_;
local $out = $timeout ?
	&backquote_with_timeout($cmd." 2>&1 </dev/null", $timeout) :
	&backquote_command($cmd." 2>&1 </dev/null");
return ($out, $?);
}

# type_this_get_file(&server, remotefile, localfile)
# Can just copy the file, since we are on the same box!
sub type_this_get_file
{
local ($server, $remotefile, $localfile) = @_;
local $out = &backquote_command("cp ".quotemeta($remotefile)." ".
				      quotemeta($localfile)." 2>&1");
return $? ? $out : undef;
}

# type_this_put_file(&server, localfile, remotefile)
# Can just copy the file, since we are on the same box!
sub type_this_put_file
{
local ($server, $localfile, $remotefile) = @_;
return &type_this_get_file($server, $localfile, $remotefile);
}

sub type_this_check_login
{
local ($server) = @_;
local %miniserv;
&get_miniserv_config(\%miniserv);
return (0, undef, $miniserv{'root'}, $miniserv{'port'}, $miniserv{'ssl'});
}

