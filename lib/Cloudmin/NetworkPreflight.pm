package Cloudmin::NetworkPreflight;

# Check libvirt's live IPv4 forwarding rules before guest software setup.
# This detects missing prerequisites, not reachability of remote repositories.
use strict;
use warnings;
use Socket qw(AF_INET inet_pton inet_ntop);
use Text::ParseWords qw(shellwords);
use WebminCore qw(read_file_contents execute_command convert_from_json);

# managed(network) identifies libvirt networks whose IPv4 rules we can inspect.
sub managed
{
my ($network) = @_;
return ($network->{'type'} || 'network') eq 'network' &&
	($network->{'forward'} || '') =~ /\A(?:nat|route)\z/ &&
	$network->{'address'};
}

# service_command(action, unit, [failure])
# Runs fixed systemd requests with a timeout.
# failure is an optional scalar reference receiving the failure reason.
sub service_command
{
my ($action, $unit, $failure) = @_;
my ($output, $error);
# libvirtd can spend 30 seconds closing clients before it starts again. Leave
# time for startup instead of ending the wait at the same shutdown deadline.
my $timeout = $action eq 'restart' ? 60 : 5;
my $status = execute_command("/usr/bin/timeout -k 2 $timeout /usr/bin/systemctl $action $unit",
	undef, \$output, \$error);
if ($status && $failure) {
	# Killing systemctl only ends our wait; systemd can still finish the restart.
	if (($status >> 8) == 124 || ($status >> 8) == 137 || $status == 9) {
		$$failure = "Timed out waiting for $unit. The service may still be restarting; check Host Overview before retrying";
	}
	else {
		# Keep command diagnostics short enough for an inline UI error.
		$error = substr($error || '', 0, 1000);
		$error =~ s/\s+/ /g;
		$error =~ s/^\s+|\s+$//g;
		$$failure = "Service command failed for $unit".($error ? ": $error" : '');
	}
}
return $status ? undef : $output // '';
}

# command(program, arguments)
# Reads fixed firewall commands with a five-second deadline; no caller input
# reaches the shell. Returns undef for missing tools, failed commands or output
# over 4 MiB. Callers validate the returned format.
sub command
{
my ($program, $arguments) = @_;
my ($path) = grep { -x $_ } map { "$_/$program" }
	qw(/usr/sbin /usr/bin /sbin /bin);
# Run only when both the tool and its timeout wrapper are available.
return undef if (!$path || !-x '/usr/bin/timeout');
my ($output, $error);
my $status = execute_command("/usr/bin/timeout -k 1 5 $path $arguments",
	undef, \$output, \$error);
return !$status && defined($output) && length($output) <= 4*1024*1024
	? $output : undef;
}

# subnet(network)
# Converts libvirt's IPv4 address and prefix/netmask to a canonical subnet.
sub subnet
{
my ($network) = @_;
my $address = inet_pton(AF_INET, $network->{'address'} || '') || return;
my $prefix = $network->{'prefix'};
# Older network definitions store a netmask instead of a prefix length.
if (!defined($prefix) || $prefix eq '') {
	my $mask = inet_pton(AF_INET, $network->{'netmask'} || '') || return;
	my $bits = unpack('B32', $mask);
	# A non-contiguous netmask cannot describe one IPv4 subnet.
	return if ($bits !~ /\A(1*)0*\z/);
	$prefix = length($1);
}
# Bound the prefix before constructing the packed network mask.
return if ($prefix !~ /\A\d+\z/ || $prefix > 32);
my $mask = pack('B32', ('1' x $prefix).('0' x (32-$prefix)));
return inet_ntop(AF_INET, $address & $mask).'/'.$prefix;
}

1;
