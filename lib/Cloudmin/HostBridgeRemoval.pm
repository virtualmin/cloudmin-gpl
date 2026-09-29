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

# save_removal(self, plan)
# Writes a prepare_remove plan without applying it to the live network.
sub save_removal
{
my ($self, $p) = @_;
$self->backend();
my ($name, $source) = @$p{qw(name source)};
if ($p->{'mode'} eq 'nm') {
	# Write keyfiles without dropping the live connection before apply starts.
	my @sections = grep { $_->{'sect'} !~ /\A(?:ipv4|ipv6|proxy|bridge-port)\z/ } @{$p->{'port'}->{'cfg'}};
	push(@sections, grep { $_->{'sect'} =~ /\A(?:ipv4|ipv6|proxy)\z/ } @{$p->{'saved'}->{'cfg'}});
	# Profiles without physical settings still need the preserved MAC and MTU.
	push(@sections, {sect => 'ethernet', members => []})
		if (!grep { $_->{'sect'} =~ /\A(?:ethernet|802-3-ethernet)\z/ } @sections);
	my $contents = '';
	foreach my $section (@sections) {
		my @members = @{$section->{'members'}};
		if ($section->{'sect'} eq 'connection') {
			# Turn the existing port profile into a standalone connection.
			@members = grep { $_->{'name'} !~ /\A(?:master|controller|slave-type|port-type)\z/ } @members;
			}
		if ($section->{'sect'} eq 'ipv4' && defined($p->{'dhcp4_client_id'})) {
			# Keep the client identity that the DHCP server recognizes.
			@members = grep { $_->{'name'} ne 'dhcp-client-id' } @members;
			push(@members, {name => 'dhcp-client-id', value => $p->{'dhcp4_client_id'}});
			}
		if ($section->{'sect'} =~ /\A(?:ethernet|802-3-ethernet)\z/) {
			# Keep the bridge's link identity without changing IPv6's own MTU.
			@members = grep { $_->{'name'} !~ /\A(?:cloned-mac-address|mtu)\z/ } @members;
			push(@members, {name => 'cloned-mac-address', value => $p->{'mac'}},
				{name => 'mtu', value => $p->{'mtu'}});
			}
		$contents .= "[$section->{sect}]\n".join('', map { "$_->{name}=$_->{value}\n" } @members)."\n";
		}
	# Replace saved profiles only; activation happens under the recovery guard.
	write_file_contents($p->{'port'}->{'file'}, $contents);
	chmod(0600, $p->{'port'}->{'file'}) || die "Cannot set Ethernet profile permissions: $!\n";
	unlink_file($p->{'saved'}->{'file'});
	}
elsif ($p->{'mode'} eq 'netplan') {
	# Keep hardware matching on Ethernet while replacing its IP configuration.
	my %physical = map { $_ => 1 } qw(match set-name renderer optional critical);
	my %port = (%{$p->{'saved'}}, %{$p->{'port'}});
	foreach my $key (qw(dhcp auto6 address netmask gateway gateway6 address6 netmask6 nameserver search routes)) {
		$port{$key} = $p->{'saved'}->{$key};
		}
	$port{'ether'} = $p->{'mac'};
	$port{'up'} = $p->{'saved'}->{'up'};
	# Keep hardware matching on the port and move only applicable bridge fields.
	delete(@port{qw(bridge bridgeto bridgestp bridgefd)});
	$port{'yaml'} = {%{$p->{'port'}->{'yaml'}}, members => [
		grep({ $physical{$_->{'name'}} } @{$p->{'port'}->{'yaml'}->{'members'}}),
		grep({ !$physical{$_->{'name'}} && $_->{'name'} ne 'interfaces' && $_->{'name'} ne 'parameters' }
			@{$p->{'saved'}->{'yaml'}->{'members'}}) ]};
	net::save_interface(\%port);
	# Reload line numbers because both devices may share the same YAML file.
	my ($bridge) = grep { $_->{'fullname'} eq $name } net::boot_interfaces();
	net::delete_interface($bridge);
	# A static or externally created bridge may not have a Cloudmin override.
	unlink_file($p->{'old_dhcp4_dropin'}) if (-e $p->{'old_dhcp4_dropin'});
	# An empty Cloudmin override directory must not reserve the old bridge name.
	rmdir(dirname($p->{'old_dhcp4_dropin'}));
	if ($p->{'dhcp4_dropin'}) {
		# Request the captured lease with the same identity on Ethernet.
		make_dir($p->{'dhcp4_directory'}, 0755, 1);
		write_file_contents($p->{'dhcp4_dropin'}, $p->{'dhcp4_identity'});
		chmod(0644, $p->{'dhcp4_dropin'}) || die "Cannot set DHCP configuration permissions: $!\n";
		}
	my $error = net::validate_netplan_config();
	# Fail before activation so the journal can restore the saved configuration.
	die "Invalid Ethernet configuration: $error\n" if ($error);
	}
else {
	# Move the bridge's addresses to port stanzas and remove bridge options.
	foreach my $def (@{$p->{'defs'}}) {
		my @options = grep { $_->[0] !~ /^bridge_/ && $_->[0] ne 'hwaddress' } @{$def->[3]};
		# Set the MAC once for both address families.
		push(@options, ['hwaddress', 'ether '.$p->{'mac'}]) if ($def->[1] eq 'inet');
		my ($port) = grep { $_->[1] eq $def->[1] } @{$p->{'port_defs'}};
		# Reuse the destination stanza when that address family already exists.
		if ($port) { net::modify_interface_def($source, $def->[1], $def->[2], \@options, 0, $port->[4]); }
		# Otherwise add the missing family in the port's existing file.
		else { net::new_interface_def($source, $def->[1], $def->[2], \@options, $p->{'port'}->{'file'}); }
		net::modify_interface_def($name, $def->[1], '', [], 1, $def->[4]);
		}
	# Replace only this name on startup lines, preserving unrelated interfaces.
	foreach my $file (sort keys %{$p->{'files'}}) {
		my $contents = read_file_contents($file);
		$contents =~ s{^(\s*(?:auto|allow-[\w-]+)[ \t]+)([^\n#]+)}{
			my ($prefix, $names) = ($1, $2);
			$names =~ s/(?<!\S)\Q$name\E(?!\S)/$source/g;
			$prefix.$names;
		}meg;
		write_file_contents($file, $contents);
		unflush_file_lines($file);
		}
	}
}

1;
