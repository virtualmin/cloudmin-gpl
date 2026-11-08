use strict;
use warnings;

use FindBin qw($Bin);
use Test::More;
use lib "$Bin/../lib";
use lib "$Bin/lib";
use CloudminTest;

use Cloudmin::Libvirt;

# Replace Sys::Virt objects so adapter tests need neither KVM nor a live daemon.
{
	package TestDomain;

	# new(class, fields) - Wraps guest fixture fields in a domain object.
	sub new
	{
	return bless($_[1], $_[0]);
	}

	# get_name(self) - Supplies the guest name for lookup and sorting.
	sub get_name
	{
	return $_[0]->{'name'};
	}

	# get_uuid_string(self) - Supplies the guest's stable identifier.
	sub get_uuid_string
	{
	return $_[0]->{'uuid'};
	}

	# is_active(self) - Supplies the fixture's active-domain flag.
	sub is_active
	{
	return $_[0]->{'active'};
	}

	# is_persistent(self) - Supplies the saved-definition flag.
	sub is_persistent
	{
	return $_[0]->{'persistent'};
	}

	# get_autostart(self) Supplies boot policy or simulates a failed lookup.
	sub get_autostart
	{
	die "Lookup failed\n" if ($_[0]->{'autostart_error'});
	return $_[0]->{'autostart'};
	}

	# get_info(self) - Supplies raw libvirt-style state and resource values.
	sub get_info
	{
	return $_[0]->{'info'};
	}

	# get_xml_description(self, [flags]) - Returns XML; ignores flags.
	sub get_xml_description
	{
	return $_[0]->{'xml'};
	}

	# get_interface_addresses(self, source, flags) Returns configured
	# address sources or simulates an unavailable lookup.
	sub get_interface_addresses
	{
	my ($self, $source) = @_;
	push(@{$self->{'address_calls'}}, $source);
	die "Address source unavailable\n"
		if ($self->{'address_errors'}->{$source});
	return @{$self->{'address_sources'}->{$source} || [ ]};
	}

	# set_agent_response_timeout(self, seconds, flags)
	# records bounded polling.
	sub set_agent_response_timeout
	{
	push(@{$_[0]->{'timeouts'}}, $_[1]);
	}

	# get_guest_info(self, types, flags) supplies a responding
	# or unavailable agent.
	sub get_guest_info
	{
	$_[0]->{'agent_calls'}++;
	die "Agent unavailable\n" if ($_[0]->{'agent_error'});
	return { 'os.name' => 'Fixture Linux' };
	}
	}

{
	package TestConnection;

	# new(class, fields) - Wraps fixture domains in a connection object.
	sub new
	{
	return bless($_[1], $_[0]);
	}

	# get_hostname(self) - Supplies a fixed host name without a live lookup.
	sub get_hostname
	{
	return 'kvm1.example.test';
	}

	# get_type(self) - Emulates the QEMU driver used by Cloudmin.
	sub get_type
	{
	return 'QEMU';
	}

	# get_version(self) - Supplies QEMU's version as a libvirt integer.
	sub get_version
	{
	return 10_002_000;
	}

	# get_library_version(self) - Uses a different version to catch mix-ups.
	sub get_library_version
	{
	return 11_010_000;
	}

	# list_all_domains(self, [flags]) - Returns all guests, ignoring flags.
	sub list_all_domains
	{
	return @{$_[0]->{'domains'}};
	}

	# list_all_storage_pools(self, [flags]) - Returns all pool fixtures.
	sub list_all_storage_pools
	{
	return @{$_[0]->{'pools'} || [ ]};
	}
	}

{
	package TestStorageVolume;

	# new(class, fields) - Wraps volume fixture fields in a volume object.
	sub new
	{
	return bless($_[1], $_[0]);
	}

	# get_name(self) - Supplies the volume name.
	sub get_name
	{
	return $_[0]->{'name'};
	}

	# get_key(self) - Supplies the backend's stable volume key.
	sub get_key
	{
	return $_[0]->{'key'};
	}

	# get_path(self) - Supplies the local volume path.
	sub get_path
	{
	return $_[0]->{'path'};
	}

	# get_info(self) - Supplies raw libvirt-style size values.
	sub get_info
	{
	return $_[0]->{'info'};
	}
	}

{
	package TestStoragePool;

	# new(class, fields) - Wraps pool fixture fields in a pool object.
	sub new
	{
	return bless($_[1], $_[0]);
	}

	# get_name(self) - Supplies the pool name.
	sub get_name
	{
	return $_[0]->{'name'};
	}

	# get_uuid_string(self) - Supplies the pool's stable identifier.
	sub get_uuid_string
	{
	return $_[0]->{'uuid'};
	}

	# is_active(self) - Supplies the active-pool flag.
	sub is_active
	{
	return $_[0]->{'active'};
	}

	# is_persistent(self) - Supplies the saved-definition flag.
	sub is_persistent
	{
	return $_[0]->{'persistent'};
	}

	# get_autostart(self) - Supplies the host-boot flag.
	sub get_autostart
	{
	return $_[0]->{'autostart'};
	}

	# get_info(self) - Supplies raw libvirt-style pool state and sizes.
	sub get_info
	{
	return $_[0]->{'info'};
	}

	# get_xml_description(self, [flags]) - Returns pool XML; ignores flags.
	sub get_xml_description
	{
	return $_[0]->{'xml'};
	}

	# list_all_volumes(self, [flags]) - Returns all volume fixtures.
	sub list_all_volumes
	{
	return @{$_[0]->{'volumes'} || [ ]};
	}
	}

# Guest fixtures use numeric libvirt states and memory values in KiB.
my $running = TestDomain->new(
	{
		'name' => 'web-01',
		'autostart' => 1,
		'uuid' => '11111111-2222-3333-4444-555555555555',
		'active' => 1,
		'persistent' => 1,
		'info' => {
			'state' => 1,
			'memory' => 2 * 1024 * 1024,
			'maxMem' => 4 * 1024 * 1024,
			'nrVirtCpu' => 4,
		},
		'xml' =>
			q{<domain><devices><interface><mac address='52:54:00:aa:bb:cc'/></interface></devices></domain>},
	});
# Vary the state, resources, and XML quoting for the inactive guest.
my $stopped = TestDomain->new(
	{
		'name' => 'db-01',
		'uuid' => 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
		'active' => 0,
		'persistent' => 1,
		'info' => {
			'state' => 5,
			'memory' => 1024 * 1024,
			'maxMem' => 2 * 1024 * 1024,
			'nrVirtCpu' => 2,
		},
		'xml' =>
			q{<domain><devices><interface><mac address="52:54:00:11:22:33"/></interface></devices></domain>},
	});
# The directory pool includes one sparse raw volume and current byte totals.
my $volume = TestStorageVolume->new({
	'name' => 'base.raw',
	'key' => '/var/lib/libvirt/images/base.raw',
	'path' => '/var/lib/libvirt/images/base.raw',
	'info' => {
		'type' => 0,
		'capacity' => 20 * 1024 * 1024,
		'allocation' => 4 * 1024 * 1024,
	},
});
my $pool = TestStoragePool->new(
	{
		'name' => 'default',
		'uuid' => '99999999-8888-7777-6666-555555555555',
		'active' => 1,
		'persistent' => 1,
		'autostart' => 1,
		'info' => {
			'state' => 2,
			'capacity' => 100 * 1024 * 1024,
			'allocation' => 40 * 1024 * 1024,
			'available' => 60 * 1024 * 1024,
		},
		'xml' =>
			q{<pool type='dir'><target><path>/var/lib/libvirt/images</path></target></pool>},
		'volumes' => [ $volume ],
	});
# Deliberately supply guests out of name order and count connection attempts.
my $connection = TestConnection->new({
	'domains' => [ $running, $stopped ],
	'pools' => [ $pool ],
});
my $factory_calls = 0;
my $adapter = Cloudmin::Libvirt->new(
	'uri' => 'test:///cloudmin',
	# connection_factory(uri, readonly) Checks connection options and
	# returns the shared test connection.
	'connection_factory' => sub {
		my ($uri, $readonly) = @_;
		$factory_calls++;
		is($uri, 'test:///cloudmin', 'factory receives configured URI');
		is($readonly, 1, 'connections are read-only by default');
		return $connection;
		},
);

# Verify the connection and keep libvirt and QEMU version reporting distinct.
is($adapter->uri(), 'test:///cloudmin', 'URI is exposed');
ok($adapter->probe()->{'ok'}, 'connection probe succeeds');
my $host = $adapter->get_host_info();
is($host->{'driver'}, 'QEMU', 'host driver is reported');
is($host->{'libvirt_version'}, '11.10.0', 'libvirt version is formatted');
is($host->{'hypervisor_version'}, '10.2.0', 'QEMU version is formatted');

# Local connections use Webmin's full hostname without substituting
# it for a remote host.
{
	no warnings 'redefine';
	local *Cloudmin::Libvirt::get_system_hostname =
		sub { return 'local.example.test'; };
	my $local = Cloudmin::Libvirt->new(uri => 'qemu:///system',
					   connection_factory => sub { $connection });
	is($local->get_host_info()->{'hostname'}, 'local.example.test',
	   'local host uses Webmin hostname resolution');
	my $remote = Cloudmin::Libvirt->new(uri => 'qemu+ssh://remote/system',
					    connection_factory => sub { $connection });
	is($remote->get_host_info()->{'hostname'}, 'kvm1.example.test',
	   'remote host keeps its libvirt hostname');
	ok(!defined($remote->get_host_info()->{'libvirt_layout'}),
	   'remote layout is not inferred from local binaries');
	}

# Inventory reads must reuse the connection and return guests sorted by name.
my $domains = $adapter->list_domains();
is($factory_calls, 1, 'connection is cached');
is_deeply(
	[ map { $_->{'name'} } @$domains ],
	[ 'db-01', 'web-01' ],
	'domains are sorted by name',
);
# Preserve guest state, CPU count, and interface identity during conversion.
is($domains->[0]->{'state'}, 'shutoff', 'inactive state is normalized');
is($domains->[1]->{'state'}, 'running', 'active state is normalized');
is($domains->[1]->{'vcpus'}, 4, 'CPU count is retained');
is($domains->[1]->{'autostart'}, 1, 'inventory exposes enabled autostart');
is($domains->[0]->{'autostart'}, 0, 'inventory exposes disabled autostart');
{
	local $running->{'autostart_error'} = 1;
	ok(!defined($adapter->list_domains()->[1]->{'autostart'}),
	   'failed boot-policy lookup is not presented as disabled');
	}
is_deeply(
	$domains->[1]->{'macs'},
	[ '52:54:00:aa:bb:cc' ],
	'MAC addresses are read from domain XML',
);

# Address discovery is opt-in; ordinary inventory and preflight skip probes.
ok(!$running->{'address_calls'}, 'ordinary inventory does not query addresses');
$running->{'address_sources'} = {
	1 => [ { name => 'eth0', hwaddr => '52:54:00:aa:bb:cc', addrs => [
		{ addr => '192.0.2.10', prefix => 24 },
		{ addr => '2001:db8::10', prefix => 64 },
	] } ],
	0 => [ { name => 'vnet0', hwaddr => '52:54:00:aa:bb:cc',
		 addrs => [ { addr => '192.0.2.11', prefix => 24 } ] } ],
	2 => [ { name => 'vnet0', hwaddr => '52:54:00:aa:bb:cc',
		 addrs => [ { addr => '192.0.2.11', prefix => 24 } ] } ],
};
my $addressed = $adapter->list_domains(0, 1);
is_deeply([ map { $_->{'address'} } @{$addressed->[1]->{'addresses'}} ],
	  [ '192.0.2.10', '2001:db8::10' ],
	  'overview inventory includes guest-agent IPv4 and IPv6');
is_deeply($running->{'address_calls'}, [ 1 ],
	  'an agent response does not require fallback queries');
is_deeply($addressed->[0]->{'addresses'}, [ ],
	  'stopped guest has no reported addresses');
ok(!$stopped->{'address_calls'},
   'stopped guest is not queried for old addresses');

# Guests without an agent still expose DHCP addresses without
# duplicate ARP entries.
$running->{'address_errors'} = { 1 => 1 };
$addressed = $adapter->list_domains(0, 1);
is_deeply([ map { $_->{'address'} } @{$addressed->[1]->{'addresses'}} ],
	  [ '192.0.2.11' ], 'DHCP and ARP fallback addresses are deduplicated');
is($addressed->[1]->{'addresses'}->[0]->{'source'}, 'lease',
   'fallback retains its address source');
$running->{'address_errors'} = { 0 => 1, 1 => 1, 2 => 1 };
$addressed = $adapter->list_domains(0, 1);
is_deeply($addressed->[1]->{'addresses'}, [ ],
	  'unavailable sources leave the guest visible without an address');

# Storage discovery must identify pool capabilities and nested volumes.
my $pools = $adapter->list_storage_pools(1);
is(scalar(@$pools), 1, 'one storage pool is returned');
is($pools->[0]->{'type'}, 'dir', 'directory backend is read from pool XML');
is($pools->[0]->{'state'}, 'running', 'pool state is normalized');
is($pools->[0]->{'target'}, '/var/lib/libvirt/images',
   'pool target path is retained');
is($pools->[0]->{'provisioning'}, 'managed',
   'directory volumes are marked as managed');
is($pools->[0]->{'volume_count'}, 1, 'pool volumes are counted');
is($pools->[0]->{'volumes'}->[0]->{'allocation'}, 4 * 1024 * 1024,
   'volume allocation is retained');

# Local filesystem counters replace stale libvirt totals without counting
# reserved blocks as either used data or available space.
{
	no warnings 'redefine';
	my @paths;
	my $space = { capacity => 1000, allocation => 400, available => 500 };
	local *Cloudmin::Libvirt::filesystem_space =
		sub { push(@paths, $_[0]); return $space };
	local $adapter->{'uri'} = 'qemu:///system';
	foreach my $type (qw(dir fs netfs)) {
		local $pool->{'xml'} =
			"<pool type='$type'><target><path>/fixture</path></target></pool>";
		my $record = $adapter->get_storage_pool_record($pool);
		is_deeply([ @$record{qw(capacity allocation available)} ],
			  [ 1000, 400, 500 ],
			  "$type inventory uses current filesystem counters and excludes reserves");
		}
	is_deeply(\@paths, [ '/fixture', '/fixture', '/fixture' ],
		  'reads the pool target filesystem');
	# Remote, inactive and block pools must never read a
	# local lookalike path.
	local *Cloudmin::Libvirt::filesystem_space =
		sub { die "unexpected local filesystem read\n" };
	{
		local $adapter->{'uri'} = 'qemu+ssh://remote/system';
		is($adapter->get_storage_pool_record($pool)->{'available'},
		   $pool->{'info'}->{'available'},
		   'remote inventory retains native counters');
		}
	{
		local $pool->{'active'} = 0;
		is($adapter->get_storage_pool_record($pool)->{'capacity'},
		   0,
		   'inactive pools are not measured');
		}
	{
		local $pool->{'xml'} =
			q{<pool type='logical'><target><path>/fixture</path></target></pool>};
		is($adapter->get_storage_pool_record($pool)->{'capacity'},
		   $pool->{'info'}->{'capacity'},
		   'block pools retain native counters');
		}
	# An unavailable filesystem read retains the existing native fallback.
	local *Cloudmin::Libvirt::filesystem_space = sub { undef };
	is($adapter->get_storage_pool_record($pool)->{'available'},
	   $pool->{'info'}->{'available'},
	   'failed filesystem reads preserve native inventory');
	}

# A failed connection must return a readable probe error, not throw it.
my $failed = Cloudmin::Libvirt->new(
	# connection_factory(uri, readonly) Ignores the connection options and
	# simulates a refused connection.
	'connection_factory' => sub { die "connection refused\n"; },
);
my $probe = $failed->probe();
ok(!$probe->{'ok'}, 'failed connection probe is reported');
is($probe->{'error'}, 'connection refused', 'connection errors are normalized');

# Webmin's HTML escaping uses numeric entities that are also valid XML.
my $xml_value = q{disk='a&b' <qcow2> "quoted"};
is(
	Cloudmin::Libvirt::decode_xml_text(
		Cloudmin::Libvirt::xml_escape($xml_value)),
	$xml_value,
	'XML escaping and decoding preserve quotes, equals and markup');
is(Cloudmin::Libvirt::decode_xml_text('&amp;lt;'), '&lt;',
   'XML decoding preserves literal entity text');

# The console opens VNC, so a guest with several displays must report it.
my $displays = Cloudmin::Libvirt::extract_graphics(
	q{<devices><graphics type='spice' autoport='yes'/>}.
	q{<graphics type='vnc' port='5901' listen='127.0.0.1'/></devices>});
is_deeply([ @{$displays}{qw(type port listen)} ], [ 'vnc', 5901, '127.0.0.1' ],
	  'VNC display is preferred over an earlier graphics device');
is(
	Cloudmin::Libvirt::extract_graphics(
		q{<devices><graphics type='spice'/></devices>})->{'type'},
	'spice', 'first display is reported when no VNC display exists');
ok(!defined(Cloudmin::Libvirt::extract_graphics('<devices/>')),
   'headless guest has no display');

# Live status must not confuse power with guest-agent or SSH readiness.
$running->{'address_calls'} = [ ];
my $health = $adapter->get_guest_status($running->{'uuid'});
is($health->{'agent'}, 'responding',
   'agent health requires an actual guest reply');
ok(!@{$running->{'timeouts'} || [ ]},
   'status reads do not change the shared domain agent timeout');
$running->{'agent_error'} = 1;
$running->{'address_calls'} = [ ];
$health = $adapter->get_guest_status($running->{'uuid'});
is($health->{'agent'}, 'unavailable',
   'agent failure is not called booting or ready');
ok(!grep({ $_ == 1 } @{$running->{'address_calls'}}),
   'failed agent is not queried again for addresses');
my $calls = $stopped->{'agent_calls'} || 0;
$health = $adapter->get_guest_status($stopped->{'uuid'});
is($stopped->{'agent_calls'} || 0, $calls,
   'stopped guests cause no agent query');
is_deeply($health->{'addresses'}, [ ],
	  'stopped guests never retain stale leases');
$running->{'address_calls'} = [ ];
$adapter->get_domain($running->{'uuid'}, 1);
is_deeply($running->{'address_calls'}, [ ],
	  'initial details render without waiting on agent addresses');
# Empty, enabled bridges are usable before a guest supplies carrier.
{
	require File::Temp;
	require File::Path;
	my $dir = File::Temp::tempdir(CLEANUP => 1);
	for my $item ( [ 'empty0', '0x1003' ], [ 'disabled0', '0x1002' ],
		       [ 'owned0', '0x1003' ] ) {
		File::Path::make_path("$dir/$item->[0]/bridge");
		open(my $fh, '>', "$dir/$item->[0]/flags") or die $!;
		print { $fh } "$item->[1]\n";
		close($fh);
		open($fh, '>', "$dir/$item->[0]/operstate") or die $!;
		print { $fh } "down\n";
		close($fh);
		}
	my $adapter = Cloudmin::Libvirt->new(sys_net => $dir);
	is_deeply(
		$adapter->list_host_bridges([ { bridge => 'owned0' } ]),
		[ { name => 'disabled0', state => 'down' },
		  { name => 'empty0', state => 'up' } ],
		'bridge selection uses administrative state and excludes libvirt-owned bridges');
	}

# Model libvirt exceptions so only the documented transient cases are retried.
{
	package Sys::Virt::Error;

	# code(self) - Supplies the numeric libvirt error code.
	sub code
	{
	return $_[0]->{'code'};
	}

	# message(self) - Supplies the libvirt diagnostic
	# without string wrapping.
	sub message
	{
	return $_[0]->{'message'};
	}
	package BusyPool;

	# refresh(self) - Replays one pending clone followed
	# by a normal refresh.
	sub refresh
	{
	$_[0]->{'calls'}++;
	my $error = shift(@{$_[0]->{'errors'}});
	die $error if ($error);
	}
	}
my $busy = bless({ code => 1,
		   message =>
			   "internal error: pool 'default' has asynchronous jobs running." },
		 'Sys::Virt::Error');
my $refresh = bless({ errors => [ $busy ] }, 'BusyPool');
ok(eval { Cloudmin::Libvirt::refresh_pool($refresh); 1 },
   'pool refresh waits for an unrelated clone to finish');
is($refresh->{'calls'}, 2, 'busy refresh is retried');
$refresh = bless({ errors => [ $busy ] }, 'BusyPool');
ok(!eval { Cloudmin::Libvirt::refresh_pool($refresh, 0); 1 },
   'pool refresh stops at its deadline');
is($@, $busy, 'timeout preserves the libvirt error');
is($refresh->{'calls'}, 1, 'expired refresh does not keep retrying');
for my $error ( 'Connection failed', bless({ code => 1,
					     message => 'Other internal failure' },
					   'Sys::Virt::Error') ) {
	$refresh = bless({ errors => [ $error ] }, 'BusyPool');
	ok(!eval { Cloudmin::Libvirt::refresh_pool($refresh); 1 },
	   'unrelated refresh failure propagates');
	is($refresh->{'calls'}, 1, 'unrelated error is not retried');
	}
# A disappearing domain must not hide real preflight errors from other guests.
{
	no warnings 'redefine';
	my $error = bless({ code => 42 }, 'Sys::Virt::Error');
	local *TestDomain::get_info = sub {
		die $error if ($_[0] == $stopped);
		return $_[0]->{'info'};
		};
	is_deeply([ map { $_->{'uuid'} } @{$adapter->list_domains(1)} ],
		  [ $running->{'uuid'} ],
		  'undefined guest is omitted from preflight');
	$error = bless({ code => 1 }, 'Sys::Virt::Error');
	ok(!eval { $adapter->list_domains(1); 1 },
	   'other domain failures still stop strict preflight');
	is($@, $error, 'strict preflight preserves the original error');
	}
# Firmware ROMs and video models must not be mistaken for EFI or a CPU model.
for my $case ( [ 'rom', 'bios' ], [ 'pflash', 'efi' ] ) {
	my $domain =
		TestDomain->new({ xml =>
					  '<domain><os><type arch="x86_64">hvm</type>'.
					  '<loader type="'.$case->[0].
					  '">/firmware</loader></os><cpu mode="host-passthrough"/>'.
					  '<devices><video><model type="virtio"/></video></devices></domain>' });
	my $record = $adapter->complete_domain($domain, { persistent => 1 }, 1);
	is($record->{firmware}, $case->[1],
	   "$case->[0] loader has the correct firmware type");
	is($record->{cpu_model}, '',
	   'self-closing CPU does not capture a video model');
	}
# Inventory compares normalized public settings and retains unknown reads.
{
	no warnings 'redefine';
	my $live =
		q{<domain><vcpu current="2">4</vcpu><memory unit="MiB">1024</memory><currentMemory unit="MiB">512</currentMemory></domain>};
	my $saved = $live;
	$saved =~ s/>4<\/vcpu>/>6<\/vcpu>/;
	local *TestDomain::get_xml_description = sub { return ($_[1] || 0) & 2
		? $saved
		: $live; };
	is_deeply($adapter->get_domain_record($running)->{'pending'},
		  { cpu_limit => { running => 4, saved => 6 } },
		  'overview receives only changed public resources');
	$saved = $live;
	$saved =~ s{<memory unit="MiB">1024</memory>}{<memory unit="KiB">1048576</memory>};
	is_deeply($adapter->get_domain_record($running)->{'pending'}, { },
		  'equivalent memory units are not pending');
	# Runtime bridge, port IDs and tap names do not alter
	# a network attachment.
	my $nic =
		'<interface type="network"><mac address="52:54:00:11:22:33"/>'.
		'<source network="default"/><model type="virtio"/></interface>';
	$live =~ s{</domain>}{<devices>$nic</devices></domain>};
	$saved = $live;
	my $runtime =
		'<source network="default" bridge="virbr0" portid="runtime"/>'.
		'<target dev="vnet3"/><actual type="bridge"><source bridge="virbr0"/></actual>';
	$live =~ s{<source network="default"/>}{$runtime};
	is_deeply($adapter->get_domain_record($running)->{'pending'}, { },
		  'runtime network details do not require a power cycle');
	# A different configured source must remain pending
	# until the guest uses it.
	$saved =~ s{type="network"}{type="bridge"};
	$saved =~ s{network="default"}{bridge="br-lan"};
	is_deeply($adapter->get_domain_record($running)->{'pending'},
		  { networks => {
			  running => [ { mac => '52:54:00:11:22:33',
					 type => 'network',
					 source => 'default' } ],
			  saved => [ { mac => '52:54:00:11:22:33',
				       type => 'bridge',
				       source => 'br-lan' } ] } },
		  'a saved network-to-bridge move requires a power cycle');
	# Once both definitions agree, no attachment change remains to report.
	$live = $saved;
	is_deeply($adapter->get_domain_record($running)->{'pending'}, { },
		  'applied network attachment clears the warning');
	# Losing inactive XML must preserve an unknown result
	# rather than clear badges.
	local *TestDomain::get_xml_description =
		sub { die "Inactive XML unavailable\n" if $_[1]; return $live; };
	ok(!defined($adapter->get_domain_record($running)->{'pending'}),
	   'failed comparison remains unknown');
	}

# Metadata ownership follows its namespace, not the spelling of its prefix.
{
	my $job = 'a' x 32;
	my $body = "<job>$job</job><username>alice&amp;bob</username>";
	my $default =
		qq{<domain><metadata><vm xmlns="urn:cloudmin:vm:1">$body</vm></metadata></domain>};
	is_deeply(Cloudmin::Libvirt::extract_metadata($default),
		  { job => $job, username => 'alice&bob' },
		  'default namespace and XML text are decoded');
	my $prefixed = $default;
	$prefixed =~ s{xmlns=}{xmlns:ns0=};
	$prefixed =~ s{<(\/?)(vm|job|username)(?=[\s>])}{<$1ns0:$2}g;
	is_deeply(Cloudmin::Libvirt::extract_metadata($prefixed),
		  { job => $job, username => 'alice&bob' },
		  'rewritten prefix preserves creation ownership');
	# Foreign namespaces, duplicate markers and nested
	# fields cannot claim a VM.
	for my $case (
		[ 'foreign namespace',
		  $default =~ s/urn:cloudmin:vm:1/urn:other/r ],
		[ 'missing namespace',
		  $default =~ s/ xmlns="urn:cloudmin:vm:1"//r ],
		[ 'duplicate field',
		  $default =~ s{</job>}{</job><job>$job</job>}r ],
		[ 'nested field', $default =~ s{<job>}{<job><value/>}r ],
		[ 'duplicate marker',
		  $default =~ s{</metadata>}{<vm xmlns="urn:cloudmin:vm:1">$body</vm></metadata>}r ],
		[ 'wrong location', $default =~ s{metadata}{devices}gr ],
		[ 'malformed XML', '<domain><metadata>' ],
	) {
		is_deeply(Cloudmin::Libvirt::extract_metadata($case->[1]), { },
			  $case->[0].' does not establish ownership');
		}
	}

# Disk roles come from creation metadata and survive snapshot backing chains.
{
	my $job = 'a' x 32;
	my $xml =
		qq{<domain><metadata><cloudmin:vm xmlns:cloudmin="urn:cloudmin:vm:1"><cloudmin:job>$job</cloudmin:job></cloudmin:vm></metadata><devices>
<disk type="file" device="disk"><source file="/pool/overlay.qcow2"/><target dev="vdz"/>
<backingStore><source file="/pool/cloudmin-test-system-$job.qcow2"/></backingStore></disk>
<disk type="volume" device="disk"><source pool="default" volume="cloudmin-test-seed-$job.1791549256"/><target dev="vdb"/><readonly/></disk>
<disk type="file" device="disk"><source file="/pool/data.qcow2"/><target dev="vdc"/></disk>
<disk device="cdrom"><target dev="sda"/><readonly/></disk></devices></domain>};
	my @disks = Cloudmin::Libvirt::extract_disks($xml);
	is_deeply(
		[ map { $_->{'role'} } @disks ], [ qw(system seed data cdrom) ],
		'shared inventory recognizes system, restored seed, data and CD media');
	is($disks[0]->{'target'}, 'vdz',
	   'system role does not depend on a vda target');
	is($disks[0]->{'path'}, '/pool/overlay.qcow2',
	   'display roles never replace the actual disk path');
	# Rewriting the namespace prefix must preserve friendly disk names too.
	$xml =~ s{(</?)cloudmin:}{$1ns0:}g;
	$xml =~ s/xmlns:cloudmin=/xmlns:ns0=/g;
	@disks = Cloudmin::Libvirt::extract_disks($xml);
	is_deeply([ map { $_->{'role'} } @disks ],
		  [ qw(system seed data cdrom) ],
		  'disk roles survive a namespace prefix change');
	# Native disks keep their roles through both LVM device naming schemes.
	for my $prefix ( "/dev/guests/cloudmin-$job-",
			 "/dev/mapper/guest--vg-cloudmin--$job--" ) {
		my $native =
			qq{<domain><metadata><vm xmlns="urn:cloudmin:vm:1"><job>$job</job></vm></metadata><devices>
<disk type="block" device="disk"><source dev="${prefix}system"/><target dev="vda"/></disk>
<disk type="block" device="disk"><source dev="${prefix}seed"/><target dev="vdb"/><readonly/></disk>
</devices></domain>};
		is_deeply(
			[ map {
				$_->{'role'} } Cloudmin::Libvirt::extract_disks(
					$native) ], [ qw(system seed) ],
			'LVM system and seed roles follow creation ownership');
		}
	# Matching filenames alone are insufficient without
	# Cloudmin ownership metadata.
	$xml =~ s{<metadata>.*?</metadata>}{}s;
	@disks = Cloudmin::Libvirt::extract_disks($xml);
	is_deeply(
		[ map { $_->{'role'} } @disks ], [ qw(disk disk disk cdrom) ],
		'external guests retain generic disk names instead of guessed OS roles');
	}

done_testing();
