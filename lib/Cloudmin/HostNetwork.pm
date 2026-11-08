package Cloudmin::HostNetwork;

# Persistent host bridge changes use Webmin's network backends. A durable
# journal, boot recovery service and independent timer
# protect access to the host.
use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use Socket qw(AF_INET6 inet_pton);
use IO::Socket::INET;
use File::Basename qw(dirname);
use WebminCore qw(foreign_require read_file_contents write_file_contents
	make_dir rename_logged unlink_file unflush_file_lines execute_command
	execute_command_logged get_perl_path convert_from_json convert_to_json
	substitute_template);
require(dirname(__FILE__).'/HostBridgeRemoval.pm');

# new(class, directory => path, module => path, jobs => object,
#     [client => IP], [confirm_timeout => seconds])
# Creates a bridge manager using directory for its journal and jobs for locking.
# module contains the recovery worker; client identifies the management route.
# Tests can override command() and the backend methods
# without touching the host.
sub new
{
my ($class, %opts) = @_;
# Invalid hand-edited timeouts retain the three-minute recovery guard.
$opts{'confirm_timeout'} = 180 unless (defined($opts{'confirm_timeout'}) &&
				       !ref($opts{'confirm_timeout'}) &&
				       $opts{'confirm_timeout'} =~ /\A\d{3}\z/ &&
				       $opts{'confirm_timeout'} >= 120 && $opts{'confirm_timeout'} <= 900);
return bless(\%opts, $class);
}

# backend(self) Loads the same detected network backend used by Webmin's
# Network Configuration.
sub backend
{
my ($self) = @_;
foreign_require('net', 'net-lib.pl');
no warnings 'once';
return $net::net_mode;
}

# command(self, argv, [quiet], [safe]) Runs argv with a 60-second timeout and
# shell-quotes each argument. quiet skips command logging; safe allows a
# read-only command in demo mode.
sub command
{
my ($self, $argv, $quiet, $safe) = @_;
my $out = '';
my $cmd = join(' ', map { quotemeta($_) } ( 'timeout', '60', @$argv ));
my $rv = $quiet
	? execute_command($cmd, undef, \$out, \$out, 0, $safe)
	: execute_command_logged($cmd, undef, \$out, \$out);
die "Network command failed: $out\n" if ($rv);
return $out;
}

# ip_json(self, arguments...) Reads structured kernel state where Webmin's
# interface API omits route tables or ports.
sub ip_json
{
my ($self, @args) = @_;
return convert_from_json($self->command([ 'ip', '-j', @args ], 1, 1), 1);
}

# mask_prefix(self, mask) Validates and counts the leading bits in a
# contiguous IPv4 netmask.
sub mask_prefix
{
my ($self, $mask) = @_;
# Webmin's check_netmask checks IPv4 syntax but accepts noncontiguous masks.
my @parts = split(/\./, $mask || '', -1);
die "Invalid network mask\n"
	if (@parts != 4 || grep { !/\A\d{1,3}\z/ || $_ > 255 } @parts);
my $bits = unpack('B*', pack('C4', @parts));
die "Invalid network mask\n" if ($bits !~ /\A1*0*\z/);
$bits =~ /\A(1*)/;
return length($1);
}

# inventory(self) Reports current addresses, bridge ports and the route used
# to reach this browser.
sub inventory
{
my ($self) = @_;
my $mode = $self->backend();
my @boot = net::boot_interfaces();
my $links = $self->ip_json('-details', 'address', 'show');
my @routes = ( @{$self->ip_json('-4', 'route', 'show', 'table', 'all')},
	       @{$self->ip_json('-6', 'route', 'show', 'table', 'all')} );
my %management = map { $_->{'dev'} => 1 } grep {
	($_->{'dst'} || '') eq 'default' && $_->{'dev'} } @routes;
# Include a more specific browser route even when it is not the default route.
if (($self->{'client'} || '') =~ /\A[0-9a-fA-F:.]+\z/) {
	my $route = eval { $self->ip_json('route', 'get', $self->{'client'}) };
	$management{$_->{'dev'}} = 1 foreach grep { $_->{'dev'} } @{$route ||
		[ ]};
	}
my @interfaces;
foreach my $link (@$links) {
	# Match persistent settings to live links and omit
	# temporary IPv6 addresses.
	my $name = $link->{'ifname'};
	my ($saved) = grep { ($_->{'fullname'} || '') eq $name } @boot;
	my $kind = $link->{'linkinfo'}->{'info_kind'} || '';
	my @addresses = map { $_->{'local'}.'/'.$_->{'prefixlen'} }
			grep { ($_->{'scope'} || '') ne 'link' &&
			!$_->{'temporary'} } @{$link->{'addr_info'} || [ ]};
	push(@interfaces, { name => $name, bridge => $kind eq 'bridge' ? 1 : 0,
			    kind => $kind, active =>
						   scalar(grep { $_ eq 'UP' } @{$link->{'flags'} || [ ]})
							   ? 1
							   : 0,
			    loopback => $link->{'link_type'} eq 'loopback'
				    ? 1
				    : 0,
			    mac => $link->{'address'}, mtu => $link->{'mtu'},
			    master => $link->{'master'} || '',
		# Local children name their parent; link_index can refer
			    # to another namespace.
			    parent => $link->{'link'} || '',
			    addresses => \@addresses, persistent => $saved
				    ? 1
				    : 0,
			    dynamic_ipv6 => [ map { $_->{'local'} } grep {
			($_->{'family'} || '') eq 'inet6' &&
				($_->{'scope'} || '') eq 'global' &&
				$_->{'dynamic'} &&
				!$_->{'temporary'} } @{$link->{'addr_info'} ||
					[ ]} ],
			    ports =>
				    [ map { $_->{'ifname'} } grep { ($_->{'master'} ||
								     '') eq $name } @$links ],
			    management => $management{$name} ? 1 : 0,
			    candidate => $saved && !$kind && !$link->{'master'} &&
					 $link->{'link_type'} eq 'ether' &&
					 !-d "/sys/class/net/$name/wireless"
						 ? 1
						 : 0 });
	}
my @subnets = map { $_->{'dst'} } grep { ($_->{'dst'} || '') =~ m{/} &&
	($_->{'type'} || '') ne 'local' &&
	$_->{'dst'} !~ m{^fe80:} } @routes;
return { interfaces => \@interfaces, subnets => \@subnets,
	 management => [ sort keys %management ], backend => $mode,
	 supported => $mode =~ /\A(?:nm|netplan|debian-linux)\z/ ? 1 : 0 };
}

# read_state(self) Loads private journal data; callers must not return the
# backup fields to a browser.
sub read_state
{
my ($self) = @_;
my $path = "$self->{directory}/bridge.json";
return undef if (!-f $path);
# Keep byte strings intact: saved configuration need not be valid UTF-8.
return convert_from_json(read_file_contents($path), 1);
}

# write_state(self, record) Atomically replaces the private transaction journal
# through Webmin's file API.
sub write_state
{
my ($self, $record) = @_;
make_dir($self->{'directory'}, 0700, 1);
my $mask = umask(0077);
write_file_contents("$self->{directory}/bridge.json",
		    convert_to_json($record, 0, 0, 1));
umask($mask);
}

# pending(self) Includes failed rollback, which must be resolved
# before further mutations.
sub pending
{
my ($self) = @_;
my $state = $self->read_state();
return $state &&
       $state->{'state'} =~ /\A(?:armed|applying|confirm|rollback_failed)\z/
	       ? $state
	       : undef;
}

# public_state(self) Exposes progress and identity only, never saved host
# configuration or credentials.
sub public_state
{
my ($self) = @_;
# No journal means there is no bridge progress to expose.
my $state = $self->read_state() || return undef;
my $restoring;
# A retry leaves the failed journal intact until it finishes. Read the worker's
# job too, so the page shows progress as soon as systemd accepts the request.
if ($state->{'state'} =~ /\A(?:armed|applying|confirm|rollback_failed)\z/) {
	my $unit = eval { $self->command([ 'systemctl', 'show',
					   'cloudmin-network-rollback.service',
					   '--property=ActiveState,Job' ], 1,
					 1) } || '';
	$restoring =
		$unit =~ /^ActiveState=(?:activating|active|deactivating)$/m ||
		$unit =~ /^Job=[1-9]\d*(?:\s|$)/m;
	# The worker may have finished while systemd was being queried.
	$state = $self->read_state() || return undef;
	}
my $public =
	{ map { $_ =>
		$state->{$_} } qw(id name source operation owner state deadline error management) };
if ($restoring &&
    $state->{'state'} =~ /\A(?:armed|applying|confirm|rollback_failed)\z/) {
	# Hide the prior failure while its retry is still running. A stopped or
	# failed worker exposes it again instead of leaving an endless spinner.
	$public->{'state'} = 'rolling_back';
	delete($public->{'error'});
	}
return $public;
}

# snapshot(self, paths) Saves exact contents and ownership for the files a
# backend will change.
sub snapshot
{
my ($self, $paths) = @_;
my %files;
foreach my $path (@$paths) {
	next if (exists($files{$path}));
	die "Network configuration must use ordinary files: $path\n"
		if (-l $path || (-e $path && !-f $path));
	my @st = stat($path);
	$files{$path} = @st
		? { content => read_file_contents($path),
		    mode => $st[2] & 07777, uid => $st[4], gid => $st[5] }
		: undef;
	}
return \%files;
}

# netplan_dhcp4_identity(self, source, mac) Returns networkd settings that keep
# source's identity and request its lease. mac is the MAC retained by the
# destination; callers must have an IPv4 lease.
sub netplan_dhcp4_identity
{
my ($self, $source, $mac) = @_;
my $status = eval { convert_from_json(
	$self->command([ 'networkctl', '--json=short', 'status',
			 $source ], 1), 1) };
my $id = ref($status) eq 'HASH' && ref($status->{'DHCPv4Client'}) eq 'HASH'
	? $status->{'DHCPv4Client'}->{'ClientIdentifier'}
	: undef;
# Reject missing or malformed client bytes before generating native settings.
die "Cannot preserve this interface's DHCP identity; configure its bridge in Webmin Network Configuration\n"
	if (ref($id) ne 'ARRAY' || !@$id || grep { !defined($_) || ref($_) ||
		!/\A\d+\z/ || $_ > 255 } @$id);
# A server may forget a released lease. Identity alone does not tell the new
# client which address to request; copy only the address supplied by DHCP.
my @leases =
	grep { ref($_) eq 'HASH' && ($_->{'ConfigSource'} || '') eq 'DHCPv4' &&
		($_->{'ConfigState'} ||
		 '') eq 'configured' } @{$status->{'Addresses'} || [ ]};
my $address = @leases == 1 ? $leases[0]->{'Address'} : undef;
# A single DHCP address is required to choose an unambiguous lease request.
die "Cannot read the current DHCPv4 address for $source; configure its bridge in Webmin Network Configuration\n"
	if (ref($address) ne 'ARRAY' || @$address != 4 ||
	    grep { !defined($_) || ref($_) || !/\A\d+\z/ ||
			$_ > 255 } @$address);
my $request = 'RequestAddress='.join('.', @$address)."\n";
if ($id->[0] == 1 && @$id == 7 &&
    join(':', map { sprintf('%02x', $_) } @$id[1 .. 6]) eq lc($mac)) {
	# MAC-based clients keep their identity without switching to a DUID.
	return "[DHCPv4]\nClientIdentifier=mac\n".$request;
	}
# Other supported clients encode an IAID and DUID after the type byte.
die "Unsupported DHCP client identity; configure its bridge in Webmin Network Configuration\n"
	if ($id->[0] != 255 || @$id < 8);
# RFC 4361 combines a four-byte interface ID with the DHCP unique identifier.
my $iaid = unpack('N', pack('C*', @$id[1 .. 4]));
my $type = unpack('n', pack('C*', @$id[5 .. 6]));
my $duid = join(':', map { sprintf('%02x', $_) } @$id[7 .. $#$id]);
return "[DHCPv4]\nClientIdentifier=duid\nIAID=$iaid\nDUIDType=$type\nDUIDRawData=$duid\n".$request;
}

# nm_dhcp4_identity(self, source) Reads the active lease's client ID, including
# generated and global defaults.
sub nm_dhcp4_identity
{
my ($self, $source) = @_;
my $options = $self->command([ 'nmcli', '--terse', '--mode', 'multiline',
			       '--escape', 'no', '--fields', 'DHCP4.OPTION',
			       'device', 'show',
			       $source ], 1, 1);
# Without a lease, an absent ID could mean DHCP has not completed yet.
die "Cannot read the current DHCPv4 lease for $source; configure its bridge in Webmin Network Configuration\n"
	if (
		$options !~ /^DHCP4\.OPTION\[\d+\]:ip_address = \d+\.\d+\.\d+\.\d+\s*$/m);
my @ids =
	$options =~ /^DHCP4\.OPTION\[\d+\]:dhcp_client_identifier = ([^\r\n]*)/mg;
# NetworkManager omits the option when the client sends no identifier.
return 'none' if (!@ids);
die "Cannot preserve the DHCPv4 client ID for $source; configure its bridge in Webmin Network Configuration\n"
	if (@ids != 1 || $ids[0] !~ /\A[0-9a-f]{2}(?::[0-9a-f]{2}){1,254}\z/i);
return lc($ids[0]);
}

# check_ipv6_identity(self, interface, [token]) Checks live dynamic IPv6
# addresses against the preserved MAC or SLAAC token. Other generated
# identifiers may change when addressing moves to a bridge.
sub check_ipv6_identity
{
my ($self, $live, $token) = @_;
my $packed = $token ? inet_pton(AF_INET6, $token) : undef;
my @mac = map { hex($_) } split(/:/, $live->{'mac'});
my $iid = $packed
	? substr($packed, 8)
	: @mac == 6
		? pack('C8', $mac[0] ^ 2, @mac[1, 2], 255, 254, @mac[3 .. 5])
		: undef;
foreach my $address (@{$live->{'dynamic_ipv6'} || [ ]}) {
	# Refuse before applying settings that cannot reproduce a host address.
	my $ip = inet_pton(AF_INET6, $address);
	die "This interface has automatically generated IPv6 addresses that cannot be preserved on a new bridge. Configure the bridge and its IPv6 addresses in Webmin Network Configuration\n"
		if (!$iid || !$ip || substr($ip, 8) ne $iid);
	}
}

# ipv6_address_mode(self, device) Reads the named device's IPv6 generation mode,
# or undef if it is not exposed.
sub ipv6_address_mode
{
my ($self, $device) = @_;
my $links = $self->ip_json('-details', 'link', 'show', 'dev', $device);
my $mode = $links->[0]->{'inet6_addr_gen_mode'};
# Do not pass an unrecognized kernel value into a later ip link command.
die "Cannot read IPv6 address generation mode for $device\n"
	if (defined($mode) &&
	    $mode !~ /\A(?:eui64|none|stable_secret|random)\z/);
return $mode;
}

# prepare(self, name, source) Captures a bridge conversion plan, rejecting
# topology that cannot be preserved.
sub prepare
{
my ($self, $name, $source) = @_;
Cloudmin::Networks::name($name);
Cloudmin::Networks::name($source);
die "Bridge names beginning with virbr are reserved for libvirt\n"
	if ($name =~ /^virbr/);
my $inventory = $self->inventory();
die "Bridge setup is unavailable for this host's network backend\n"
	if (!$inventory->{'supported'});
my @boot = net::boot_interfaces();
die "That interface name already exists\n" if (grep { $_->{'name'} eq $name }
					       ( @{$inventory->{'interfaces'}},
						 @boot ));
my ($live) =
	grep { $_->{'name'} eq $source &&
		$_->{'candidate'} } @{$inventory->{'interfaces'}};
die "Choose a standalone, persistently configured Ethernet interface\n"
	if (!$live);
my @saved = grep { ($_->{'fullname'} || '') eq $source } @boot;
die "The interface must have exactly one persistent configuration\n"
	if (@saved != 1);
die "Move additional interface aliases manually before creating a bridge\n"
	if (grep { $_->{'name'} eq $source && defined($_->{'virtual'}) &&
		$_->{'virtual'} ne '' } @boot);
my $saved = $saved[0];
my $mode = $inventory->{'backend'};
# Include the timeout in the review hash so a changed setting requires review.
my $plan = { name => $name, source => $source, mode => $mode,
	     confirm_timeout => 0 + $self->{'confirm_timeout'},
	     management => $live->{'management'}, mac => $live->{'mac'},
	     saved =>
		     $saved,
	     addresses => $live->{'addresses'}, client => $self->{'client'} };
my @files = ($saved->{'file'});
if ($mode eq 'debian-linux') {
	# ifupdown needs bridge-utils and stanzas that can move
	# without shell hooks.
	die "Install bridge-utils before creating a persistent bridge on this host\n"
		if (!WebminCore::has_command('brctl'));
	my @defs = grep { $_->[0] eq $source } net::get_interface_defs();
	# Shell hooks can refer to the old device name and
	# cannot be moved blindly.
	die "This interface has custom hooks or unsupported address methods; configure its bridge in Webmin Network Configuration\n"
		if (grep { $_->[2] !~ /\A(?:static|dhcp|auto|manual)\z/ ||
			grep { $_->[0] =~ /^(?:pre-|post-)?(?:up|down)$/ ||
				$_->[0] =~ /^(?:bond|bridge|vlan)/ }
			@{$_->[3]} } @defs);
	$plan->{'defs'} = \@defs;
	$plan->{'ipv6_address_mode'} = $self->ipv6_address_mode($source);
	no warnings 'once';
	push(@files, $net::network_interfaces_config, map { $_->[4] } @defs);
	}
elsif ($mode eq 'netplan') {
	# Keep physical matching/renaming on the NIC, moving
	# only IP configuration.
	my %allowed =
		map { $_ => 1 } qw(match set-name renderer optional dhcp4 dhcp6
		dhcp4-overrides dhcp6-overrides accept-ra addresses gateway4 gateway6 nameservers
		macaddress mtu routes routing-policy link-local ipv6-privacy ipv6-address-generation
		ipv6-address-token dhcp-identifier critical optional-addresses);
	die "This interface has unsupported Netplan options; configure its bridge in Webmin Network Configuration\n"
		if (
			grep { !$allowed{$_->{'name'}} } @{
				$saved->{'yaml'}->{'members'} || [ ]});
	# Copying DHCPv6 or stable-privacy settings may change their addresses.
	my ($entry) = grep { $_->{'name'} eq 'ipv6-address-token' }
		      @{$saved->{'yaml'}->{'members'} || [ ]};
	# Webmin's YAML reader retains scalar quotes and trailing whitespace.
	my $token = $entry ? $entry->{'value'} : '';
	$token =~ s/^\s*(['"]?)(.*?)\1\s*$/$2/;
	$self->check_ipv6_identity($live, $token);
	no warnings 'once';
	$plan->{'api_file'} = "$net::netplan_dir/$name.yaml";
	# Netplan resolves bridge ports in file order. Place the final bridge
	# file after the file defining its Ethernet port, even
	# with custom file names.
	$plan->{'new_file'} = $saved->{'file'}.".cloudmin-$name.yaml";
	die "A configuration file for this bridge already exists\n"
		if (-e $plan->{'api_file'});
	push(@files, $plan->{'api_file'}, $plan->{'new_file'});
	if ($saved->{'dhcp'} && grep { /^\d+\./ } @{$live->{'addresses'}}) {
		# Preserve the active IPv4 lease through a journaled networkd
		# drop-in: Netplan cannot set its IAID. IPv6-only
		# links skip this step.
		$plan->{'dhcp4_identity'} =
			$self->netplan_dhcp4_identity($source, $live->{'mac'});
		my $directory = $self->{'networkd_directory'} ||
				'/etc/systemd/network';
		$plan->{'dhcp4_directory'} =
			"$directory/10-netplan-$name.network.d";
		$plan->{'dhcp4_dropin'} =
			"$plan->{dhcp4_directory}/90-cloudmin-dhcp.conf";
		die "Network configuration for this bridge already exists\n"
			if (-e $plan->{'dhcp4_directory'});
		push(@files, $plan->{'dhcp4_dropin'});
		}
	}
else {
	# NetworkManager converts a plain Ethernet profile into a bridge port.
	my $cfg = $saved->{'cfg'};
	my $type = net::find_nm_config($cfg, 'connection', 'type') || '';
	die "Choose a plain NetworkManager Ethernet connection\n" if (
		$type !~ /\A(?:ethernet|802-3-ethernet)\z/ ||
		net::find_nm_config($cfg, 'connection', 'master') ||
		net::find_nm_config($cfg, 'connection', 'controller'));
	die "This connection uses authentication or advanced Ethernet settings; configure its bridge in Webmin Network Configuration\n"
	# Cloud-init's origin metadata stays on the existing Ethernet profile.
		if (grep {
			$_->{'sect'} !~ /\A(?:connection|ethernet|802-3-ethernet|ipv4|ipv6|proxy|user)\z/ } @$cfg);
	$plan->{'uuid'} = net::find_nm_config($cfg, 'connection', 'uuid');
	die "NetworkManager connection UUID is missing\n" if (!$plan->{'uuid'});
	# Generated addresses must survive the profile and
	# interface name change.
	$self->check_ipv6_identity($live,
				   net::find_nm_config($cfg, 'ipv6', 'token'));
	# Preserve the active IPv4 lease. Unaddressed ports
	# have no lease to retain.
	$plan->{'dhcp4_client_id'} = $self->nm_dhcp4_identity($source)
		if ($saved->{'dhcp'} &&
		    grep { /^\d+\./ } @{$live->{'addresses'} ||
				[ ]});
	no warnings 'once';
	$plan->{'new_file'} = "$net::nm_conn_dir/cloudmin-$name.nmconnection";
	push(@files, $plan->{'new_file'});
	}
die "A configuration file for this bridge already exists\n"
	if ($plan->{'new_file'} && -e $plan->{'new_file'});
$plan->{'files'} = $self->snapshot(\@files);
$plan->{'revision'} = sha256_hex(convert_to_json($plan, 0, 0, 1));
return $plan;
}

# unit(self, method, arguments...) Converts Webmin systemd's result pair into an
# exception on failure.
sub unit
{
my ($self, $method, @args) = @_;
foreign_require('systemd', 'systemd-lib.pl');
no strict 'refs';
my $function = "systemd::$method";
my ($ok, $error) = $function->(@args);
die "Cannot prepare network recovery: $error\n" if (!$ok);
}

# install_guards(self, plan) Arms recovery before any network write, including a
# boot-time restore path.
sub install_guards
{
my ($self, $plan) = @_;
# Use the saved deadline so restarting the timer does not extend it.
my $remaining = $plan->{'deadline'} - time();
die "Bridge confirmation time has expired\n" if ($remaining <= 0);
# Recovery commands must remain valid systemd ExecStart arguments.
my $script = "$self->{module}/network-worker.pl";
my $perl = get_perl_path();
die "Unsupported module path for network recovery\n"
	if ("$script$perl" =~ /[^a-zA-Z0-9_\/.+-]/);
my %values = ( network_exec => "$perl $script",
	       network_timeout => $remaining );
# Read every template before installing any recovery units.
my %units;
foreach my $name (qw(boot.service rollback.service rollback.timer apply.service)) {
	my $file = "$self->{module}/cloudmin-network-$name.in";
	my $data = read_file_contents($file);
	die "Cannot read network recovery template $file\n"
		unless (defined($data) && length($data));
	$units{$name} = substitute_template($data, \%values);
	}
# Boot recovery survives a reboot while the normal timer covers a lost session.
$self->unit(
	'create_system_unit', 'cloudmin-network-boot.service',
	$units{'boot.service'});
$self->unit('enable_unit', 'cloudmin-network-boot.service');
$self->unit(
	'create_system_unit', 'cloudmin-network-rollback.service',
	$units{'rollback.service'});
$self->unit(
	'create_system_unit', 'cloudmin-network-rollback.timer',
	$units{'rollback.timer'});
# Apply failures also request rollback; start the timer before launching apply.
$self->unit(
	'create_system_unit', 'cloudmin-network-apply.service',
	$units{'apply.service'});
$self->unit('stop_unit', 'cloudmin-network-rollback.timer');
$self->unit('start_unit', 'cloudmin-network-rollback.timer');
}

# disarm_guards(self, record) Removes scheduled recovery after the journal has
# committed a final outcome. Cleanup failure is reported without making
# confirmed networking reversible.
sub disarm_guards
{
my ($self, $p) = @_;
my @errors;
foreach my $guard ( [ 'stop_unit', 'cloudmin-network-rollback.timer' ],
		    [ 'disable_unit', 'cloudmin-network-boot.service' ] ) {
	push(@errors, "$@") if (!eval { $self->unit(@$guard); 1 });
	}
if (@errors) {
	# Preserve the committed outcome while making
	# incomplete cleanup visible.
	$p->{'error'} =
		($p->{'error'} ||
		 '')." Could not disarm network recovery: ".join(' ',
								 @errors);
	$self->write_state($p);
	}
}

# begin(self, name, source, revision, owner, [operation]) Revalidates the
# reviewed plan and starts an independent, bounded apply worker. operation
# defaults to creation; remove moves addressing back to Ethernet. owner is the
# requesting user; removal derives source from the named bridge.
sub begin
{
my ($self, $name, $source, $revision, $owner, $operation) = @_;
return $self->{'jobs'}->lock('host-network', sub {
	# Only one transaction may own the saved files and
	# recovery units at a time.
	die "Another bridge change needs confirmation or recovery\n"
		if ($self->pending());
	my $plan = ($operation || '') eq 'remove'
		? $self->prepare_remove($name)
		: $self->prepare($name, $source);
	# Require another review if topology or file contents changed meanwhile.
	die "Host networking changed; review the bridge again\n"
		if ($revision ne $plan->{'revision'});
	$plan->{'id'} =
		substr(
			sha256_hex($revision.':'.$owner.':'.time().':'.$$),
			0, 32);
	$plan->{'owner'} = $owner;
	if ($plan->{'mode'} eq 'nm' && ($operation || '') ne 'remove') {
		# Allocate the bridge profile identity before saving
		# the recovery journal.
		$plan->{'bridge_uuid'} =
			read_file_contents('/proc/sys/kernel/random/uuid');
		chomp($plan->{'bridge_uuid'});
		# Do not journal an unusable profile identity if
		# the kernel read failed.
		die "Cannot generate a bridge UUID\n"
			if ($plan->{'bridge_uuid'} !~ /\A[0-9a-f-]{36}\z/);
		}
	# Save the deadline before services start; applying the
	# change counts toward it.
	$plan->{'state'} = 'armed';
	$plan->{'deadline'} = time() + $self->{'confirm_timeout'};
	$self->write_state($plan);
	my $ok = eval {
		$self->install_guards($plan);
		# The API's start_unit waits for completion; this
		# change must outlive CGI.
		$self->command([ 'systemctl', 'start', '--no-block',
				 'cloudmin-network-apply.service' ]);
		1;
		};
	if (!$ok) {
		# Retire the armed record if recovery setup or
		# service launch fails.
		my $error = $@;
		$plan->{'state'} = 'rolled_back';
		$plan->{'error'} = $error;
		$self->write_state($plan);
		$self->disarm_guards($plan);
		die $error;
		}
	return $plan->{'id'};
	});
}

# save_bridge(self, plan) Uses each Webmin backend's configuration APIs,
# preserving complete IP settings.
sub save_bridge
{
my ($self, $p) = @_;
$self->backend();
my ($name, $source) = @$p{qw(name source)};
if ($p->{'mode'} eq 'debian-linux') {
	# Move addressing to bridge stanzas and leave the
	# physical port unnumbered.
	my @defs = @{$p->{'defs'}};
	foreach my $def (@defs) {
		my @options =
			map { [ @$_ ] } grep { $_->[0] ne 'hwaddress' } @{$def->[3]};
		if ($def->[1] eq 'inet') {
			# Create the bridge once, even when the port has
			# both address families.
			push(@options, [ 'bridge_ports', $source ],
			     [ 'bridge_stp', 'off' ],
			     [ 'bridge_fd', '0' ], [ 'hwaddress', 'ether '.
						     $p->{'mac'} ]);
			}
		net::new_interface_def($name, $def->[1], $def->[2], \@options,
				       $def->[4]);
		net::modify_interface_def($source, $def->[1], 'manual', [ ], 0,
					  $def->[4]);
		}
	if (!grep { $_ eq $name } net::get_auto_defs()) {
		# Keep existing auto lines and their startup order intact.
		no warnings 'once';
		my $file = $net::network_interfaces_config;
		my $contents = read_file_contents($file);
		$contents .= "\n" if (length($contents) && $contents !~ /\n\z/);
		write_file_contents($file, $contents."auto $name\n");
		unflush_file_lines($file);
		}
	}
elsif ($p->{'mode'} eq 'netplan') {
	# Keep NIC matching on the port and copy IP settings
	# to a new bridge file.
	my %physical =
		map { $_ =>
			1 } qw(match set-name renderer mtu macaddress optional critical);
	my $old = $p->{'saved'};
	my %bridge = ( %$old, name => $name, fullname => $name, bridge => 1,
		       bridgeto => $source, bridgestp => 'off', bridgefd => 0,
		       ether =>
			       $p->{'mac'}, up => 1 );
	delete(@bridge{qw(file line eline index)});
	# A new Webmin Netplan file uses four-space section indentation,
	# regardless of the source file's indentation. Its interface must
	# be one level deeper.
	$bridge{'yaml'} = { %{$old->{'yaml'}}, indent => 8, members => [ grep {
		!$physical{$_->{'name'}} || $_->{'name'} eq 'renderer' ||
			$_->{'name'} eq 'mtu'
		} @{$old->{'yaml'}->{'members'}} ] };
	# Each generated file declares its schema and keeps host
	# configuration private.
	my $mask = umask(0077);
	write_file_contents($p->{'api_file'}, "network:\n    version: 2\n");
	net::save_interface(\%bridge);
	umask($mask);
	rename_logged($p->{'api_file'}, $p->{'new_file'}) ||
		die "Cannot place the bridge configuration: $!\n";
	unflush_file_lines($p->{'api_file'});
	# Reload line positions after appending the new bridge file.
	my @boot = net::boot_interfaces();
	my ($port) = grep { $_->{'fullname'} eq $source } @boot;
	$port = { %$port, dhcp => 0, auto6 => 0, address6 => [ ],
		  netmask6 => [ ],
		  # Preserve the port's MAC and keep a minimal DHCP
		  # stanza a YAML mapping.
		  ether => $port->{'ether'} || $p->{'mac'},
		  yaml =>
			  { %{$port->{'yaml'}}, members =>
							[ grep { $physical{$_->{'name'}} }
							  @{$port->{'yaml'}->{'members'}} ] } };
	delete(
		@$port{qw(address netmask gateway gateway6 nameserver search routes)});
	net::save_interface($port, \@boot);
	if ($p->{'dhcp4_dropin'}) {
		# networkd reads this alongside Netplan's generated
		# bridge configuration.
		make_dir($p->{'dhcp4_directory'}, 0755, 1);
		write_file_contents($p->{'dhcp4_dropin'},
				    $p->{'dhcp4_identity'});
		chmod(0644, $p->{'dhcp4_dropin'}) ||
			die "Cannot set DHCP configuration permissions: $!\n";
		}
	my $error = net::validate_netplan_config();
	die "Invalid bridge configuration: $error\n" if ($error);
	}
else {
	# Copy IP settings, replacing generated DHCP identity
	# with its saved value.
	my $cfg = $p->{'saved'}->{'cfg'};
	my $uuid = $p->{'bridge_uuid'};
	my $contents =
		"[connection]\nid=cloudmin-$name\nuuid=$uuid\ntype=bridge\ninterface-name=$name\nautoconnect=true\nautoconnect-slaves=1\n\n[bridge]\nstp=false\nmac-address=$p->{mac}\n";
	foreach my $section (grep {
		$_->{'sect'} =~ /\A(?:ipv4|ipv6|proxy)\z/ } @$cfg) {
		my @members = @{$section->{'members'}};
		if ($section->{'sect'} eq 'ipv4' &&
		    defined($p->{'dhcp4_client_id'})) {
			# Replace the key rather than relying on
			# duplicate-key precedence.
			@members =
				grep {
					$_->{'name'} ne 'dhcp-client-id' } @members;
			push(@members,
			     { name => 'dhcp-client-id', value =>
								 $p->{'dhcp4_client_id'} });
			}
		$contents .= "\n[$section->{sect}]\n".join('',
							   map { "$_->{name}=$_->{value}\n" } @members);
		}
	my $mask = umask(0077);
	write_file_contents($p->{'new_file'}, $contents);
	umask($mask);
	$self->command([ 'nmcli', 'connection', 'load', $p->{'new_file'} ]);
	net::save_nm_config($cfg, 'connection', 'master', $name, 'slave-type',
			    'bridge');
	}
}

# activate(self, plan, rollback) Reconnects only the selected Ethernet/bridge
# pair except Netplan's native apply.
sub activate
{
my ($self, $p, $rollback) = @_;
# Removal reconnects the Ethernet port; recovery recreates the saved bridge.
return $self->activate_removal($p, $rollback)
	if (($p->{'operation'} || '') eq 'remove');
my ($name, $source) = @$p{qw(name source)};
if ($p->{'mode'} eq 'nm') {
	# Reload saved profiles and activate the existing Ethernet connection.
	if ($rollback) {
		# Delete only the bridge profile created by this transaction.
		my $uuids =
			$self->command([ 'nmcli', '-t', '-f', 'UUID',
					 'connection',
					 'show' ], 1);
		$self->command([ 'nmcli', 'connection', 'delete', 'uuid',
				 $p->{'bridge_uuid'} ])
			if (grep { $_ eq $p->{'bridge_uuid'} } split(/\n/,
								     $uuids));
		}
	$self->command([ 'nmcli', 'connection', 'reload' ]);
	# Activating the port also activates its controller. Activating the
	# bridge again afterwards would detach and reconnect
	# the port a second time.
	$self->command([ 'nmcli', '--wait', '30', 'connection', 'up',
			 $p->{'uuid'} ]);
	}
elsif ($p->{'mode'} eq 'netplan') {
	# Netplan applies the regenerated configuration through
	# its selected renderer.
	my $error = net::apply_network();
	die "Cannot apply bridge configuration: $error\n" if ($error);
	}
else {
	# ifdown must use the original definition to release
	# DHCP and old routes.
	my $temporary = "$self->{directory}/ifdown.interfaces";
	my $defs = $rollback
		? [ map { [ $name, $_->[1], $_->[2],
			    $_->[3] ] } @{$p->{'defs'}} ]
		: $p->{'defs'};
	my $text =
		join('',
		     map { 'iface '.$_->[0].' '.$_->[1].' '.$_->[2]."\n".
				join('',
				     map { "\t$_->[0] $_->[1]\n" } @{
						$_->[3]}) } @$defs);
	write_file_contents($temporary, $text);
	eval { $self->command([ 'ifdown', '--force', '-i', $temporary, $rollback
		? $name
		: $source ]); };
	if ($rollback) {
		# Release the Ethernet port before restoring
		# DHCP and routes on it.
		my $links = $self->ip_json('link', 'show');
		$self->command([ 'ip', 'link', 'delete', $name, 'type',
				 'bridge' ])
			if (grep { $_->{'ifname'} eq $name } @$links);
		# A retried restore may already have some addresses on the port.
		eval { $self->command([ 'ifdown', '--force', $source ]); };
		# bridge-utils disables IPv6 generation on ports. Restore the
		# captured mode (the kernel default for older journals) before
		# restarting the link.
		$self->command([ 'ip', 'link', 'set', 'dev', $source, 'down' ]);
		$self->command([ 'ip', 'link', 'set', 'dev', $source,
				 'addrgenmode',
				 $p->{'ipv6_address_mode'} || 'eui64' ]);
		$self->command([ 'ip', 'link', 'set', 'dev', $source, 'up' ]);
		}
	$self->command([ 'ifup', '--force', $rollback ? $source : $name ]);
	}
if ($rollback) {
	# Removing a bridge releases its port; the restored
	# backend owns the NIC again.
	my $links = $self->ip_json('link', 'show');
	$self->command([ 'ip', 'link', 'delete', $name, 'type', 'bridge' ])
		if (grep { $_->{'ifname'} eq $name } @$links);
	}
}

# apply(self) The systemd worker holds the transaction lock while saving
# and applying settings.
sub apply
{
my ($self) = @_;
return $self->{'jobs'}->lock('host-network', sub {
	my $p = $self->pending() || return;
	# A timer or another worker may already have advanced this transaction.
	return if ($p->{'state'} ne 'armed');
	# Do not begin a connection change after its recovery
	# deadline has passed.
	die "Bridge review expired before it could be applied\n"
		if (time() >= $p->{'deadline'});
	$p->{'state'} = 'applying';
	# Journal before writing so boot and timeout recovery
	# can undo partial work.
	$self->write_state($p);
	# Use the writer for the operation recorded in the recovery journal.
	if (($p->{'operation'} || '') eq 'remove') { $self->save_removal($p); }
	# Creation moves the source settings onto a new bridge instead.
	else { $self->save_bridge($p); }
	# Offer confirmation only after the destination has the
	# preserved addresses.
	$self->activate($p, 0);
	$self->wait_for_connection($p);
	$p->{'state'} = 'confirm';
	$self->write_state($p);
	return $p->{'name'};
	});
}

# wait_for_connection(self, plan, [restoring]) Allows address acquisition to
# finish after the backend reports activation. restoring defaults to false; true
# checks the pre-change topology instead.
sub wait_for_connection
{
my ($self, $p, $restoring) = @_;
for (1 .. 20) {
	# DHCP and IPv6 addresses may arrive after the backend reports success.
	return if (eval { $self->check_connection($p, $restoring); 1 });
	sleep(1);
	}
$self->check_connection($p, $restoring);
}

# check_connection(self, plan, [restoring]) Checks the port, preserved addresses
# and browser/default route before confirmation. restoring defaults to false and
# reverses the plan's expected destination.
sub check_connection
{
my ($self, $p, $restoring) = @_;
local $self->{'client'} = $p->{'client'};
my $inventory = $self->inventory();
# Creation recovery and forward removal both require standalone Ethernet.
my $unbridged = !!$restoring != (($p->{'operation'} || '') eq 'remove');
my $name = $unbridged ? $p->{'source'} : $p->{'name'};
my ($bridge) =
	grep { $_->{'name'} eq $name && ($unbridged || $_->{'bridge'}) &&
		$_->{'active'} } @{$inventory->{'interfaces'}};
# Address checks are meaningful only after the expected device is active.
die "Network interface $name is not active\n" if (!$bridge);
# A bridge without its uplink would leave the host isolated from its network.
die "The Ethernet interface did not join the bridge\n"
	if (!$unbridged && !grep { $_ eq $p->{'source'} } @{$bridge->{'ports'}});
# The port must leave the bridge before it can carry the host connection.
die "The Ethernet interface is still attached to a bridge\n"
	if ($unbridged && $bridge->{'master'});
# Successful removal must delete the obsolete kernel device too.
die "The removed bridge is still present\n"
	if (($p->{'operation'} || '') eq 'remove' &&
	    !$restoring &&
	    grep { $_->{'name'} eq
			$p->{'name'} } @{$inventory->{'interfaces'}});
foreach my $address (@{$p->{'addresses'}}) {
	# Preserve all reviewed addresses, including IPv6,
	# before accepting success.
	die "The host address $address is missing from $name\n"
		if (!grep { $_ eq $address } @{$bridge->{'addresses'}});
	}
# A management interface must still carry the route used to reach this host.
die "Network interface $name did not retain the management route\n"
	if ($p->{'management'} &&
	    !grep { $_ eq $name } @{$inventory->{'management'}});
}

# confirm(self, id, owner) A fresh successful browser request and connectivity
# checks commit the change.
sub confirm
{
my ($self, $id, $owner) = @_;
return $self->{'jobs'}->lock('host-network', sub {
	my $p = $self->pending() ||
		die "No bridge change is awaiting confirmation\n";
	die "This bridge change belongs to another user or has been replaced\n"
		if ($p->{'id'} ne $id || $p->{'owner'} ne $owner);
	die "The bridge is not ready for confirmation\n"
		if ($p->{'state'} ne 'confirm');
	die "The confirmation period expired; networking will be restored\n"
		if (time() >= $p->{'deadline'});
	$self->check_connection($p);
	$p->{'state'} = 'complete';
	$self->write_state($p);
	$self->disarm_guards($p);
	return $p->{'name'};
	});
}

# rollback(self, [boot]) Restores exact persistent files even after a worker
# crash; boot recovery avoids starting network services before systemd has
# reached network-pre.target. boot defaults to false; true restores files for
# the normal boot sequence.
sub rollback
{
my ($self, $boot) = @_;
return $self->{'jobs'}->lock('host-network', sub {
	my $p = $self->pending() || return;
	my $ok = eval {
		$self->backend();
		foreach my $path (sort keys %{$p->{'files'}}) {
			my $file = $p->{'files'}->{$path};
			if ($file) {
				# Restore both content and metadata for a
				# pre-existing file. Removal may have deleted an
				# empty override directory as well.
				make_dir(dirname($path), 0755,
					 1) if (!-d dirname($path));
				write_file_contents($path, $file->{'content'});
				chmod($file->{'mode'}, $path) ||
					die "Cannot restore permissions on $path\n";
				chown($file->{'uid'}, $file->{'gid'}, $path) ||
					die "Cannot restore ownership on $path\n";
				}
			# Files absent before conversion belong solely
			# to this transaction.
			else { unlink_file($path) if (-e $path); }
			unflush_file_lines($path);
			}
		# Remove the directory created for this transaction
		# once its file is gone.
		rmdir($p->{'dhcp4_directory'})
			if ($p->{'dhcp4_directory'} &&
			    -d $p->{'dhcp4_directory'});
		if ($boot && ($p->{'mode'} || '') eq 'netplan') {
			# The early systemd generator may already have rendered
			# the unconfirmed YAML. Replace that runtime
			# configuration before network services start.
			my $error = net::validate_netplan_config();
			# Invalid regenerated files must keep
			# recovery marked as failed.
			die "Cannot regenerate restored Netplan configuration: $error\n"
				if ($error);
			}
		if (!$boot && $p->{'state'} ne 'armed') {
			# Only an applied change needs live reconnection;
			# boot handles it later.
			$self->activate($p, 1);
			$self->restore_netplan_dhcp4($p);
			# Check management connectivity before
			# marking recovery complete.
			$self->wait_for_connection($p, 1)
				if ($p->{'management'});
			}
		1;
		};
	$p->{'state'} = $ok ? 'rolled_back' : 'rollback_failed';
	# A successful retry must not display the previous attempt's failure.
	if ($ok) { delete($p->{'error'}); }
	# Keep the latest failure visible and leave recovery guards armed.
	else { $p->{'error'} = "$@"; }
	$self->write_state($p);
	# A failed restore must retain its guards so it remains recoverable.
	die $p->{'error'} if (!$ok);
	$self->disarm_guards($p);
	return $p->{'name'};
	});
}

# release_netplan_dhcp4(self, target, status) Sends a release for target's
# configured lease from its networkctl JSON status. Returns 1 when sent, or 0
# without a lease. Sending does not confirm receipt. Static addresses are never
# selected for release.
sub release_netplan_dhcp4
{
my ($self, $target, $status) = @_;
Cloudmin::Networks::name($target);
my @leases = grep { ($_->{'ConfigSource'} || '') eq 'DHCPv4' &&
	($_->{'ConfigState'} ||
	 '') eq 'configured' } @{$status->{'Addresses'} || [ ]};
# A missing lease needs a new request, without sending a release for an old one.
return 0 if (!@leases);
# Never choose arbitrarily between multiple configured leases.
die "Cannot identify the current DHCPv4 lease for $target\n" if (@leases != 1);
my ($lease) = @leases;
my $id = $status->{'DHCPv4Client'}->{'ClientIdentifier'};
my $mac = $status->{'HardwareAddress'};
# Validate live address and identity bytes before building a DHCP message.
foreach my $bytes ( $lease->{'Address'}, $lease->{'ConfigProvider'}, $id,
		    $mac ) {
	die "Cannot read DHCPv4 release details for $target\n"
		if (ref($bytes) ne 'ARRAY' || !@$bytes || @$bytes > 255 ||
		    grep { !defined($_) || ref($_) || !/\A\d{1,3}\z/ ||
				$_ > 255 } @$bytes);
	}
# The packet requires IPv4 addresses, an Ethernet MAC and a client identifier.
die "Invalid DHCPv4 release details for $target\n"
	if (@{$lease->{'Address'}} != 4 || @{$lease->{'ConfigProvider'}} != 4 ||
	    @$mac != 6 || @$id < 2);
foreach my $ip ( $lease->{'Address'}, $lease->{'ConfigProvider'} ) {
	# A release goes only from the leased unicast address
	# to its actual server.
	die "Invalid DHCPv4 release address for $target\n"
		if ($ip->[0] == 0 || $ip->[0] == 127 || $ip->[0] >= 224);
	}
my $source = join('.', @{$lease->{'Address'}});
my $server = pack('C4', @{$lease->{'ConfigProvider'}});
my $client = pack('C*', @$id);
# RFC 2131 requires the server identifier and the original client identifier.
# Some networkd versions omit the server identifier from their release packet.
my $packet = pack('C4Nn2a4a4a4a4a16a64a128N',
		  1, 1, 6, 0, int(rand(4294967296)), 0, 0,
		  pack('C4', @{$lease->{'Address'}}), '', '', '', pack('C6',
								       @$mac),
		  '',
		  '', 0x63825363);
$packet .= pack('C*', 53, 1, 7, 54, 4).$server.
	   pack('CC', 61, length($client)).$client.chr(255);
# Pad short DHCP messages to the BOOTP minimum packet size.
$packet .= "\0" x (300 - length($packet)) if (length($packet) < 300);
my $socket = IO::Socket::INET->new(Proto => 'udp', LocalAddr => $source,
				   LocalPort => 68, ReuseAddr => 1) ||
	     die "Cannot open DHCPv4 release socket for $target: $!\n";
# Bind both the source address and device so overlapping subnets cannot route
# this release through another interface. No reply is expected for a release.
$socket->setsockopt(Socket::SOL_SOCKET(), Socket::SO_BINDTODEVICE(),
		    $target."\0") ||
	die "Cannot bind DHCPv4 release to $target: $!\n";
$socket->blocking(0);
my $sent = $socket->send($packet, 0, Socket::pack_sockaddr_in(67, $server));
# A failed or incomplete send must stop recovery before taking the link down.
die "Cannot release DHCPv4 lease for $target: $!\n"
	if (!defined($sent) || $sent != length($packet));
$socket->close();
return 1;
}

# restore_netplan_dhcp4(self, plan) Requests plan's saved DHCP address if
# Netplan recovery got a different lease. Uses a temporary networkd override;
# throws if recovery or cleanup fails.
sub restore_netplan_dhcp4
{
my ($self, $p) = @_;
# Other backends and static configurations have no networkd lease to restore.
return unless (($p->{'mode'} || '') eq 'netplan' && $p->{'saved'}->{'dhcp'});
# Recovery of a removal restores the lease on the bridge, not its former port.
my $target = ($p->{'operation'} || '') eq 'remove'
	? $p->{'name'}
	: $p->{'source'};
my ($address) = ($p->{'dhcp4_identity'} || '') =~ /^RequestAddress=(\S+)$/m;
# An existing failed transaction may have saved its address only in inventory.
if (!$address) {
	my @addresses = map { m{\A([0-9.]+)/\d+\z} ? $1 : () }
			@{$p->{'addresses'} || [ ]};
	# DHCP may be enabled on an IPv6-only network with no lease to recover.
	return if (!@addresses);
	# Older journals cannot distinguish a DHCP lease from
	# multiple IPv4 entries.
	die "Cannot identify the original DHCPv4 address for $target\n"
		if (@addresses != 1);
	$address = $addresses[0];
	}
my @octets = split(/\./, $address, -1);
# Validate journal data before placing it in a networkd setting.
die "Invalid saved DHCPv4 address\n" if (@octets != 4 ||
					 grep { !/\A\d{1,3}\z/ || $_ > 255 } @octets);
my $status = convert_from_json($self->command(
	[ 'networkctl', '--json=short', 'status', $target ], 1), 1);
# Avoid reconnecting an interface that already recovered its original lease.
return if (grep { ($_->{'ConfigSource'} || '') eq 'DHCPv4' &&
	($_->{'ConfigState'} || '') eq 'configured' &&
	join('.',
	     @{$_->{'Address'} ||
			[ ]}) eq $address } @{$status->{'Addresses'} ||
				[ ]});
my ($network) =
	($status->{'NetworkFile'} || '') =~
	m{\A/(?:run|etc|usr/lib)/systemd/network/([a-zA-Z0-9_.:-]+\.network)\z};
# Only a known networkd file basename may select the override directory.
die "Cannot identify the restored network configuration for $target\n"
	if (!$network);
my $root = $self->{'networkd_runtime_directory'} || '/run/systemd/network';
my $directory = "$root/$network.d";
# A stable transaction-specific name lets a retry reuse its own runtime hint.
my $dropin =
	"$directory/90-cloudmin-restore-".substr(sha256_hex($p->{'id'}), 0,
						 16).'.conf';
my $contents = "[DHCPv4]\nRequestAddress=$address\nSendRelease=yes\n";
# Never follow a replacement directory symlink or overwrite another file.
die "Recovery configuration is not an ordinary directory\n"
	if (-l $directory || (-e $directory && !-d $directory));
# An existing hint is reusable only when it contains exactly this request.
die "Recovery configuration already exists\n" if (-l $dropin ||
						  (-e $dropin &&
						   (!-f $dropin || read_file_contents($dropin) ne $contents)));
my $existed = -d $directory;
make_dir($directory, 0755, 1);
my $down;
my $ok = eval {
	# Keep permanent files and the client identity while
	# requesting the old IP.
	write_file_contents($dropin, $contents);
	chmod(0644, $dropin) ||
		die "Cannot set DHCP recovery permissions: $!\n";
	if ($self->release_netplan_dhcp4($target, $status)) {
		# Clear the wrong cached lease before reload can request it
		# again. Track the attempted down so even a failed
		# command is followed by up.
		$down = 1;
		$self->command([ 'networkctl', 'down', $target ]);
		}
	# Load the hint before restarting DHCP. Without a lease, reconfiguration
	# suffices and avoids taking an otherwise working link down.
	$self->command([ 'networkctl', 'reload' ]);
	$self->command([ 'networkctl', $down ? 'up' : 'reconfigure', $target ]);
	$down = 0;
	$self->wait_for_connection($p, 1);
	1;
	};
my $error = $@;
# Remove the hint after success or refusal. Recovery guards handle interrupted
# workers; a retry can reuse the hint, and a reboot discards it automatically.
my $clean = eval {
	# A failed write may have left no hint; remove only
	# our own runtime file.
	unlink_file($dropin) if (-e $dropin);
	# Leave pre-existing directories and other services' overrides intact.
	rmdir($directory) if (!$existed);
	$self->command([ 'networkctl', 'reload' ]);
	1;
	};
# Report cleanup failures too, even if the original lease was recovered.
$error .= $@ if (!$clean);
# A failed reload or activation must not leave the recovered interface down.
if ($down) {
	my $up = eval { $self->command([ 'networkctl', 'up', $target ]); 1; };
	# Keep the original failure if the final attempt to raise
	# the link also fails.
	$error .= $@ if (!$up);
	}
# Both recovery and cleanup must succeed before the caller clears the error.
die $error if (!$ok || !$clean);
}

1;
