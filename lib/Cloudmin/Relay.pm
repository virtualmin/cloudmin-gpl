package Cloudmin::Relay;

# Minimal helpers for fresh, unprivileged console and terminal processes.
use strict;
use warnings;
use IO::Socket::INET;
use MIME::Base64 qw(encode_base64);

# initialize() reads the inherited listener and private Webmin session key.
# Expects the controller's socket on fd 0 and a systemd session credential.
sub initialize
{
# Refuse to handle browser traffic under a root UID.
die "Interactive relays must run without root privileges\n" if (!$< || !$>);
my $directory = $ENV{'CREDENTIALS_DIRECTORY'} ||
	die "Relay credentials are unavailable\n";
open(my $file, '<', "$directory/session") ||
	die "Cannot read relay credentials\n";
my $length = read($file, my $session, 257);
close($file);
# Reject empty or oversized keys and keys containing whitespace.
die "Invalid relay credentials\n"
	if (!$length || $length > 256 || $session =~ /\s/);
my $listener = IO::Socket::INET->new_from_fd(0, 'r+') ||
	die "Cannot open the relay listener\n";
return ($listener, $session);
}

1;
