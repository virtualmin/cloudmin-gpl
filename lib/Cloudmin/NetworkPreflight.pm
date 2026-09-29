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

1;
