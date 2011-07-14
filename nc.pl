#!/usr/bin/perl
# Open a TCP socket, write to it till EOF, then read back

use Socket;
my $delay;

if ($ARGV[0] =~ /^\-+sleep/) {
	shift(@ARGV);
	$delay = shift(@ARGV);
	}
@ARGV == 2 || die "usage: nc.pl [--delay secs] host port";
my ($addr, $port) = @ARGV;

# Open the connection
my $proto = getprotobyname("tcp");
my $fh;
socket($fh, PF_INET(), SOCK_STREAM, $proto) ||
	die "Failed to create socket : $!";
connect($fh, pack_sockaddr_in($port, inet_aton($addr))) ||
	die "Failed to connect : $!";
select($fh);
$| = 1;
select(STDOUT);
$| = 1;

# Feed input
while(<STDIN>) {
	sleep($delay) if ($delay);
	print $fh $_;
	}
shutdown($fh, 1);

# Read back output
while(<$fh>) {
	print $_;
	}
close($fh);
