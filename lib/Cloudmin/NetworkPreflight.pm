package Cloudmin::NetworkPreflight;

# Check libvirt's live IPv4 forwarding rules before guest software setup.
# This detects missing prerequisites, not reachability of remote repositories.
use strict;
use warnings;
use Socket qw(AF_INET inet_pton inet_ntop);
use Text::ParseWords qw(shellwords);
use WebminCore qw(read_file_contents execute_command convert_from_json);

# check(network)
# Rejects missing IPv4 prerequisites on local NAT/routed networks. Bridges,
# isolated networks and IPv6-only networks are outside this check.
sub check
{
my ($network) = @_;
# Leave networks without libvirt-managed IPv4 forwarding to their own checks.
return if (!managed($network));
my $status = status($network, inspect());
# Offer recovery only when inspection identified a missing prerequisite.
die $status->{'detail'}.($status->{'repairable'}
	? '. Open Host Overview and use Restore Network Rules' : '')."\n"
	if (!$status->{'ok'});
}

# managed(network) identifies libvirt networks whose IPv4 rules we can inspect.
sub managed
{
my ($network) = @_;
return ($network->{'type'} || 'network') eq 'network' &&
	($network->{'forward'} || '') =~ /\A(?:nat|route)\z/ &&
	$network->{'address'};
}

# inspect() reads forwarding and firewall state once for all active networks.
sub inspect
{
my $forward = read_file_contents('/proc/sys/net/ipv4/ip_forward') || '';
# Inspect both backends: legacy iptables rules are not visible through nft.
# A failed inspection must not be mistaken for an empty ruleset.
my (@chains, $read);
my $nft = command('nft', '-j list ruleset');
if (defined($nft)) {
	# A successful command alone does not establish that its JSON is usable.
	my $data = eval { convert_from_json($nft) };
	if (ref($data) eq 'HASH' && ref($data->{'nftables'}) eq 'ARRAY') {
		push(@chains, @{nft_chains($data)});
		$read = 1;
	}
}
my $iptables = command('iptables-save', '');
# Accept a readable legacy ruleset even when native nft inspection failed.
if (defined($iptables) && $iptables =~ /^\*(?:filter|nat)$/m) {
	push(@chains, @{iptables_chains($iptables)});
	$read = 1;
}
return { forwarding => $forward =~ /\A1\s*\z/ ? 1 : 0,
	readable => $read ? 1 : 0, chains => \@chains };
}

# status(network, snapshot) returns a displayable result without changing rules.
sub status
{
my ($network, $snapshot) = @_;
my $name = $network->{'name'};
my ($detail, $repairable);
my $subnet = subnet($network);
# Invalid network metadata cannot be repaired by restarting the daemon.
if (!$subnet) {
	$detail = "Cannot check the IPv4 subnet for network $name";
}
elsif (!$snapshot->{'forwarding'}) {
	# Recovery can enable forwarding for managed networks.
	$detail = 'IPv4 forwarding is disabled on the host';
	$repairable = 1;
}
elsif (!$snapshot->{'readable'}) {
	# Do not present an inspection failure as proof that rules are missing.
	$detail = "Cannot read the host firewall rules to check network $name";
}
else {
	# Check rule presence only; arbitrary firewall policies may still block
	# traffic.
	my $missing = missing_rules($network, $subnet, $snapshot->{'chains'});
	$detail = "Network $name is missing $missing" if ($missing);
	$repairable = $missing ? 1 : 0;
}
return { name => $name, id => $network->{'id'}, ok => $detail ? 0 : 1,
	detail => $detail || "IPv4 forwarding rules are present for network $name",
	repairable => $repairable ? 1 : 0 };
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

# nft_chains(document)
# Normalizes the native nftables and iptables-nft forms emitted by libvirt.
sub nft_chains
{
my ($data) = @_;
my %chains;
foreach my $entry (@{$data->{'nftables'}}) {
	my $item = $entry->{'chain'} || $entry->{'rule'} || next;
	# Match libvirt's IPv4 tables; other families are outside this check.
	next if (($item->{'family'} || '') ne 'ip');
	my $name = $item->{'chain'} || $item->{'name'};
	my $id = "nft:$item->{'table'}:$name";
	my $chain = $chains{$id} ||= { id => $id, rules => [] };
	# Chain declarations attach the collected rules to a kernel hook.
	if ($entry->{'chain'}) {
		$chain->{'hook'} = $item->{'hook'} || '';
		next;
	}
	my %rule;
	foreach my $expr (@{$item->{'expr'} || []}) {
		# Only equality matches establish the network or bridge scope.
		my $match = $expr->{'match'};
		if ($match && $match->{'op'} eq '==') {
			my $left = $match->{'left'};
			my $right = $match->{'right'};
			# Normalize address prefixes for exact subnet comparisons.
			if (ref($left) eq 'HASH' && $left->{'payload'} &&
				($left->{'payload'}->{'protocol'} || '') eq 'ip') {
				my $field = $left->{'payload'}->{'field'};
				# nft may encode CIDRs as address/length objects.
				$right = $right->{'prefix'}->{'addr'}.'/'.$right->{'prefix'}->{'len'}
					if (ref($right) eq 'HASH' && $right->{'prefix'});
				# Sets and other expressions do not establish
				# one exact subnet.
				$rule{$field} = $right if (!ref($right));
			}
			# Accept both interface-key spellings used by libvirt.
			if (ref($left) eq 'HASH' && $left->{'meta'}) {
				my $key = $left->{'meta'}->{'key'};
				$key =~ s/name$//;
				# Ignore metadata other than a literal input or
				# output interface.
				$rule{$key} = $right if ($key =~ /\A[io]if\z/ && !ref($right));
			}
		}
		# nft represents argument-free verdicts as null, so test existence.
		$rule{'accept'} = 1 if (exists($expr->{'accept'}));
		# iptables-nft may expose NAT through an xt compatibility
		# target.
		$rule{'nat'} = 1 if (exists($expr->{'masquerade'}) || exists($expr->{'snat'}) ||
			($expr->{'xt'} && ($expr->{'xt'}->{'name'} || '') =~ /\A(?:MASQUERADE|SNAT)\z/));
		my $jump = $expr->{'jump'} || $expr->{'goto'};
		# Track jumps so detached rules cannot count as active rules.
		$rule{'jump'} = "nft:$item->{'table'}:$jump->{'target'}" if ($jump);
	}
	push(@{$chain->{'rules'}}, \%rule);
}
return [values %chains];
}

# iptables_chains(save_output)
# Normalizes iptables-save, including the legacy backend absent from nft JSON.
sub iptables_chains
{
my ($output) = @_;
my (%chains, $table);
foreach my $line (split(/\n/, $output)) {
	# Chain names are local to the table named by the preceding header.
	if ($line =~ /^\*(\w+)$/) {
		$table = $1;
		next;
	}
	# Libvirt's forwarding and source NAT rules use these two legacy tables.
	next if (!$table || $table !~ /\A(?:nat|filter)\z/);
	# Built-in chains have a policy; user-defined chains need a reachable
	# jump.
	if ($line =~ /^:(\S+) (\S+)/) {
		my ($name, $policy) = ($1, $2);
		my $id = "iptables:$table:$name";
		$chains{$id} = { id => $id, rules => [],
			hook => $policy ne '-' ? lc($name) : '' };
		next;
	}
	# Counters, comments and commit markers do not describe packet rules.
	next if ($line !~ /^-A /);
	my @words = shellwords($line);
	my $chain = $chains{"iptables:$table:$words[1]"} || next;
	my %rule;
	my %fields = ('-s' => 'saddr', '-d' => 'daddr', '-i' => 'iif', '-o' => 'oif');
	for (my $i = 2; $i < @words; $i++) {
		my $word = $words[$i];
		# Negated subnets do not establish which network this rule serves.
		if ($fields{$word}) {
			$rule{$fields{$word}} = $words[$i+1] if ($words[$i-1] ne '!');
			$i++;
		}
		elsif ($word eq '-j' || $word eq '-g') {
			# Record verdicts and chain edges without interpreting
			# other options.
			my $target = $words[++$i];
			$rule{'accept'} = 1 if ($target eq 'ACCEPT');
			$rule{'nat'} = 1 if ($target =~ /\A(?:MASQUERADE|SNAT)\z/);
			$rule{'jump'} = "iptables:$table:$target";
		}
	}
	push(@{$chain->{'rules'}}, \%rule);
}
return [values %chains];
}

# hooked_rules(chains, hook)
# Follows chain jumps from a kernel hook; detached chains cannot pass the check.
# This checks rule presence, not ordering or arbitrary administrator policies.
sub hooked_rules
{
my ($chains, $hook) = @_;
my %index = map { $_->{'id'} => $_ } @$chains;
my @pending = grep { ($_->{'hook'} || '') eq $hook } @$chains;
my (%seen, @rules);
while (my $chain = shift(@pending)) {
	# Shared targets and cycles must not make traversal repeat indefinitely.
	next if ($seen{$chain->{'id'}}++);
	push(@rules, @{$chain->{'rules'}});
	push(@pending, map { $index{$_->{'jump'}} || () }
		grep { $_->{'jump'} } @{$chain->{'rules'}});
}
return \@rules;
}

# missing_rules(network, subnet, chains)
# Returns the missing prerequisite, or undef when both directions and any
# required source NAT rules are attached to the packet-processing hooks.
sub missing_rules
{
my ($network, $subnet, $chains) = @_;
my $bridge = $network->{'bridge'} || '';
my $rules = hooked_rules($chains, 'forward');
my $out = grep { $_->{'accept'} && ($_->{'iif'} || '') eq $bridge &&
	($_->{'saddr'} || '') eq $subnet } @$rules;
my $in = grep { $_->{'accept'} && ($_->{'oif'} || '') eq $bridge &&
	($_->{'daddr'} || '') eq $subnet } @$rules;
# Both directions must identify this bridge and its subnet.
return 'IPv4 forwarding rules' if (!$bridge || !$out || !$in);
# Routed networks do not require masquerading or source address translation.
if ($network->{'forward'} eq 'nat') {
	my $nat = hooked_rules($chains, 'postrouting');
	return 'IPv4 NAT rules' if (!grep { $_->{'nat'} &&
		($_->{'saddr'} || '') eq $subnet } @$nat);
}
return undef;
}

1;
