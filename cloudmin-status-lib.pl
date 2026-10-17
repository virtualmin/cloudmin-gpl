# Read-only guest health checks; never log in or run commands in a guest.
use strict;
use warnings;
use File::Basename ();
use Cwd ();
# Load ACL helpers once, even when callers use different paths.
require(Cwd::abs_path(File::Basename::dirname(__FILE__).'/cloudmin-access-lib.pl'));
use IO::Socket::IP;
use IO::Select;
use Time::HiRes ();
use Fcntl qw(:flock);
our (%text, %config, %in, $module_root_directory, $module_var_directory,
     $module_config_directory, $module_name);
# Replace collectors that still include licensing in session permissions.
our $cloudmin_status_protocol = 13;
require "$module_root_directory/cloudmin-terminal-lib.pl";

# check_ssh_service(addresses, [port])
# Checks discovered guest addresses for an SSH banner on port (default 22).
# All addresses share a two-second budget.
# Callers supply a validated port, normally from get_terminal_port.
sub check_ssh_service
{
my ($addresses, $port) = @_;
# Callers without a saved port retain the standard SSH default.
$port = 22 if (!defined($port));
my $deadline = Time::HiRes::time() + 2;
foreach my $address (@$addresses) {
	my $remaining = $deadline - Time::HiRes::time();
	# All candidate addresses share the two-second budget.
	last if ($remaining <= 0);
	my $socket = IO::Socket::IP->new(PeerHost => $address, PeerPort => $port,
		Type => Socket::SOCK_STREAM(),
		Timeout => $remaining < 0.5 ? $remaining : 0.5);
	# An unreachable address should not prevent trying another
	# reported IP.
	next if (!$socket);
	my $until = Time::HiRes::time() + 0.5;
	# A final connection attempt cannot extend the shared probe
	# deadline.
	$until = $deadline if ($until > $deadline);
	my $buffer = '';
	# A listening TCP port alone is not evidence of a working SSH service.
	while (length($buffer) < 4096 && $until > Time::HiRes::time()) {
		# Stop waiting when this server has used its allotted
		# banner time.
		last if (!IO::Select->new($socket)->can_read($until - Time::HiRes::time()));
		# A closed socket or failed read cannot confirm SSH readiness.
		last if (!sysread($socket, my $part, 512));
		$buffer .= $part;
		# Accept SSH-2-compatible identification, even after
		# server preamble lines.
		if ($buffer =~ /(?:\A|\n)SSH-(?:2\.0|1\.99)-[^\r\n]+\r?\n/) {
			close($socket);
			return $address;
			}
		}
	close($socket);
	}
return undef;
}

1;
