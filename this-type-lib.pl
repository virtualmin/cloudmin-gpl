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

