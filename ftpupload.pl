#!/usr/local/bin/perl
# Perl script to upload a single file via FTP. Contains functions ripped from
# the Webmin API.

use Socket;

@ARGV == 6 || die "usage: ftpupload.pl user pass host port destfile file|--delete";
($user, $pass, $host, $port, $destfile, $file) = @ARGV;

$err = undef;
if ($file eq "--delete") {
	&ftp_deletefile($host, $destfile, \$err, $user, $pass, $port);
	}
else {
	&ftp_upload($host, $destfile, $file, \$err, undef, $user, $pass, $port);
	}
if ($err) {
	print $err,"\n";
	exit(1);
	}
else {
	print "OK\n";
	exit(0);
	}

# ftp_upload(host, file, srcfile, [&error], [&callback], [user, pass], [port])
# Download data from a local file to an FTP site
sub ftp_upload
{
local($buf, @n);
local $cbfunc = $_[4];

$main::download_timed_out = undef;
local $SIG{ALRM} = \&download_timeout;
alarm(60);

# connect to host and login
&open_socket($_[0], $_[7] || 21, "SOCK", $_[3]) || return 0;
alarm(0);
if ($main::download_timed_out) {
	${$_[3]} = $main::download_timed_out; return 0;
	}
&ftp_command("", 2, $_[3]) || return 0;
if ($_[5]) {
	# Login as supplied user
	local @urv = &ftp_command("USER $_[5]", [ 2, 3 ], $_[3]);
	@urv || return 0;
	if (int($urv[1]/100) == 3) {
		&ftp_command("PASS $_[6]", 2, $_[3]) || return 0;
		}
	}
else {
	# Login as anonymous
	local @urv = &ftp_command("USER anonymous", [ 2, 3 ], $_[3]);
	@urv || return 0;
	if (int($urv[1]/100) == 3) {
		&ftp_command("PASS root\@".&get_system_hostname(), 2,
			     $_[3]) || return 0;
		}
	}
&$cbfunc(1, 0) if ($cbfunc);

# Switch to binary mode
&ftp_command("TYPE I", 2, $_[3]) || return 0;

# get the file size and tell the callback
local @st = stat($_[2]);
if ($cbfunc) {
	&$cbfunc(2, $st[7]);
	}

# send the file
local $pasv = &ftp_command("PASV", 2, $_[3]);
defined($pasv) || return 0;
$pasv =~ /\(([0-9,]+)\)/;
@n = split(/,/ , $1);
&open_socket("$n[0].$n[1].$n[2].$n[3]", $n[4]*256 + $n[5], "CON", $_[3]) || return 0;
&ftp_command("STOR $_[1]", 1, $_[3]) || return 0;

# transfer data
local $got;
open(PFILE, $_[2]);
while(read(PFILE, $buf, 1024) > 0) {
	local $ok = print CON $buf;
	if ($ok <= 0) {
		# Write failed!
		local $msg = "FTP write failed : $!";
		${$_[3]} = $msg; return 0;
		}
	$got += length($buf);
	&$cbfunc(3, $got) if ($cbfunc);
	}
close(PFILE);
close(CON);
if ($got != $st[7]) {
	local $msg = "Upload incomplete - file size is $st[7], but sent $got";
	${$_[3]} = $msg; return 0;
	}
&$cbfunc(4) if ($cbfunc);

# finish off..
&ftp_command("", 2, $_[3]) || return 0;
&ftp_command("QUIT", 2, $_[3]) || return 0;
close(SOCK);

return 1;
}

# ftp_command(command, expected, [&error], [filehandle])
sub ftp_command
{
my ($cmd, $expect, $err, $fh) = @_;
$fh ||= "SOCK";

my $line;
my $what = $cmd ne "" ? $cmd : "initial connection";
if ($cmd ne "") {
        print $fh "$cmd\r\n";
        }
alarm(60);
if (!($line = <$fh>)) {
	alarm(0);
	$$err = "Failed to read reply to $what"; return undef;
        }
$line =~ /^(...)(.)(.*)$/;
my $found = 0;
if (ref($expect)) {
	foreach my $c (@$expect) {
		$found++ if (int($1/100) == $c);
		}
	}
else {
	$found++ if (int($1/100) == $_[1]);
	}
if (!$found) {
	alarm(0);
	$$err = "$what failed : $3"; return undef;
	}
my $rcode = $1;
my $reply = $3;
if ($2 eq "-") {
        # Need to skip extra stuff..
        while(1) {
                if (!($line = <$fh>)) {
			alarm(0);
			$$err = "Failed to read reply to $what"; return undef;
                        }
                $line =~ /^(....)(.*)$/; $reply .= $2;
		if ($1 eq "$rcode ") { last; }
                }
        }
alarm(0);
return wantarray ? ($reply, $rcode) : $reply;
}

# open_socket(host, port, handle, [&error])
sub open_socket
{
my ($host, $port, $fh, $err) = @_;

if (!socket($fh, PF_INET, SOCK_STREAM, getprotobyname("tcp"))) {
	$$err = "Failed to create socket : $!"; return 0;
	}
my $addr;
if (!($addr = inet_aton($host))) {
	$$err = "Failed to lookup IP address for $host"; return 0;
	}
if ($gconfig{'bind_proxy'}) {
	if (!bind($fh,pack_sockaddr_in(0, inet_aton($gconfig{'bind_proxy'})))) {
		$$err = "Failed to bind to source address : $!"; return 0;
		}
	}
if (!connect($fh, pack_sockaddr_in($port, $addr))) {
	$$err = "Failed to connect to $host:$port : $!"; return 0;
	}
my $old = select($fh); $| =1; select($old);
return 1;
}

sub download_timeout
{
$main::download_timed_out = "Download timed out";
}

# ftp_deletefile(host, file, &error, [user, pass], [port])
# Delete some file or directory from an FTP server. This is done recursively
# if needed. Returns the size of any deleted sub-directories.
sub ftp_deletefile
{
local ($host, $file, $err, $user, $pass, $port) = @_;
&ftp_onecommand($host, "DELE $file", $err, $user, $pass, $port);
}

# ftp_onecommand(host, command, [&error], [user, pass], [port])
# Executes one command on an FTP server, after logging in, and returns its
# exit status.
sub ftp_onecommand
{
local ($buf, @n);

$main::download_timed_out = undef;
local $SIG{ALRM} = \&download_timeout;
alarm(60);

# connect to host and login
&open_socket($_[0], $_[5] || 21, "SOCK", $_[2]) || return 0;
alarm(0);
if ($main::download_timed_out) {
	${$_[2]} = $main::download_timed_out; return 0;
	}
&ftp_command("", 2, $_[2]) || return 0;
if ($_[3]) {
	# Login as supplied user
	local @urv = &ftp_command("USER $_[3]", [ 2, 3 ], $_[2]);
	@urv || return 0;
	if (int($urv[1]/100) == 3) {
		&ftp_command("PASS $_[4]", 2, $_[2]) || return 0;
		}
	}
else {
	# Login as anonymous
	local @urv = &ftp_command("USER anonymous", [ 2, 3 ], $_[2]);
	@urv || return 0;
	if (int($urv[1]/100) == 3) {
		&ftp_command("PASS root\@".&get_system_hostname(), 2,
			     $_[2]) || return 0;
		}
	}

# Run the command
local @rv = &ftp_command($_[1], 2, $_[2]);
@rv || return 0;

# finish off..
&ftp_command("QUIT", 2, $_[3]) || return 0;
close(SOCK);

return $rv[1];
}

