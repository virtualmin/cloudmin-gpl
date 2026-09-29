package Cloudmin::HostNetwork;

# Removal moves current settings back to Ethernet. HostNetwork saves the files
# in its journal and handles confirmation and recovery.
use strict;
use warnings;

# prepare_remove(self, name)
# Returns a removal plan for the named bridge, including current file backups.
sub prepare_remove
{
my ($self, $name) = @_;
Cloudmin::Networks::name($name);
my $inventory = $self->inventory();
# Limit automatic removal to backends with a matching recovery path.
die "Bridge removal is unavailable for this host's network backend\n" if (!$inventory->{'supported'});
my ($live) = grep { $_->{'name'} eq $name && $_->{'bridge'} } @{$inventory->{'interfaces'}};
# Recheck that the bridge still exists when the request arrives.
die "Choose an existing host bridge\n" if (!$live);
# Nested bridges and multiple ports need an explicit destination decision.
die "Detach this bridge from its controller before removing it\n" if ($live->{'master'});
die "Only bridges with one Ethernet port can be removed here\n" if (@{$live->{'ports'}} != 1);
my $source = $live->{'ports'}->[0];
Cloudmin::Networks::name($source);
# Deleting the bridge also deletes its child links. Children of its Ethernet
# port need manual handling too, since the port's configuration will change.
die "Other host interfaces depend on this bridge or its port; use Webmin Network Configuration\n"
	if (grep { ($_->{'parent'} || '') eq $name || ($_->{'parent'} || '') eq $source }
		@{$inventory->{'interfaces'}});
my ($port_live) = grep { $_->{'name'} eq $source } @{$inventory->{'interfaces'}};
# Only plain Ethernet can receive the bridge's settings through this flow.
die "The bridge port must be a plain Ethernet interface\n" if (!$port_live ||
	$port_live->{'kind'} || -d "/sys/class/net/$source/wireless");
# Avoid overwriting the port's own addresses.
die "The Ethernet port has its own addresses; resolve them before removing the bridge\n"
	if (@{$port_live->{'addresses'} || []});
my @boot = net::boot_interfaces();
my @bridges = grep { ($_->{'fullname'} || '') eq $name } @boot;
my @ports = grep { ($_->{'fullname'} || '') eq $source } @boot;
# Ambiguous saved definitions cannot be moved and restored reliably.
die "The bridge and port must each have one persistent configuration\n"
	if (@bridges != 1 || @ports != 1 || !$bridges[0]->{'bridge'});
# Alias addresses are outside the single-interface conversion.
die "Move additional interface aliases manually before removing a bridge\n"
	if (grep { ($_->{'name'} eq $name || $_->{'name'} eq $source) &&
		defined($_->{'virtual'}) && $_->{'virtual'} ne '' } @boot);
my ($saved, $port) = ($bridges[0], $ports[0]);
# Capture current settings so removal never revives an old creation snapshot.
my $p = { operation => 'remove', name => $name, source => $source,
	mode => $inventory->{'backend'}, confirm_timeout => 0 + $self->{'confirm_timeout'},
	management => $live->{'management'}, mac => $live->{'mac'}, mtu => $live->{'mtu'},
	saved => $saved, port => $port, addresses => $live->{'addresses'}, client => $self->{'client'} };
my @files = ($saved->{'file'}, $port->{'file'});
if ($p->{'mode'} eq 'nm') {
	# Keep the Ethernet profile's identity and physical settings; copy IP sections.
	my $cfg = $saved->{'cfg'};
	my $pcfg = $port->{'cfg'};
	my $type = net::find_nm_config($pcfg, 'connection', 'type') || '';
	# A live Ethernet device may still have an incompatible saved profile.
	die "The saved bridge port is not an Ethernet connection\n"
		if ($type !~ /\A(?:ethernet|802-3-ethernet)\z/);
	$p->{'bridge_uuid'} = net::find_nm_config($cfg, 'connection', 'uuid');
	$p->{'uuid'} = net::find_nm_config($pcfg, 'connection', 'uuid');
	# Both identities are needed to switch profiles and undo that switch.
	die "NetworkManager connection UUID is missing\n" if (!$p->{'uuid'} || !$p->{'bridge_uuid'});
	my $master = net::find_nm_config($pcfg, 'connection', 'controller') ||
		net::find_nm_config($pcfg, 'connection', 'master') || '';
	# Accept either NetworkManager representation of this controller.
	die "The saved Ethernet connection does not belong to this bridge\n"
		if ($master ne $name && $master ne $p->{'bridge_uuid'});
	# Do not silently discard bridge settings that this writer cannot preserve.
	die "This bridge uses unsupported NetworkManager settings; use Webmin Network Configuration\n"
		if (grep { $_->{'sect'} !~ /\A(?:connection|bridge|ethernet|802-3-ethernet|ipv4|ipv6|proxy|user)\z/ } @$cfg);
	# The destination profile must also fit the supported Ethernet conversion.
	die "The bridge port uses unsupported NetworkManager settings; use Webmin Network Configuration\n"
		if (grep { $_->{'sect'} !~ /\A(?:connection|ethernet|802-3-ethernet|bridge-port|ipv4|ipv6|proxy|user)\z/ } @$pcfg);
	# Inactive saved ports also count, even when absent from the live bridge.
	die "The bridge has additional saved ports\n" if (grep {
		my $master = net::find_nm_config($_->{'cfg'}, 'connection', 'controller') ||
			net::find_nm_config($_->{'cfg'}, 'connection', 'master') || '';
		$_->{'fullname'} ne $source && ($master eq $name || $master eq $p->{'bridge_uuid'}) } @boot);
	$self->check_ipv6_identity($live, net::find_nm_config($cfg, 'ipv6', 'token'));
	# Without an IPv4 address, there is no lease to preserve during the move.
	$p->{'dhcp4_client_id'} = $self->nm_dhcp4_identity($name)
		if ($saved->{'dhcp'} && grep { /^\d+\./ } @{$live->{'addresses'}});
	}
elsif ($p->{'mode'} eq 'netplan') {
	# Accept only settings this writer knows how to move or remove.
	my %allowed = map { $_ => 1 } qw(renderer optional dhcp4 dhcp6 dhcp4-overrides
		dhcp6-overrides accept-ra addresses gateway4 gateway6 nameservers macaddress mtu
		routes routing-policy link-local ipv6-privacy ipv6-address-generation
		ipv6-address-token dhcp-identifier critical optional-addresses interfaces parameters);
	die "This bridge uses unsupported Netplan settings; use Webmin Network Configuration\n"
		if (grep { !$allowed{$_->{'name'}} } @{$saved->{'yaml'}->{'members'}});
	my $ports = ref($saved->{'bridgeto'}) eq 'ARRAY'
		? join(',', @{$saved->{'bridgeto'}}) : $saved->{'bridgeto'} || '';
	$ports =~ s/[\s'"\[\]]//g;
	# Saved membership must agree with the single live port being moved.
	die "The bridge has additional or different saved ports\n" if ($ports ne $source);
	my ($entry) = grep { $_->{'name'} eq 'ipv6-address-token' } @{$saved->{'yaml'}->{'members'}};
	my $token = $entry ? $entry->{'value'} : '';
	$token =~ s/^\s*(['"]?)(.*?)\1\s*$/$2/;
	$self->check_ipv6_identity($live, $token);
	# Move Cloudmin's DHCP override; other networkd overrides need manual review.
	my $root = $self->{'networkd_directory'} || '/etc/systemd/network';
	$p->{'old_dhcp4_dropin'} = "$root/10-netplan-$name.network.d/90-cloudmin-dhcp.conf";
	foreach my $device ($name, $source) {
		# Unrecognized native overrides could change either device after apply.
		die "This interface has custom networkd overrides; use Webmin Network Configuration\n"
			if (grep { $_ !~ m{/90-cloudmin-dhcp\.conf\z} }
				glob("$root/10-netplan-$device.network.d/*.conf"));
		}
	push(@files, $p->{'old_dhcp4_dropin'});
	# An IPv6-only interface may enable DHCPv4 without having a lease to move.
	if ($saved->{'dhcp'} && grep { /^\d+\./ } @{$live->{'addresses'}}) {
		$p->{'dhcp4_identity'} = $self->netplan_dhcp4_identity($name, $live->{'mac'});
		$p->{'dhcp4_directory'} = "$root/10-netplan-$source.network.d";
		$p->{'dhcp4_dropin'} = "$p->{dhcp4_directory}/90-cloudmin-dhcp.conf";
		push(@files, $p->{'dhcp4_dropin'});
		}
	}
else {
	# Preserve both address families, rejecting custom hooks before any write.
	my @defs = net::get_interface_defs();
	$p->{'defs'} = [grep { $_->[0] eq $name } @defs];
	$p->{'port_defs'} = [grep { $_->[0] eq $source } @defs];
	# The conversion uses the inet stanza for link settings, even without IPv4.
	die "The bridge needs an inet stanza\n" if (!grep { $_->[1] eq 'inet' } @{$p->{'defs'}});
	# Manual port stanzas can be replaced without losing separate addressing.
	die "The Ethernet port has its own saved addressing; resolve it before removing the bridge\n"
		if (grep { $_->[2] ne 'manual' } @{$p->{'port_defs'}});
	foreach my $def (@{$p->{'defs'}}, @{$p->{'port_defs'}}) {
		# Custom hooks and device types may not work after the move to Ethernet.
		die "This bridge has custom hooks or unsupported address methods; use Webmin Network Configuration\n"
			if ($def->[2] !~ /\A(?:static|dhcp|auto|manual)\z/ || grep {
				$_->[0] =~ /^(?:pre-|post-)?(?:up|down)$/ || $_->[0] =~ /^(?:bond|vlan)/ ||
				($_->[0] =~ /^bridge/ && $_->[0] !~ /\Abridge_(?:ports|stp|fd|waitport)\z/) } @{$def->[3]});
		}
	$self->check_ipv6_identity($live);
	$p->{'ipv6_address_mode'} = $self->ipv6_address_mode($name);
	my @bridge_ports = map { $_->[1] } grep { $_->[0] eq 'bridge_ports' }
		map { @{$_->[3]} } @{$p->{'defs'}};
	# Check persistent membership too, including ports that are currently down.
	die "The bridge has additional or different saved ports\n"
		if (@bridge_ports != 1 || $bridge_ports[0] ne $source);
	no warnings 'once';
	push(@files, $net::network_interfaces_config, map { $_->[4] } (@{$p->{'defs'}}, @{$p->{'port_defs'}}));
	}
# Bind submission to the reviewed topology, settings and file contents.
$p->{'files'} = $self->snapshot(\@files);
$p->{'revision'} = sha256_hex(convert_to_json($p, 0, 0, 1));
return $p;
}

1;
