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

1;
