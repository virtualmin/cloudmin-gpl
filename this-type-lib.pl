# Functions for managing the server itself

sub type_this_desc
{
return $text{'this_typedesc'};
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

sub type_this_can_password
{
return 1;
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
	return (undef, 0, undef, 0, $fh, $fpid);
	}
else {
	# Just run the command, and get the output
	my $out = $timeout ?
		&backquote_with_timeout("($cmd) 2>&1 </dev/null", $timeout) :
		&backquote_command("($cmd) 2>&1 </dev/null");
	return ($out, $?/256);
	}
}

# type_this_get_file(&server, remotefile, localfile, device-file)
# Can just copy the file, since we are on the same box!
sub type_this_get_file
{
my ($server, $remotefile, $localfile, $device) = @_;
my $out = &backquote_command(
	$device ?
		&dd_command($remotefile, $localfile)." 2>&1" :
	-d $localfile && -d remotefile ?
		"cp -r -H ".quotemeta($remotefile)."/* ".
		  quotemeta($localfile)." 2>&1" :
		"cp -r -H ".quotemeta($remotefile)." ".
		  quotemeta($localfile)." 2>&1");
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

# type_this_make_dir(&server, remotedir, perms, recur)
# For a dir on the Cloudmin master, just create it directly
sub type_this_make_dir
{
my ($server, $remotedir, $perms, $recur) = @_;
my $ok = &make_dir($remotedir, $perms, $recur);
return $ok ? undef : "$!";
}

# type_this_list_dir(&server, remotedir)
# For a dir on the Cloudmin master, just list it directly
sub type_this_list_dir
{
my ($server, $remotedir) = @_;
opendir(LISTDIR, $remotedir) || return "$!";
my @files = grep { $_ ne "." && $_ ne ".." } readdir(LISTDIR);
closedir(LISTDIR);
return \@files;
}

# type_this_open_shell(&server)
# Opens a shell in a sub-process, connected to a pty. Returns an error message
# (or undef if OK), and a file handle.
sub type_this_open_shell
{
my ($server) = @_;
&foreign_require("proc");
my $shell = &has_command("bash") || &has_command("sh");
my $pwd = &get_current_dir();
chdir("/root") || chdir("/");
my ($fh, $pid) = &proc::pty_process_exec($shell);
chdir($pwd);
return (undef, $fh);
}

# type_this_real_interfaces(&server)
# Returns a list of interfaces on the master system. Each is a hash ref with
# keys name, bytes_in, bytes_out, packets_in, packets_out
sub type_this_real_interfaces
{
my ($server) = @_;
my $out = &read_file_contents("/proc/net/dev");
my @rv;
foreach my $dev (split(/\r?\n/, $out)) {
	$dev =~ s/^\s+//;
        my @w = split(/[ \t:]+/, $dev);
	if ($w[0] =~ /^eth\d+/) {
		my $iface = { 'name' => $w[0],
			      'bytes_in' => $w[1],
			      'packets_in' => $w[2],
			      'bytes_out' => $w[9],
			      'packets_out' => $w[10] };
		push(@rv, $iface);
		}
	}
return \@rv;
}

1;


