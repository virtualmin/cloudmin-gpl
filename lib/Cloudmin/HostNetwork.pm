package Cloudmin::HostNetwork;

# Persistent host bridge changes use Webmin's network backends. A durable journal,
# boot recovery service and independent timer protect access to the host.
use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use Socket qw(AF_INET6 inet_pton);
use IO::Socket::INET;
use File::Basename qw(dirname);
use WebminCore qw(foreign_require read_file_contents write_file_contents
	make_dir rename_logged unlink_file unflush_file_lines execute_command
	execute_command_logged get_perl_path convert_from_json convert_to_json);
require(dirname(__FILE__).'/HostBridgeRemoval.pm');

# new(class, directory => path, module => path, jobs => object,
#     [client => IP], [confirm_timeout => seconds])
# Creates a bridge manager using directory for its journal and jobs for locking.
# module contains the recovery worker; client identifies the management route.
# Tests can override command() and the backend methods without touching the host.
sub new
{
my ($class, %opts) = @_;
# Invalid hand-edited timeouts retain the three-minute recovery guard.
$opts{'confirm_timeout'} = 180 unless (defined($opts{'confirm_timeout'}) &&
	!ref($opts{'confirm_timeout'}) && $opts{'confirm_timeout'} =~ /\A\d{3}\z/ &&
	$opts{'confirm_timeout'} >= 120 && $opts{'confirm_timeout'} <= 900);
return bless(\%opts, $class);
}

# backend(self)
# Loads the same detected network backend used by Webmin's Network Configuration.
sub backend
{
my ($self) = @_;
foreign_require('net', 'net-lib.pl');
no warnings 'once';
return $net::net_mode;
}

# command(self, argv, [quiet], [safe])
# Runs argv with a 60-second timeout and shell-quotes each argument.
# quiet skips command logging; safe allows a read-only command in demo mode.
sub command
{
my ($self, $argv, $quiet, $safe) = @_;
my $out = '';
my $cmd = join(' ', map { quotemeta($_) } ('timeout', '60', @$argv));
my $rv = $quiet ? execute_command($cmd, undef, \$out, \$out, 0, $safe)
	: execute_command_logged($cmd, undef, \$out, \$out);
die "Network command failed: $out\n" if ($rv);
return $out;
}

# ip_json(self, arguments...)
# Reads structured kernel state where Webmin's interface API omits route tables or ports.
sub ip_json
{
my ($self, @args) = @_;
return convert_from_json($self->command(['ip', '-j', @args], 1, 1), 1);
}

# mask_prefix(self, mask)
# Validates and counts the leading bits in a contiguous IPv4 netmask.
sub mask_prefix
{
my ($self, $mask) = @_;
# Webmin's check_netmask checks IPv4 syntax but accepts noncontiguous masks.
my @parts = split(/\./, $mask || '', -1);
die "Invalid network mask\n" if (@parts != 4 || grep { !/\A\d{1,3}\z/ || $_ > 255 } @parts);
my $bits = unpack('B*', pack('C4', @parts));
die "Invalid network mask\n" if ($bits !~ /\A1*0*\z/);
$bits =~ /\A(1*)/;
return length($1);
}

# inventory(self)
# Reports current addresses, bridge ports and the route used to reach this browser.
sub inventory
{
my ($self) = @_;
my $mode = $self->backend();
my @boot = net::boot_interfaces();
my $links = $self->ip_json('-details', 'address', 'show');
my @routes = (@{$self->ip_json('-4', 'route', 'show', 'table', 'all')},
	@{$self->ip_json('-6', 'route', 'show', 'table', 'all')});
my %management = map { $_->{'dev'} => 1 } grep {
	($_->{'dst'} || '') eq 'default' && $_->{'dev'} } @routes;
# Include a more specific browser route even when it is not the default route.
if (($self->{'client'} || '') =~ /\A[0-9a-fA-F:.]+\z/) {
	my $route = eval { $self->ip_json('route', 'get', $self->{'client'}) };
	$management{$_->{'dev'}} = 1 foreach grep { $_->{'dev'} } @{$route || []};
	}
my @interfaces;
foreach my $link (@$links) {
	# Match persistent settings to live links and omit temporary IPv6 addresses.
	my $name = $link->{'ifname'};
	my ($saved) = grep { ($_->{'fullname'} || '') eq $name } @boot;
	my $kind = $link->{'linkinfo'}->{'info_kind'} || '';
	my @addresses = map { $_->{'local'}.'/'.$_->{'prefixlen'} }
		grep { ($_->{'scope'} || '') ne 'link' && !$_->{'temporary'} } @{$link->{'addr_info'} || []};
	push(@interfaces, { name => $name, bridge => $kind eq 'bridge' ? 1 : 0,
		kind => $kind, active => scalar(grep { $_ eq 'UP' } @{$link->{'flags'} || []}) ? 1 : 0,
		loopback => $link->{'link_type'} eq 'loopback' ? 1 : 0,
		mac => $link->{'address'}, mtu => $link->{'mtu'}, master => $link->{'master'} || '',
		# Local children name their parent; link_index can refer to another namespace.
		parent => $link->{'link'} || '',
		addresses => \@addresses, persistent => $saved ? 1 : 0,
		dynamic_ipv6 => [map { $_->{'local'} } grep {
			($_->{'family'} || '') eq 'inet6' && ($_->{'scope'} || '') eq 'global' &&
			$_->{'dynamic'} && !$_->{'temporary'} } @{$link->{'addr_info'} || []}],
		ports => [map { $_->{'ifname'} } grep { ($_->{'master'} || '') eq $name } @$links],
		management => $management{$name} ? 1 : 0,
		candidate => $saved && !$kind && !$link->{'master'} &&
			$link->{'link_type'} eq 'ether' && !-d "/sys/class/net/$name/wireless" ? 1 : 0 });
	}
my @subnets = map { $_->{'dst'} } grep { ($_->{'dst'} || '') =~ m{/} &&
	($_->{'type'} || '') ne 'local' && $_->{'dst'} !~ m{^fe80:} } @routes;
return { interfaces => \@interfaces, subnets => \@subnets,
	management => [sort keys %management], backend => $mode,
	supported => $mode =~ /\A(?:nm|netplan|debian-linux)\z/ ? 1 : 0 };
}

# read_state(self)
# Loads private journal data; callers must not return the backup fields to a browser.
sub read_state
{
my ($self) = @_;
my $path = "$self->{directory}/bridge.json";
return undef if (!-f $path);
# Keep byte strings intact: saved configuration need not be valid UTF-8.
return convert_from_json(read_file_contents($path), 1);
}

# write_state(self, record)
# Atomically replaces the private transaction journal through Webmin's file API.
sub write_state
{
my ($self, $record) = @_;
make_dir($self->{'directory'}, 0700, 1);
my $mask = umask(0077);
write_file_contents("$self->{directory}/bridge.json", convert_to_json($record, 0, 0, 1));
umask($mask);
}

# pending(self)
# Includes failed rollback, which must be resolved before further mutations.
sub pending
{
my ($self) = @_;
my $state = $self->read_state();
return $state && $state->{'state'} =~ /\A(?:armed|applying|confirm|rollback_failed)\z/ ? $state : undef;
}

# public_state(self)
# Exposes progress and identity only, never saved host configuration or credentials.
sub public_state
{
my ($self) = @_;
# No journal means there is no bridge progress to expose.
my $state = $self->read_state() || return undef;
my $restoring;
# A retry leaves the failed journal intact until it finishes. Read the worker's
# job too, so the page shows progress as soon as systemd accepts the request.
if ($state->{'state'} =~ /\A(?:armed|applying|confirm|rollback_failed)\z/) {
	my $unit = eval { $self->command(['systemctl', 'show',
		'cloudmin-network-rollback.service', '--property=ActiveState,Job'], 1, 1) } || '';
	$restoring = $unit =~ /^ActiveState=(?:activating|active|deactivating)$/m ||
		$unit =~ /^Job=[1-9]\d*(?:\s|$)/m;
	# The worker may have finished while systemd was being queried.
	$state = $self->read_state() || return undef;
	}
my $public = { map { $_ => $state->{$_} } qw(id name source operation owner state deadline error management) };
if ($restoring && $state->{'state'} =~ /\A(?:armed|applying|confirm|rollback_failed)\z/) {
	# Hide the prior failure while its retry is still running. A stopped
	# or failed worker exposes it again instead of leaving an endless spinner.
	$public->{'state'} = 'rolling_back';
	delete($public->{'error'});
	}
return $public;
}

# snapshot(self, paths)
# Saves exact contents and ownership for the files a backend will change.
sub snapshot
{
my ($self, $paths) = @_;
my %files;
foreach my $path (@$paths) {
	next if (exists($files{$path}));
	die "Network configuration must use ordinary files: $path\n" if (-l $path || (-e $path && !-f $path));
	my @st = stat($path);
	$files{$path} = @st ? { content => read_file_contents($path),
		mode => $st[2] & 07777, uid => $st[4], gid => $st[5] } : undef;
	}
return \%files;
}

# netplan_dhcp4_identity(self, source, mac)
# Returns networkd settings that keep source's identity and request its lease.
# mac is the MAC retained by the destination; callers must have an IPv4 lease.
sub netplan_dhcp4_identity
{
my ($self, $source, $mac) = @_;
my $status = eval { convert_from_json(
	$self->command(['networkctl', '--json=short', 'status', $source], 1), 1) };
my $id = ref($status) eq 'HASH' && ref($status->{'DHCPv4Client'}) eq 'HASH'
	? $status->{'DHCPv4Client'}->{'ClientIdentifier'} : undef;
# Reject missing or malformed client bytes before generating native settings.
die "Cannot preserve this interface's DHCP identity; configure its bridge in Webmin Network Configuration\n"
	if (ref($id) ne 'ARRAY' || !@$id || grep { !defined($_) || ref($_) || !/\A\d+\z/ || $_ > 255 } @$id);
# A server may forget a released lease. Identity alone does not tell the new
# client which address to request; copy only the address supplied by DHCP.
my @leases = grep { ref($_) eq 'HASH' && ($_->{'ConfigSource'} || '') eq 'DHCPv4' &&
	($_->{'ConfigState'} || '') eq 'configured' } @{$status->{'Addresses'} || []};
my $address = @leases == 1 ? $leases[0]->{'Address'} : undef;
# A single DHCP address is required to choose an unambiguous lease request.
die "Cannot read the current DHCPv4 address for $source; configure its bridge in Webmin Network Configuration\n"
	if (ref($address) ne 'ARRAY' || @$address != 4 ||
		grep { !defined($_) || ref($_) || !/\A\d+\z/ || $_ > 255 } @$address);
my $request = 'RequestAddress='.join('.', @$address)."\n";
if ($id->[0] == 1 && @$id == 7 &&
	join(':', map { sprintf('%02x', $_) } @$id[1..6]) eq lc($mac)) {
	# MAC-based clients keep their identity without switching to a DUID.
	return "[DHCPv4]\nClientIdentifier=mac\n".$request;
	}
# Other supported clients encode an IAID and DUID after the type byte.
die "Unsupported DHCP client identity; configure its bridge in Webmin Network Configuration\n"
	if ($id->[0] != 255 || @$id < 8);
# RFC 4361 combines a four-byte interface ID with the DHCP unique identifier.
my $iaid = unpack('N', pack('C*', @$id[1..4]));
my $type = unpack('n', pack('C*', @$id[5..6]));
my $duid = join(':', map { sprintf('%02x', $_) } @$id[7..$#$id]);
return "[DHCPv4]\nClientIdentifier=duid\nIAID=$iaid\nDUIDType=$type\nDUIDRawData=$duid\n".$request;
}

# nm_dhcp4_identity(self, source)
# Reads the active lease's client ID, including generated and global defaults.
sub nm_dhcp4_identity
{
my ($self, $source) = @_;
my $options = $self->command(['nmcli', '--terse', '--mode', 'multiline',
	'--escape', 'no', '--fields', 'DHCP4.OPTION', 'device', 'show', $source], 1, 1);
# Without a lease, an absent ID could mean DHCP has not completed yet.
die "Cannot read the current DHCPv4 lease for $source; configure its bridge in Webmin Network Configuration\n"
	if ($options !~ /^DHCP4\.OPTION\[\d+\]:ip_address = \d+\.\d+\.\d+\.\d+\s*$/m);
my @ids = $options =~ /^DHCP4\.OPTION\[\d+\]:dhcp_client_identifier = ([^\r\n]*)/mg;
# NetworkManager omits the option when the client sends no identifier.
return 'none' if (!@ids);
die "Cannot preserve the DHCPv4 client ID for $source; configure its bridge in Webmin Network Configuration\n"
	if (@ids != 1 || $ids[0] !~ /\A[0-9a-f]{2}(?::[0-9a-f]{2}){1,254}\z/i);
return lc($ids[0]);
}

# check_ipv6_identity(self, interface, [token])
# Checks live dynamic IPv6 addresses against the preserved MAC or SLAAC token.
# Other generated identifiers may change when addressing moves to a bridge.
sub check_ipv6_identity
{
my ($self, $live, $token) = @_;
my $packed = $token ? inet_pton(AF_INET6, $token) : undef;
my @mac = map { hex($_) } split(/:/, $live->{'mac'});
my $iid = $packed ? substr($packed, 8) : @mac == 6
	? pack('C8', $mac[0] ^ 2, @mac[1,2], 255, 254, @mac[3..5]) : undef;
foreach my $address (@{$live->{'dynamic_ipv6'} || []}) {
	# Refuse before applying settings that cannot reproduce a host address.
	my $ip = inet_pton(AF_INET6, $address);
	die "This interface has automatically generated IPv6 addresses that cannot be preserved on a new bridge. Configure the bridge and its IPv6 addresses in Webmin Network Configuration\n"
		if (!$iid || !$ip || substr($ip, 8) ne $iid);
	}
}

# ipv6_address_mode(self, device)
# Reads the named device's IPv6 generation mode, or undef if it is not exposed.
sub ipv6_address_mode
{
my ($self, $device) = @_;
my $links = $self->ip_json('-details', 'link', 'show', 'dev', $device);
my $mode = $links->[0]->{'inet6_addr_gen_mode'};
# Do not pass an unrecognized kernel value into a later ip link command.
die "Cannot read IPv6 address generation mode for $device\n"
	if (defined($mode) && $mode !~ /\A(?:eui64|none|stable_secret|random)\z/);
return $mode;
}

# prepare(self, name, source)
# Captures a bridge conversion plan, rejecting topology that cannot be preserved.
sub prepare
{
my ($self, $name, $source) = @_;
Cloudmin::Networks::name($name);
Cloudmin::Networks::name($source);
die "Bridge names beginning with virbr are reserved for libvirt\n" if ($name =~ /^virbr/);
my $inventory = $self->inventory();
die "Bridge setup is unavailable for this host's network backend\n" if (!$inventory->{'supported'});
my @boot = net::boot_interfaces();
die "That interface name already exists\n" if (grep { $_->{'name'} eq $name }
	(@{$inventory->{'interfaces'}}, @boot));
my ($live) = grep { $_->{'name'} eq $source && $_->{'candidate'} } @{$inventory->{'interfaces'}};
die "Choose a standalone, persistently configured Ethernet interface\n" if (!$live);
my @saved = grep { ($_->{'fullname'} || '') eq $source } @boot;
die "The interface must have exactly one persistent configuration\n" if (@saved != 1);
die "Move additional interface aliases manually before creating a bridge\n"
	if (grep { $_->{'name'} eq $source && defined($_->{'virtual'}) && $_->{'virtual'} ne '' } @boot);
my $saved = $saved[0];
my $mode = $inventory->{'backend'};
# Include the timeout in the review hash so a changed setting requires review.
my $plan = { name => $name, source => $source, mode => $mode,
	confirm_timeout => 0 + $self->{'confirm_timeout'},
	management => $live->{'management'}, mac => $live->{'mac'}, saved => $saved,
	addresses => $live->{'addresses'}, client => $self->{'client'} };
my @files = ($saved->{'file'});
if ($mode eq 'debian-linux') {
	# ifupdown needs bridge-utils and stanzas that can move without shell hooks.
	die "Install bridge-utils before creating a persistent bridge on this host\n"
		if (!WebminCore::has_command('brctl'));
	my @defs = grep { $_->[0] eq $source } net::get_interface_defs();
	# Shell hooks can refer to the old device name and cannot be moved blindly.
	die "This interface has custom hooks or unsupported address methods; configure its bridge in Webmin Network Configuration\n"
		if (grep { $_->[2] !~ /\A(?:static|dhcp|auto|manual)\z/ ||
			grep { $_->[0] =~ /^(?:pre-|post-)?(?:up|down)$/ || $_->[0] =~ /^(?:bond|bridge|vlan)/ }
			@{$_->[3]} } @defs);
	$plan->{'defs'} = \@defs;
	$plan->{'ipv6_address_mode'} = $self->ipv6_address_mode($source);
	no warnings 'once';
	push(@files, $net::network_interfaces_config, map { $_->[4] } @defs);
	}
elsif ($mode eq 'netplan') {
	# Keep physical matching/renaming on the NIC, moving only IP configuration.
	my %allowed = map { $_ => 1 } qw(match set-name renderer optional dhcp4 dhcp6
		dhcp4-overrides dhcp6-overrides accept-ra addresses gateway4 gateway6 nameservers
		macaddress mtu routes routing-policy link-local ipv6-privacy ipv6-address-generation
		ipv6-address-token dhcp-identifier critical optional-addresses);
	die "This interface has unsupported Netplan options; configure its bridge in Webmin Network Configuration\n"
		if (grep { !$allowed{$_->{'name'}} } @{$saved->{'yaml'}->{'members'} || []});
	# Copying DHCPv6 or stable-privacy settings may change their addresses.
	my ($entry) = grep { $_->{'name'} eq 'ipv6-address-token' }
		@{$saved->{'yaml'}->{'members'} || []};
	# Webmin's YAML reader retains scalar quotes and trailing whitespace.
	my $token = $entry ? $entry->{'value'} : '';
	$token =~ s/^\s*(['"]?)(.*?)\1\s*$/$2/;
	$self->check_ipv6_identity($live, $token);
	no warnings 'once';
	$plan->{'api_file'} = "$net::netplan_dir/$name.yaml";
	# Netplan resolves bridge ports in file order. Place the final bridge file
	# after the file defining its Ethernet port, even with custom file names.
	$plan->{'new_file'} = $saved->{'file'}.".cloudmin-$name.yaml";
	die "A configuration file for this bridge already exists\n" if (-e $plan->{'api_file'});
	push(@files, $plan->{'api_file'}, $plan->{'new_file'});
	if ($saved->{'dhcp'} && grep { /^\d+\./ } @{$live->{'addresses'}}) {
		# Preserve the active IPv4 lease through a journaled networkd drop-in:
		# Netplan cannot set its IAID. IPv6-only links skip this step.
		$plan->{'dhcp4_identity'} = $self->netplan_dhcp4_identity($source, $live->{'mac'});
		my $directory = $self->{'networkd_directory'} || '/etc/systemd/network';
		$plan->{'dhcp4_directory'} = "$directory/10-netplan-$name.network.d";
		$plan->{'dhcp4_dropin'} = "$plan->{dhcp4_directory}/90-cloudmin-dhcp.conf";
		die "Network configuration for this bridge already exists\n" if (-e $plan->{'dhcp4_directory'});
		push(@files, $plan->{'dhcp4_dropin'});
		}
	}
else {
	# NetworkManager converts a plain Ethernet profile into a bridge port.
	my $cfg = $saved->{'cfg'};
	my $type = net::find_nm_config($cfg, 'connection', 'type') || '';
	die "Choose a plain NetworkManager Ethernet connection\n" if ($type !~ /\A(?:ethernet|802-3-ethernet)\z/ ||
		net::find_nm_config($cfg, 'connection', 'master') || net::find_nm_config($cfg, 'connection', 'controller'));
	die "This connection uses authentication or advanced Ethernet settings; configure its bridge in Webmin Network Configuration\n"
		# Cloud-init's origin metadata stays on the existing Ethernet profile.
		if (grep { $_->{'sect'} !~ /\A(?:connection|ethernet|802-3-ethernet|ipv4|ipv6|proxy|user)\z/ } @$cfg);
	$plan->{'uuid'} = net::find_nm_config($cfg, 'connection', 'uuid');
	die "NetworkManager connection UUID is missing\n" if (!$plan->{'uuid'});
	# Generated addresses must survive the profile and interface name change.
	$self->check_ipv6_identity($live, net::find_nm_config($cfg, 'ipv6', 'token'));
	# Preserve the active IPv4 lease. Unaddressed ports have no lease to retain.
	$plan->{'dhcp4_client_id'} = $self->nm_dhcp4_identity($source)
		if ($saved->{'dhcp'} && grep { /^\d+\./ } @{$live->{'addresses'} || []});
	no warnings 'once';
	$plan->{'new_file'} = "$net::nm_conn_dir/cloudmin-$name.nmconnection";
	push(@files, $plan->{'new_file'});
	}
die "A configuration file for this bridge already exists\n" if ($plan->{'new_file'} && -e $plan->{'new_file'});
$plan->{'files'} = $self->snapshot(\@files);
$plan->{'revision'} = sha256_hex(convert_to_json($plan, 0, 0, 1));
return $plan;
}

1;
