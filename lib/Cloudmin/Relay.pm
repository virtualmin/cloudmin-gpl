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

# authenticated(key, session) matches Webmin's authenticated proxy handshake.
# Miniserv replaces Sec-WebSocket-Key with the browser session's base64 value.
# Keep this compatible with xterm::verify_websocket_key; t/relay.t compares
# both checks without initializing Webmin in the relay.
sub authenticated
{
my ($key, $session) = @_;
# Missing credentials must never authenticate as an empty encoded value.
return 0 if (!defined($key) || !defined($session) || !length($session));
$key =~ s/\s//g;
return $key eq encode_base64($session, '');
}

# ready() confirms that the sandbox loaded its credentials and server code.
# Standard error is a private startup/diagnostic channel to the supervisor.
sub ready
{
my $message = "Cloudmin relay ready\n";
syswrite(STDERR, $message) == length($message) ||
	die "Cannot report relay startup\n";
}

1;
