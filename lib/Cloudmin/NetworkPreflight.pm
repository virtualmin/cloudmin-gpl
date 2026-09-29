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

1;
