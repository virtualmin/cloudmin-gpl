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
return 1;	# We never need to SSH into vservers
}

sub type_this_no_image
{
return 1;	# Real systems cannot be imaged
}

sub type_this_can_transfer
{
return 1;	# Can always transfer to self
}

# type_this_execute_command(&server, comand, [timeout], [leave-open])
# Just runs a command locally
sub type_this_execute_command
{
local ($server, $cmd, $timeout, $leave) = @_;
if ($leave) {
	# Open the command in a new pty
	&foreign_require("proc", "proc-lib.pl");
	local ($fh, $fpid) = &proc::pty_process_exec($cmd);
	return (undef, 0, 0, $fh, $fpid);
	}
else {
	# Just run the command, and get the output
	local $out = $timeout ?
		&backquote_with_timeout("($cmd) 2>&1 </dev/null", $timeout) :
		&backquote_command("($cmd) 2>&1 </dev/null");
	return ($out, $?);
	}
}

# type_this_get_file(&server, remotefile, localfile, device-file)
# Can just copy the file, since we are on the same box!
sub type_this_get_file
{
local ($server, $remotefile, $localfile, $device) = @_;
local $out = &backquote_command(
	$device ?
	  "dd if=".quotemeta($remotefile)." of=".quotemeta($localfile).
	  "bs=1024 2>&1" :
	"cp ".quotemeta($remotefile)." ".quotemeta($localfile)." 2>&1");
return $? ? $out : undef;
}

# type_this_put_file(&server, localfile, remotefile, device-file)
# Can just copy the file, since we are on the same box!
sub type_this_put_file
{
local ($server, $localfile, $remotefile, $device) = @_;
return &type_this_get_file($server, $localfile, $remotefile, $device);
}

sub type_this_check_login
{
local ($server) = @_;
local %miniserv;
&get_miniserv_config(\%miniserv);
return (0, undef, $miniserv{'root'}, $miniserv{'port'}, $miniserv{'ssl'});
}

