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
my ($server, $cmd, $timeout, $leave) = @_;
if ($leave) {
	# Open the command in a new pty
	&foreign_require("proc", "proc-lib.pl");
	my ($fh, $fpid) = &proc::pty_process_exec($cmd);
	return (undef, 0, 0, $fh, $fpid);
	}
else {
	# Just run the command, and get the output
	my $out = $timeout ?
		&backquote_with_timeout("($cmd) 2>&1 </dev/null", $timeout) :
		&backquote_command("($cmd) 2>&1 </dev/null");
	return ($out, $?);
	}
}

# type_this_get_file(&server, remotefile, localfile, device-file)
# Can just copy the file, since we are on the same box!
sub type_this_get_file
{
my ($server, $remotefile, $localfile, $device) = @_;
my $out = &backquote_command(
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
my ($server, $localfile, $remotefile, $device) = @_;
return &type_this_get_file($server, $localfile, $remotefile, $device);
}

sub type_this_check_login
{
my ($server) = @_;
my %miniserv;
&get_miniserv_config(\%miniserv);
return (0, undef, $miniserv{'root'}, $miniserv{'port'}, $miniserv{'ssl'});
}

# type_this_stat_file(&server, remotefile)
# For a file on the Cloudmin master, just stat it directly
sub type_this_stat_file
{
my ($server, $remotefile) = @_;
return stat($remotefile);
}

# type_this_open_shell(&server)
# Opens a shell in a sub-process, connected to a pty. Returns an error message
# (or undef if OK), and a file handle.
sub type_this_open_shell
{
my ($server) = @_;
&foreign_require("proc");
my $shell = &has_command("bash") || &has_command("sh");
my ($fh, $pid) = &proc::pty_process_exec($shell);
return (undef, $fh);
}


