use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib", "$Bin/../lib";
use CloudminTest;
use Test::More;
use JSON::PP ();
use Cloudmin::Networks;
use Cloudmin::HostNetwork;
use File::Temp qw(tempdir);
use WebminCore;

{
	package NetworkConnection;

	# list_all_networks(self, [flags]) supplies the
	# fixture network inventory.

	sub list_all_networks
	{
	return @{$_[0]->{'networks'} || [ ]};
	}

	# list_all_domains(self, [flags]) supplies guest references to networks.

	sub list_all_domains
	{
	return @{$_[0]->{'domains'} || [ ]};
	}

	# define_network(self, xml, [flags]) records a
	# definition without libvirt.

	sub define_network
	{
	my ($self, $xml) = @_;
	my $net =
		bless({ xml => $xml,
			uuid => '11111111-2222-3333-4444-555555555555',
			name => 'fixture', fail => $self->{'fail'} },
		      'NetworkObject');
	$self->{'created'} = $net;
	return $net;
	}
	package NetworkObject;

	# get_xml_description(self, [flags]) exposes the stored network XML.

	sub get_xml_description
	{
	return $_[0]->{'xml'};
	}

	# get_uuid_string(self) identifies the fixture network.

	sub get_uuid_string
	{
	return $_[0]->{'uuid'};
	}

	# get_name(self) exposes the name recorded during definition.

	sub get_name
	{
	return $_[0]->{'name'};
	}

	# is_active(self) reports the state changed by create and destroy.

	sub is_active
	{
	return $_[0]->{'active'} || 0;
	}

	# is_persistent(self) models a saved network definition.

	sub is_persistent
	{
	return 1;
	}

	# get_autostart(self) reads the simulated start-at-boot setting.

	sub get_autostart
	{
	return $_[0]->{'autostart'} || 0;
	}

	# set_autostart(self, enabled) records a start-at-boot change.

	sub set_autostart
	{
	$_[0]->{'autostart'} = $_[1];
	}

	# create(self, [flags]) simulates successful activation
	# or a native failure.

	sub create
	{
	die "Start refused\n"
		if $_[0]->{'fail'}; $_[0]->{'active'} = 1;
	}

	# destroy(self) records a stop without changing the saved definition.

	sub destroy
	{
	$_[0]->{'active'} = 0; $_[0]->{'destroyed'}++;
	}

	# undefine(self) records removal of the saved definition.

	sub undefine
	{
	$_[0]->{'undefined'}++;
	}
	package NetworkJobs;

	# lock(self, name, callback) runs the callback without real locking.

	sub lock
	{
	return $_[2]->();
	}

	# list(self, [owner], [active]) returns the configured pending jobs.

	sub list
	{
	return $_[0]->{'active'} || [ ];
	}
	package NetworkHost;

	# inventory(self) supplies host interfaces and subnets for validation.

	sub inventory
	{
	return $_[0]->{'data'};
	}

	# pending(self) simulates an unfinished host network change.

	sub pending
	{
	return $_[0]->{'pending'};
	}

	# mask_prefix(mask) uses the production netmask parser.

	sub mask_prefix
	{
	return Cloudmin::HostNetwork::mask_prefix(@_);
	}
	}

my $connection = bless({ }, 'NetworkConnection');
my $adapter = Cloudmin::Libvirt->new(connection_factory => sub { $connection });
my $host = bless({ data => { interfaces => [
	{ name => 'eth0', active => 1 },
	{ name => 'brlan', active => 1, bridge => 1 } ],
			     subnets => [ '192.168.96.0/24',
					  '2001:db8:1::/64' ],
			     management => [ 'eth0' ] } }, 'NetworkHost');
my $jobs = bless({ }, 'NetworkJobs');
my $service =
	Cloudmin::Networks->new(adapter => $adapter, host => $host,
				jobs => $jobs);
no warnings 'redefine';
local *Cloudmin::Libvirt::log_call = sub { };
my %input = ( name => 'fixture', mode => 'nat', ipv4 => '192.168.150.1/24',
	      dhcp => 1, dhcp_start => '192.168.150.10',
	      dhcp_end => '192.168.150.99',
	      autostart => 1 );

# Webmin accepts noncontiguous IPv4 masks; bridge conversion must reject them.
for my $case ( [ '0.0.0.0', 0 ], [ '128.0.0.0', 1 ], [ '255.255.128.0', 17 ],
	       [ '255.255.255.0', 24 ], [ '255.255.255.254', 31 ],
	       [ '255.255.255.255', 32 ] ) {
	is($host->mask_prefix($case->[0]), $case->[1],
	   'contiguous mask converts to /'.$case->[1]);
	}
for my $mask ( '255.0.255.0', '255.255.255.1', '255.255.256.0',
	       '255.255.255.0.', '255.255.255', '24', 'garbage' ) {
	ok(!eval { $host->mask_prefix($mask); 1 },
	   'invalid mask is rejected: '.$mask);
	like($@, qr/Invalid network mask/, 'mask error is explicit');
	}

# Decode command output through Webmin without losing read-only command flags.
{
	my (@command, @flags);
	my $output = '[{"ifname":"eth0","mtu":1500,"dynamic":true}]';
	local *Cloudmin::HostNetwork::command = sub {
		my ($self, $argv, @options) = @_;
		@command = @$argv;
		@flags = @options;
		return $output;
		};
	my $links = Cloudmin::HostNetwork->new()->ip_json('address', 'show');
	is_deeply(\@command, [ 'ip', '-j', 'address', 'show' ],
		  'structured inventory command is unchanged');
	is_deeply(\@flags, [ 1, 1 ],
		  'inventory remains quiet and safe for read-only users');
	is($links->[0]->{'mtu'}, 1500,
	   'Webmin decoder preserves numeric fields');
	is(JSON::PP->new->canonical->encode($links),
	   '[{"dynamic":true,"ifname":"eth0","mtu":1500}]',
	   'decoded booleans remain compatible with canonical JSON encoding');
	$output = 'invalid JSON';
	ok(!eval { Cloudmin::HostNetwork->new()->ip_json('address',
							 'show'); 1 },
	   'malformed command output is rejected');
	}

# Subnet comparisons must account for containment and every IPv6 bit.
ok(Cloudmin::Networks::overlap(Cloudmin::Networks::cidr('10.0.0.1/16'),
			       Cloudmin::Networks::cidr('10.0.3.1/24')),
   'IPv4 containment overlaps');
ok(!Cloudmin::Networks::overlap(Cloudmin::Networks::cidr('2001:db8:1::1/64'),
				Cloudmin::Networks::cidr('2001:db8:2::1/64')),
   'distinct IPv6 subnets do not overlap');
for my $value ( 'host/24', '1.2.3.4/33', '::1/129', '1.2.3.4/0',
		"1.2.3.4/24\n" ) {
	ok(!eval { Cloudmin::Networks::cidr($value); 1 },
	   "invalid CIDR rejected: $value");
	}
for my $case (
	[ { name => '../escape' }, qr/name/ ], [ { mode => 'bridge' },
						 qr/Select/ ],
	[ { ipv4 => '192.168.96.9/24' }, qr/overlaps/ ],
	[ { ipv6 => '2001:db8:1::1/64' }, qr/overlaps/ ],
	[ { ipv4 => '192.168.150.0/24' }, qr/gateway/ ],
	[ { ipv4 => '127.0.0.1/24' }, qr/unicast/ ],
	[ { ipv4 => '224.0.0.1/24' }, qr/unicast/ ],
	[ { ipv6 => 'fe80::1/64' }, qr/unicast/ ],
	[ { dhcp_end => '192.168.151.20' }, qr/DHCP/ ],
	[ { dhcp_start => '192.168.150.0' }, qr/DHCP/ ],
	[ { dhcp_start => '192.168.150.90', dhcp_end => '192.168.150.10' },
	  qr/range/ ],
	[ { dhcp_start => '192.168.150.1' }, qr/DHCP/ ],
	[ { uplink => 'missing' }, qr/uplink/ ],
	[ { mode => 'isolated', uplink => 'eth0' }, qr/isolated/ ],
) {
	ok(!eval { $service->prepare_network({ %input, %{$case->[0]} }); 1 },
	   'invalid network rejected');
	like($@, $case->[1], 'validation explains the problem');
	}
for my $mode (qw(nat route isolated)) {
	my $p =
		$service->prepare_network({ %input, mode => $mode, ipv6 =>
									   '2001:db8:2::1/64' });
	my $doc = Cloudmin::Libvirt::parse_xml_document($p->{'xml'});
	is($doc->findvalue('/network/forward/@mode'), $mode eq 'isolated'
		? ''
		: $mode, 'requested forwarding mode');
	is($doc->findvalue('/network/ip[not(@family)]/dhcp/range/@start'),
	   '192.168.150.10', 'DHCP range written');
	is($doc->findvalue('/network/ip[@family="ipv6"]/@address'),
	   '2001:db8:2::1', 'IPv6 gateway written');
	is($doc->findvalue('/network/forward/nat/@ipv6'), $mode eq 'nat'
		? 'yes'
		: '', 'IPv6 follows selected forwarding policy');
	}
is($service->create(\%input), 'fixture', 'network is created');
ok($connection->{'created'}->{'active'} &&
   $connection->{'created'}->{'autostart'},
   'active and persistent boot policy');
$connection->{'fail'} = 1;
ok(!eval { $service->create(\%input); 1 }, 'start failure propagates');
ok($connection->{'created'}->{'undefined'},
   'failed creation removes only its own definition');
delete($connection->{'fail'});
$host->{'pending'} = 1;
ok(!eval { $service->create(\%input); 1 },
   'bridge confirmation blocks new network changes');
delete($host->{'pending'});
$jobs->{'active'} = [ { state => 'queued' } ];
ok(!eval { $service->create(\%input); 1 },
   'queued VM operations protect their network references');
delete($jobs->{'active'});

# Both persistent and active XML references must protect stop/delete operations.
my $net =
	bless({ name => 'existing',
		uuid => '11111111-2222-3333-4444-555555555555',
		active => 1,
		xml =>
			'<network><name>existing</name><bridge name="virbr5"/><forward mode="nat"/><ip address="10.10.1.1" prefix="24"/></network>' }, 'NetworkObject');
$connection->{'networks'} = [ $net ];
my $vm = bless({ name => 'guest',
		 uuid => '22222222-2222-3333-4444-555555555555',
		 xml =>
			 '<domain><devices><interface type="bridge"><source bridge="virbr5"/></interface></devices></domain>' }, 'NetworkObject');
$connection->{'domains'} = [ $vm ];
my $revision = Digest::SHA::sha256_hex($net->{'xml'});
ok(!eval { $service->change('stop', $net->{'uuid'}, $revision); 1 },
   'stopped guest with direct bridge attachment protects network');
like($@, qr/Detach/, 'attachment error explains next step');
is(scalar(@{$service->inventory()->{'networks'}->[0]->{'guests'}}), 1,
   'inventory associates bridge and network users');
# Legacy libvirt netmasks and explicit prefixes should look the same in the UI.
{
	local $net->{'xml'} =
		'<network><name>existing</name><ip address="10.10.1.1" netmask="255.255.255.0"/><ip family="ipv6" address="fd00::1" prefix="64"/></network>';
	is_deeply($service->inventory()->{'networks'}->[0]->{'addresses'},
		  [ '10.10.1.1/24', 'fd00::1/64' ],
		  'inventory uses readable IPv4 and IPv6 prefixes');
	}
$connection->{'domains'} = [ ];
# A physical port cannot move while a guest refers to it directly.
$vm->{'xml'} =
	'<domain><devices><interface type="direct"><source dev="eth0"/></interface></devices></domain>';
$connection->{'domains'} = [ $vm ];
ok(!eval { $service->prepare_bridge('br0', 'eth0'); 1 },
   'direct guest interface blocks bridge conversion');
like($@, qr/used directly/, 'direct interface refusal is explained');
$connection->{'domains'} = [ ];
{
	local $net->{'xml'} =
		'<network><name>existing</name><forward mode="nat" dev="eth0"/></network>';
	ok(!eval { $service->prepare_bridge('br0', 'eth0'); 1 },
	   'explicit forwarding uplink blocks bridge conversion');
	like($@, qr/explicit uplink/, 'uplink refusal is explained');
	}
ok(!eval { $service->change('stop', $net->{'uuid'}, 'stale'); 1 },
   'stale form rejected');
$service->change('stop', $net->{'uuid'}, $revision);
ok(!$net->{'active'}, 'unused network can stop');
{
	local $host->{'data'}->{'subnets'} = [ '10.10.1.0/24' ];
	ok(!eval { $service->change('start', $net->{'uuid'}, $revision); 1 },
	   'saved network cannot overlap a host route when restarted');
	}
$service->change('delete', $net->{'uuid'}, $revision);
ok($net->{'undefined'}, 'inactive unused network can be removed');

# Private state exposes only progress, while boot rollback restores exact files.
my $dir = tempdir(CLEANUP => 1);
my $file = "$dir/config";
# Rollback must preserve even non-UTF-8 bytes in an existing configuration file.
my $original = "old settings # \x80\xe9\xff\n";
WebminCore::write_file_contents($file, $original);
my $bridge =
	Cloudmin::HostNetwork->new(directory => "$dir/state", jobs => $jobs);
# Unit lifecycle calls are recorded; workstation services are never touched.
my @guard_calls;
local *Cloudmin::HostNetwork::unit = sub { push(@guard_calls,
						[ @_[1 .. $#_] ]); };
my $files = $bridge->snapshot([ $file, "$dir/new" ]);
WebminCore::write_file_contents($file, "new settings\n");
WebminCore::write_file_contents("$dir/new", "created\n");
my $record =
	{ id => 'fixture', name => 'br0', source => 'eth0', state => 'applying',
	  owner => 'fixture', files => $files, saved =>
						       { private => 'do not expose' } };
$bridge->write_state($record);
is(WebminCore::read_file_contents("$dir/state/bridge.json"),
   JSON::PP->new->canonical->encode($record),
   'bridge journal preserves the existing compact byte encoding');
is((stat("$dir/state/bridge.json"))[2] & 0777, 0600,
   'journal with network backups stays private');
# Public status combines the private journal with the recovery worker's state.
{
	my $unit = "ActiveState=failed\nJob=\n";
	my (@command, @flags);
	# command(self, argv, [quiet], [safe]) records
	# queries and returns status.
	local *Cloudmin::HostNetwork::command = sub {
		@command = @{$_[1]}; @flags = @_[2 .. $#_];
		return $unit;
		};
	my $public = $bridge->public_state();
	ok(!exists($public->{'files'}) && !exists($public->{'saved'}),
	   'status omits private backups');
	is_deeply(\@command,
		  [ 'systemctl', 'show', 'cloudmin-network-rollback.service',
		    '--property=ActiveState,Job' ],
		  'recovery status includes queued jobs');
	is_deeply(\@flags, [ 1, 1 ],
		  'worker status is quiet and safe for read-only users');
	# Retrying a failed transaction changes only its public
	# status until it ends.
	$record->{'state'} = 'rollback_failed';
	$record->{'error'} = 'Previous address is missing';
	$bridge->write_state($record);
	for my $case ( [ "ActiveState=failed\nJob=42\n", 'rolling_back' ],
		       [ "ActiveState=activating\nJob=42\n", 'rolling_back' ],
		       [ "ActiveState=deactivating\nJob=\n", 'rolling_back' ],
		       [ "ActiveState=failed\nJob=\n", 'rollback_failed' ],
		       [ "ActiveState=inactive\nJob=0\n",
			 'rollback_failed' ] ) {
		$unit = $case->[0];
		$public = $bridge->public_state();
		is($public->{'state'}, $case->[1],
		   'queued, running and stopped recovery are distinguished');
		is(exists($public->{'error'}) ? 1 : 0,
		   $case->[1] eq 'rollback_failed' ? 1 : 0,
		   'previous failure is hidden only while recovery is running');
		}
	is($bridge->read_state()->{'state'}, 'rollback_failed',
	   'status reads leave recovery journal unchanged');
	# command(self, argv, [quiet], [safe]) completes
	# recovery during the query.
	local *Cloudmin::HostNetwork::command = sub {
		$bridge->write_state({ %$record, state => 'rolled_back' });
		return "ActiveState=activating\nJob=42\n";
		};
	is($bridge->public_state()->{'state'}, 'rolled_back',
	   'latest completed result wins over worker status');
	# A status-query failure must retain the original
	# diagnostic and retry action.
	$bridge->write_state($record);
	# command(self, argv, [quiet], [safe]) simulates a failed status query.
	local *Cloudmin::HostNetwork::command =
		sub { die "Service status unavailable\n"; };
	is($bridge->public_state()->{'state'}, 'rollback_failed',
	   'unavailable worker status does not hide a failure');
	$record->{'state'} = 'applying';
	$bridge->write_state($record);
	}
{
	local *Cloudmin::HostNetwork::backend = sub { 'fixture' };
	local *Cloudmin::HostNetwork::activate =
		sub { die 'boot recovery must not activate networking'; };
	is($bridge->rollback(1), 'br0',
	   'boot recovery restores saved configuration');
	}
is(WebminCore::read_file_contents($file), $original,
   'original bytes restored without UTF-8 decoding');
ok(!-e "$dir/new", 'new bridge file removed');
ok(!$bridge->pending(), 'successful rollback clears mutation block');
is($bridge->read_state()->{'state'}, 'rolled_back', 'rollback result persists');
ok(!exists($bridge->read_state()->{'error'}),
   'successful recovery clears the previous error');
is_deeply(\@guard_calls, [ [ 'stop_unit', 'cloudmin-network-rollback.timer' ],
			   [ 'disable_unit',
			     'cloudmin-network-boot.service' ] ],
	  'completed rollback disarms both recovery guards');
# Confirmation checks both ownership and the deadline before accepting changes.
$record->{'state'} = 'confirm';
$record->{'deadline'} = time() + 60;
$bridge->write_state($record);
ok(!eval { $bridge->confirm('fixture', 'other'); 1 },
   'another user cannot confirm');
is($bridge->read_state()->{'state'}, 'confirm',
   'failed confirmation leaves recovery armed');
$record->{'deadline'} = time() - 1;
$bridge->write_state($record);
ok(!eval { $bridge->confirm('fixture', 'fixture'); 1 },
   'expired bridge cannot be confirmed');
like($@, qr/expired/, 'expired confirmation explains recovery');
# A valid confirmation commits before stopping scheduled recovery.
{
	local *Cloudmin::HostNetwork::check_connection = sub { 1 };
	$record->{'deadline'} = time() + 60;
	$bridge->write_state($record);
	@guard_calls = ();
	is($bridge->confirm('fixture', 'fixture'), 'br0',
	   'owner confirms a connected bridge');
	is($bridge->read_state()->{'state'}, 'complete',
	   'confirmation commits the journal');
	is(scalar(@guard_calls), 2, 'confirmation disarms both guards');
	}
# Ifupdown must release the bridge port before restarting Ethernet DHCP.
{
	my @commands;
	my $present = 1;
	local *Cloudmin::HostNetwork::command = sub {
		push(@commands, $_[1]);
		$present = 0 if (join(' ', @{$_[1]}) =~ /^ip link delete/);
		};
	local *Cloudmin::HostNetwork::ip_json = sub { return $present
		? [ { ifname => 'br0' } ]
		: [ ]; };
	$bridge->activate({ mode => 'debian-linux', name => 'br0', source =>
									   'eth0',
			    defs => [ [ 'eth0', 'inet', 'dhcp', [ ] ] ] }, 1);
	is_deeply(
		[ map { join(' ', @$_) } @commands[1 .. 6] ],
		[ 'ip link delete br0 type bridge', 'ifdown --force eth0',
		  'ip link set dev eth0 down',
		  'ip link set dev eth0 addrgenmode eui64',
		  'ip link set dev eth0 up', 'ifup --force eth0' ],
		'rollback releases port and restarts IPv6 before activating it');
	}
# Adding bridge autostart must preserve unrelated interface
# lines and their order.
{
	my $path = tempdir(CLEANUP => 1);
	local $net::network_interfaces_config = "$path/interfaces";
	my $original =
		"# Keep this startup order\nauto enp0s123\n".
		"iface enp0s123 inet manual\n\n# Second group\nauto lo eth0\n";
	WebminCore::write_file_contents($net::network_interfaces_config,
					$original);
	local *Cloudmin::HostNetwork::backend = sub { 'debian-linux' };
	# Stanza writers are separate from the autostart update under test.
	local *net::new_interface_def = sub { };
	local *net::modify_interface_def = sub { };
	# get_auto_defs() reads the fixture after each save,
	# including the new bridge.
	local *net::get_auto_defs = sub {
		my $contents =
			WebminCore::read_file_contents(
				$net::network_interfaces_config);
		return map { split(/\s+/, $_) } $contents =~ /^auto (.*)$/mg;
		};
	my $plan = { mode => 'debian-linux', name => 'br0', source => 'eth0',
		     mac => '02:11:22:33:44:55', defs =>
							 [ [ 'eth0', 'inet',
							     'manual',
							     [ ] ] ] };
	$bridge->save_bridge($plan);
	is(WebminCore::read_file_contents($net::network_interfaces_config),
	   $original."auto br0\n",
	   'bridge autostart leaves existing content and order intact');
	$bridge->save_bridge($plan);
	is(WebminCore::read_file_contents($net::network_interfaces_config),
	   $original."auto br0\n",
	   'saving again does not duplicate bridge autostart');
	WebminCore::write_file_contents($net::network_interfaces_config,
					"auto eth0");
	$bridge->save_bridge($plan);
	is(WebminCore::read_file_contents($net::network_interfaces_config),
	   "auto eth0\nauto br0\n",
	   'autostart append handles a missing final newline');
	}
# Losing IPv6 must fail connectivity validation even when IPv4 still works.
{
	my $p = { name => 'br0', source => 'eth0', management => 1,
		  addresses => [ '192.0.2.2/24', '2001:db8::2/64' ] };
	local *Cloudmin::HostNetwork::inventory =
		sub { return { management => [ 'br0' ], interfaces => [
			{ name => 'br0', bridge => 1, active => 1,
			  ports => [ 'eth0' ],
			  addresses => [ '192.0.2.2/24' ] } ] }; };
	ok(!eval { $bridge->check_connection($p); 1 },
	   'missing IPv6 prevents confirmation');
	like($@, qr/2001:db8/, 'missing IPv6 address is identified');
	}
# DHCP release must identify only the lease currently held by this interface.
{
	no warnings 'once';
	my $host = Cloudmin::HostNetwork->new();
	my $status = { HardwareAddress => [ 2, 17, 34, 51, 68, 85 ],
		       DHCPv4Client =>
			       { ClientIdentifier => [ 255, 1, 2, 3, 4, 0, 2,
						       9 ] },
		       Addresses =>
			       [ { Address => [ 192, 0, 2, 12 ],
				   ConfigProvider =>
					   [ 192,
					     0, 2,
					     1 ],
				   ConfigSource => 'DHCPv4',
				   ConfigState => 'configured' } ] };
	my (@opened, @bound, @sent, $fail_send);
	# new(class, options...) captures bind options without
	# opening a real socket.
	local *IO::Socket::INET::new =
		sub { shift; @opened = @_; return bless({ },
							'ReleaseSocket'); };
	# SO_BINDTODEVICE() supplies the Linux constant on other test platforms.
	local *Socket::SO_BINDTODEVICE = sub { 25 };
	# setsockopt(self, level, option, value) records the
	# chosen network device.
	local *ReleaseSocket::setsockopt =
		sub { shift; @bound = @_; return 1; };
	# blocking(self, flag) accepts nonblocking mode
	# without changing host I/O.
	local *ReleaseSocket::blocking = sub { return 1; };
	# send(self, packet, flags, destination) captures bytes
	# or simulates failure.
	local *ReleaseSocket::send =
		sub { shift; @sent = @_; return $fail_send
			? undef
			: length($sent[0]); };
	# close(self) completes cleanup of the socket stand-in.
	local *ReleaseSocket::close = sub { return 1; };
	# Verify the release uses the live lease, its provider and
	# the selected device.
	ok($host->release_netplan_dhcp4('eth0', $status),
	   'current lease is released');
	my %opened = @opened;
	is($opened{'LocalAddr'}, '192.0.2.12',
	   'release comes from the actual leased address');
	is($opened{'LocalPort'}, 68, 'release uses the DHCP client port');
	is($bound[2], "eth0\0", 'release is bound to the intended interface');
	my ($port, $server) = Socket::unpack_sockaddr_in($sent[2]);
	is($port, 67, 'release goes to the DHCP server port');
	is($server, pack('C4', 192, 0, 2, 1),
	   'release goes to the lease provider');
	# Check wire offsets and option bytes independently
	# of the packet builder.
	is(substr($sent[0], 12, 4), pack('C4', 192, 0, 2, 12),
	   'ciaddr contains the current lease');
	is(substr($sent[0], 28, 6), pack('C6', 2, 17, 34, 51, 68, 85),
	   'chaddr contains the interface MAC');
	is(substr($sent[0], 236, 4), pack('N', 0x63825363),
	   'message contains the DHCP magic cookie');
	my $options =
		pack('C*', 53, 1, 7, 54, 4, 192, 0, 2, 1, 61, 8, 255, 1, 2, 3,
		     4, 0,
		     2, 9, 255);
	is(substr($sent[0], 240, length($options)), $options,
	   'release includes its type, server identifier and exact client identifier');
	ok(length($sent[0]) >= 300, 'release meets the BOOTP minimum length');
	# Local send errors must propagate instead of claiming
	# the lease was released.
	$fail_send = 1;
	ok(!eval { $host->release_netplan_dhcp4('eth0', $status); 1 },
	   'send failure is reported');
	like($@, qr/Cannot release DHCPv4 lease/,
	     'send failure names the failed operation');
	# Incomplete metadata must never send a guessed or truncated release.
	@opened = ();
	my $bad = { %$status, DHCPv4Client => { ClientIdentifier => [ 256,
								      1 ] } };
	ok(!eval { $host->release_netplan_dhcp4('eth0', $bad); 1 },
	   'invalid client bytes are rejected');
	is(scalar(@opened), 0, 'invalid data opens no socket');
	$bad =
		{ %$status, Addresses =>
				    [ { %{$status->{'Addresses'}->[0]},
				ConfigProvider => [ ] } ] };
	ok(!eval { $host->release_netplan_dhcp4('eth0', $bad); 1 },
	   'missing server is rejected');
	$bad =
		{ %$status, Addresses =>
				    [ $status->{'Addresses'}->[0],
				      $status->{'Addresses'}->[0] ] };
	ok(!eval { $host->release_netplan_dhcp4('eth0', $bad); 1 },
	   'ambiguous leases are rejected');
	$bad =
		{ %$status, Addresses =>
				    [ { %{$status->{'Addresses'}->[0]},
				ConfigSource => 'static' } ] };
	ok(!$host->release_netplan_dhcp4('eth0', $bad),
	   'static addresses are never released');
	}
# Recovery must request the old DHCP lease without changing permanent files.
{
	my $path = tempdir(CLEANUP => 1);
	my $host =
		Cloudmin::HostNetwork->new(networkd_runtime_directory => $path);
	my $plan =
		{ id => 'restore-fixture', mode => 'netplan', source => 'eth0',
		  saved => { dhcp => 1 }, addresses => [ '192.0.2.13/24' ] };
	my $status =
		{ NetworkFile => '/run/systemd/network/10-netplan-eth0.network',
		  Addresses =>
			  [ { Address => [ 192, 0, 2, 12 ],
			      ConfigSource => 'DHCPv4',
			      ConfigState => 'configured' } ] };
	my (@commands, $refuse, $fail_command);
	my $has_lease = 1;
	# release_netplan_dhcp4(self, target, status) avoids real
	# sockets in this test.
	local *Cloudmin::HostNetwork::release_netplan_dhcp4 = sub {
		push(@commands, "release $_[1]");
		return $has_lease;
		};
	# command(self, argv, [quiet], [safe]) records calls
	# and supplies status.
	local *Cloudmin::HostNetwork::command = sub {
		my ($self, $argv) = @_;
		push(@commands, join(' ', @$argv));
		# Fail one command only, leaving cleanup able to
		# bring the device up.
		if ($fail_command && $commands[-1] eq $fail_command) {
			$fail_command = undef;
			die "Fixture network command failed\n";
			}
		# Status returns JSON; the other networkctl
		# calls have no output.
		return JSON::PP->new->encode($status)
			if ($argv->[1] eq '--json=short');
		return '';
		};
	# wait_for_connection(self, plan, [restoring]) Checks the temporary DHCP
	# address request while it is still installed.
	local *Cloudmin::HostNetwork::wait_for_connection = sub {
		my @files = glob("$path/*.network.d/*.conf");
		is(scalar(@files), 1,
		   'only the source interface gets a temporary recovery hint');
		like(WebminCore::read_file_contents($files[0]),
		     qr/^RequestAddress=192\.0\.2\.13$/m,
		     'recovery requests the saved address, not the active wrong lease');
		is((stat($files[0]))[2] & 0777, 0644,
		   'networkd can read the recovery hint');
		# The refusal case must propagate after the hint
		# has been cleaned up.
		die "DHCP server refused the original address\n" if ($refuse);
		};
	# A successful retry releases the wrong lease before
	# loading its replacement.
	$host->restore_netplan_dhcp4($plan);
	is_deeply(
		\@commands,
		[ 'networkctl --json=short status eth0', 'release eth0',
		  'networkctl down eth0', 'networkctl reload',
		  'networkctl up eth0', 'networkctl reload' ],
		'wrong lease is released and cleared before loading the address request');
	ok(!-e "$path/10-netplan-eth0.network.d",
	   'successful recovery removes its temporary configuration');
	# DHCP refusal remains a failure, with the original policy restored.
	$refuse = 1;
	ok(!eval { $host->restore_netplan_dhcp4($plan); 1 },
	   'DHCP refusal is not accepted as recovery');
	like($@, qr/DHCP server refused/,
	     'recovery retains the actual failure');
	ok(!-e "$path/10-netplan-eth0.network.d",
	   'failed recovery also removes its temporary configuration');
	$refuse = 0;
	# Failed network commands still remove the hint and
	# attempt to restore link-up.
	foreach my $command ( 'networkctl down eth0', 'networkctl reload',
			      'networkctl up eth0' ) {
		@commands = ();
		$fail_command = $command;
		ok(!eval { $host->restore_netplan_dhcp4($plan); 1 },
		   "$command failure is reported");
		like($@, qr/Fixture network command failed/,
		     'cleanup preserves the original failure');
		is($commands[-1], 'networkctl up eth0',
		   'cleanup attempts to leave the interface up');
		ok(!-e "$path/10-netplan-eth0.network.d",
		   'command failure removes its runtime hint');
		}
	# Recovery after bridge removal must target the bridge,
	# not its former port.
	@commands = ();
	$host->restore_netplan_dhcp4({ %$plan, operation => 'remove', name =>
									      'br0' });
	ok(grep($_ eq 'release br0', @commands),
	   'removal recovery releases the bridge lease');
	ok(grep($_ eq 'networkctl up br0', @commands),
	   'removal recovery brings the bridge up');
	# An unleased interface needs no release or forced link-down.
	$has_lease = 0;
	@commands = ();
	$host->restore_netplan_dhcp4($plan);
	ok(!grep($_ eq 'networkctl down eth0', @commands),
	   'no lease avoids link-down');
	ok(grep($_ eq 'networkctl reconfigure eth0', @commands),
	   'no lease restarts DHCP normally');
	# Existing working leases, static addresses and other
	# backends stay untouched.
	$status->{'Addresses'}->[0]->{'Address'} = [ 192, 0, 2, 13 ];
	@commands = ();
	$host->restore_netplan_dhcp4($plan);
	is(scalar(@commands), 1, 'correct lease requires only a status read');
	@commands = ();
	$host->restore_netplan_dhcp4({ %$plan, saved => { dhcp => 0 } });
	$host->restore_netplan_dhcp4({ %$plan, mode => 'nm' });
	$host->restore_netplan_dhcp4({ %$plan, addresses =>
						       [ '2001:db8::13/64' ] });
	is(scalar(@commands), 0,
	   'static, IPv6-only and non-Netplan profiles are not reconfigured');
	# Ambiguous old plans must not choose an arbitrary address for DHCP.
	ok(!eval { $host->restore_netplan_dhcp4({ %$plan, addresses =>
								  [ '192.0.2.13/24', '192.0.2.14/24' ] }); 1 },
	   'ambiguous saved DHCP address is rejected');
	ok(!eval { $host->restore_netplan_dhcp4({ %$plan, dhcp4_identity =>
								  "RequestAddress=192.0.2.999\n" }); 1 },
	   'invalid saved address is rejected');
	}
# Netplan must reject addresses it cannot preserve before
# starting a transaction.
{
	my $path = tempdir(CLEANUP => 1);
	my $source = { name => 'ethfixture', fullname => 'ethfixture',
		       file => "$path/source.yaml",
		       yaml => { members => [ ] } };
	my $link =
		{ ifname => 'ethfixture', flags => [ 'UP' ],
		  link_type => 'ether',
		  address => '02:11:22:33:44:55', linkinfo => { },
		  addr_info =>
			  [ ] };
	my $host =
		Cloudmin::HostNetwork->new(directory => "$path/state", jobs =>
									       $jobs);
	local $net::netplan_dir = $path;
	# backend(self) and boot_interfaces() supply an isolated
	# persistent interface.
	local *Cloudmin::HostNetwork::backend = sub { 'netplan' };
	local *net::boot_interfaces = sub { $source };
	# ip_json(self, arguments...) supplies live
	# addresses without running ip.
	local *Cloudmin::HostNetwork::ip_json = sub {
		return grep({ $_ eq 'address' } @_[1 .. $#_]) ? [ $link ] : [ ];
		};
	# command(self, argv) refuses any attempt to change
	# workstation networking.
	local *Cloudmin::HostNetwork::command =
		sub { die "Unexpected network command\n" };
	WebminCore::write_file_contents($source->{'file'},
					"original configuration\n");
	my $eui64 = '2001:db8::11:22ff:fe33:4455';
	my $assigned = '2001:db8::1234';
	foreach my $case (
		[ 'static IPv6', { }, $assigned, 0, 0, 1 ],
		[ 'temporary IPv6', { }, $assigned, 1, 1, 1 ],
		[ 'default EUI-64', { }, $eui64, 1, 0, 1 ],
		[ 'explicit EUI-64', { 'ipv6-address-generation' => 'eui64' },
		  $eui64, 1, 0, 1 ],
		[ 'SLAAC token', { 'ipv6-address-token' => '::1234' },
		  $assigned,
		  1, 0, 1 ],
		[ 'quoted SLAAC token', { 'ipv6-address-token' => '"::1234" ' },
		  $assigned, 1, 0, 1 ],
		[ 'single-quoted SLAAC token',
		  { 'ipv6-address-token' => "'::1234'" }, $assigned, 1, 0,
		  1 ],
		[ 'stable-privacy',
		  { 'ipv6-address-generation' => 'stable-privacy' },
		  $assigned,
		  1, 0, 0 ],
		[ 'DHCPv6 lease', { dhcp6 => 'true' }, $assigned, 1, 0, 0 ],
		[ 'DHCPv6 enabled without a lease', { dhcp6 => 'true' }, $eui64,
		  1,
		  0, 1 ],
		[ 'mismatched SLAAC token',
		  { 'ipv6-address-token' => '::5678' },
		  $assigned, 1, 0, 0 ],
	) {
		my ($label, $options, $address, $dynamic, $temporary,
		    $allowed) = @$case;
		$source->{'yaml'}->{'members'} =
			[ map { { name => $_, value =>
						      $options->{$_} } } sort keys %$options ];
		$link->{'addr_info'} = [
			{ family => 'inet6', scope => 'global', local =>
									$address,
			  prefixlen => 64,
			  dynamic => $dynamic, temporary => $temporary },
			{ family => 'inet6', scope => 'link',
			  local => 'fe80::1',
			  prefixlen => 64 } ];
		my $plan = eval { $host->prepare('brfixture', 'ethfixture') };
		if ($allowed) {
			# Safe plans still require every non-temporary host
			# address after apply.
			ok($plan, "$label passes preflight") or diag($@);
			is_deeply($plan->{'addresses'}, $temporary
				? [ ]
				: [ "$address/64" ],
				  "$label retains the address-preservation check");
			}
		else {
			# The real transaction entry point must also
			# refuse before journaling.
			ok(!$plan, "$label is refused during review");
			like($@, qr/IPv6 addresses that cannot be preserved/,
			     "$label explains the refusal");
			ok(!eval { $host->begin('brfixture', 'ethfixture',
						'unused', 'fixture'); 1 },
			   "$label cannot start a transaction");
			like($@, qr/IPv6 addresses that cannot be preserved/,
			     "$label fails before applying settings");
			}
		ok(!-e "$path/state/bridge.json" && !-e "$path/brfixture.yaml",
		   "$label writes no journal or bridge configuration");
		is(WebminCore::read_file_contents($source->{'file'}),
		   "original configuration\n",
		   "$label leaves source configuration unchanged");
		}
	}
# Moving DHCP to a new device must retain both parts of its RFC 4361 identity.
{
	my $client =
		[ 255, 86, 80, 77, 152, 0, 2, 0, 0, 171, 17, 153, 221, 78, 37,
		  77,
		  97, 61, 152 ];
	my $addresses =
		[ { Address => [ 192, 0, 2, 13 ], ConfigSource => 'DHCPv4',
		    ConfigState => 'configured' },
		  { Address => [ 192, 0, 2, 99 ], ConfigSource => 'static',
		    ConfigState => 'configured' } ];
	# command(self, argv, [quiet], [safe]) returns static
	# and leased addresses.
	local *Cloudmin::HostNetwork::command = sub {
		return JSON::PP->new->encode({ DHCPv4Client =>
						       { ClientIdentifier => $client },
					       Addresses => $addresses });
		};
	my $identity =
		$bridge->netplan_dhcp4_identity('eth0', '58:47:ca:78:5a:7d');
	like($identity, qr/^IAID=1448103320$/m,
	     'bridge retains DHCP interface identity');
	like($identity, qr/^DUIDType=2$/m, 'bridge retains DUID type');
	like($identity, qr/^DUIDRawData=00:00:ab:11:99:dd:4e:25:4d:61:3d:98$/m,
	     'bridge retains DUID bytes');
	like($identity, qr/^RequestAddress=192\.0\.2\.13$/m,
	     'bridge requests the DHCP address rather than a static address');
	$client = [ 1, 88, 71, 202, 120, 90, 125 ];
	is($bridge->netplan_dhcp4_identity('eth0', '58:47:ca:78:5a:7d'),
	   "[DHCPv4]\nClientIdentifier=mac\nRequestAddress=192.0.2.13\n",
	   'MAC-based DHCP also requests the previous address');
	# A stale or malformed lease must fail before network settings change.
	my $valid_addresses = $addresses;
	foreach my $bad ( [ ],
			  [ { Address => [ 192, 0, 2, 999 ],
			      ConfigSource => 'DHCPv4',
			      ConfigState => 'configured' } ],
			  [ { Address => [ 192, 0, 2, 13 ],
			      ConfigSource => 'DHCPv4',
			      ConfigState => 'requesting' } ] ) {
		$addresses = $bad;
		ok(!eval { $bridge->netplan_dhcp4_identity(
			'eth0',
			'58:47:ca:78:5a:7d'); 1 },
		   'incomplete DHCP address prevents conversion');
		}
	$addresses = $valid_addresses;
	# Restoring a valid lease must not let malformed
	# client identifiers pass.
	foreach my $bad ( [ ], [ 255, 1 ], [ 0, 1, 2 ], [ 255, 999, 0, 0, 0, 0,
							  2, 0 ],
			  undef ) {
		$client = $bad;
		ok(!eval { $bridge->netplan_dhcp4_identity('eth0',
							   '58:47:ca:78:5a:7d'); 1 },
		   'missing or unsupported DHCP identity prevents changes');
		}
	}
# NM must copy the effective DHCP identity rather than
# regenerate it for a bridge.
{
	my $path = tempdir(CLEANUP => 1);
	local $net::nm_conn_dir = $path;
	my $cfg = [
		{ sect => 'connection', members =>
						[ { name => 'type',
						    value => 'ethernet' },
						  { name => 'uuid',
						    value => 'ebf40ec8-cfe3-4482-a2fc-fb343f87ab01' } ] },
		{ sect => 'ipv4', members =>
					  [ { name => 'method',
					      value => 'auto' } ] },
	];
	my $source = { name => 'ethfixture', fullname => 'ethfixture',
		       dhcp => 1,
		       file => "$path/source.nmconnection", cfg => $cfg };
	WebminCore::write_file_contents($source->{'file'},
					"original profile\n");
	my $host =
		Cloudmin::HostNetwork->new(directory => "$path/state", jobs =>
									       $jobs);
	local *Cloudmin::HostNetwork::backend = sub { 'nm' };
	my $addresses = [ '192.0.2.2/24' ];
	local *Cloudmin::HostNetwork::inventory = sub {
		return { backend => 'nm', supported => 1, interfaces =>
								  [ { name => 'ethfixture',
								      candidate => 1, mac => '02:11:22:33:44:55',
								      addresses => $addresses } ] };
		};
	local *net::boot_interfaces = sub { $source };
	# find_nm_config(config, section, key) reads the
	# fixture profile's settings.
	local *net::find_nm_config = sub {
		my ($config, $section, $key) = @_;
		my ($group) = grep { $_->{'sect'} eq $section } @$config;
		my ($entry) =
			grep { $_->{'name'} eq $key } @{$group->{'members'} ||
				[ ]};
		return $entry ? $entry->{'value'} : undef;
		};
	local *net::save_nm_config = sub { };
	my $lease;
	# command(self, argv, quiet, safe) permits only the
	# mocked probe and reload.
	local *Cloudmin::HostNetwork::command = sub {
		my ($self, $args, $quiet, $safe) = @_;
		return ''
			if (join(' ',
				 @$args) eq
			    "nmcli connection load $path/cloudmin-brfixture.nmconnection");
		is_deeply($args,
			  [ 'nmcli', '--terse', '--mode', 'multiline',
			    '--escape',
			    'no',
			    '--fields', 'DHCP4.OPTION', 'device', 'show',
			    'ethfixture' ],
			  'probe reads active DHCP options');
		ok($quiet && $safe, 'DHCP probe is read-only');
		return $lease;
		};
	foreach my $case (
		[ 'mac', '01:02:11:22:33:44:55' ],
		[ 'duid', 'ff:12:34:56:78:00:02:00:00:ab:11:01:02' ],
		[ 'stable', '00:11:22:33:44:55' ],
		[ undef, 'ff:87:65:43:21:00:02:00:00:ab:11:01:02' ],
		[ undef, undef ],
	) {
		my ($setting, $id) = @$case;
		$cfg->[1]->{'members'} = [ { name => 'method',
					     value => 'auto' },
					   defined($setting)
						   ? { name => 'dhcp-client-id',
						       value => $setting }
						   : () ];
		$lease = "DHCP4.OPTION[1]:ip_address = 192.0.2.2\n".
			 (defined($id)
				 ? "DHCP4.OPTION[2]:dhcp_client_identifier = $id\n"
				 : '');
		my $plan = $host->prepare('brfixture', 'ethfixture');
		is($plan->{'dhcp4_client_id'}, $id || 'none',
		   'review captures the active lease identity');
		$plan->{'bridge_uuid'} = 'de3d11a2-71ce-4467-95eb-c5d4d811beac';
		$host->save_bridge($plan);
		my @saved =
			WebminCore::read_file_contents(
				$plan->{'new_file'}) =~ /^dhcp-client-id=(.*)$/mg;
		is_deeply(\@saved, [ $id || 'none' ],
			  'bridge has one explicit client ID matching the lease');
		is(WebminCore::read_file_contents($source->{'file'}),
		   "original profile\n",
		   'identity capture leaves source file intact');
		unlink($plan->{'new_file'}) || die $!;
		}
	foreach my $bad ( '', "DHCP4.OPTION[1]:ip_address = 192.0.2.2\n".
			  "DHCP4.OPTION[2]:dhcp_client_identifier = not-hex\n" ) {
		$lease = $bad;
		ok(!eval { $host->prepare('brfixture',
					  'ethfixture'); 1 },
		   'missing lease or invalid ID refuses review');
		like($@, qr/Cannot (?:read|preserve).*DHCPv4/,
		     'refusal identifies DHCP identity problem');
		ok(!eval { $host->begin('brfixture', 'ethfixture',
					'unused',
					'fixture'); 1 },
		   'invalid DHCP identity cannot start a transaction');
		ok(!-e "$path/state/bridge.json" &&
		   !-e "$path/cloudmin-brfixture.nmconnection",
		   'refusal creates no journal or bridge configuration');
		}
	$source->{'dhcp'} = 0;
	local *Cloudmin::HostNetwork::command =
		sub { die "Static profile must not probe DHCP\n" };
	ok($host->prepare('brfixture', 'ethfixture'),
	   'static profile does not need a DHCP lease');
	$source->{'dhcp'} = 1;
	$addresses = [ ];
	ok($host->prepare('brfixture', 'ethfixture'),
	   'unaddressed port does not need a DHCP lease');
	}
# Save the configured recovery deadline before services start.
{
	# prepare(self, name, source) supplies a plan without
	# reading host interfaces.
	local *Cloudmin::HostNetwork::prepare = sub {
		return { name => 'br-test', source => 'eth-test', mode =>
									  'fixture',
			 revision => 'reviewed', confirm_timeout =>
							 $_[0]->{'confirm_timeout'} };
		};
	# get_perl_path() uses a fixed guest path in generated unit definitions.
	local *Cloudmin::HostNetwork::get_perl_path = sub { '/usr/bin/perl' };
	my @commands;
	# command(self, argv) records service launches
	# without running systemctl.
	local *Cloudmin::HostNetwork::command =
		sub { push(@commands, $_[1]); return ''; };
	# Exercise both timeout boundaries and ordinary values
	# with isolated journals.
	foreach my $seconds ( 120, 180, 420, 900 ) {
		my $path = tempdir(CLEANUP => 1);
		my $timed =
			Cloudmin::HostNetwork->new(directory => "$path/state",
						   module => '/fixture',
						   jobs => $jobs,
						   confirm_timeout =>
							   $seconds);
		@guard_calls = (); @commands = ();
		my $before = time();
		$timed->begin('br-test', 'eth-test', 'reviewed', 'fixture');
		my $state = $timed->read_state();
		# The saved deadline and generated timer must use
		# the requested timeout.
		cmp_ok($state->{'deadline'}, '>=', $before + $seconds,
		       'deadline uses configured window');
		cmp_ok($state->{'deadline'}, '<=', time() + $seconds,
		       'deadline is bounded');
		my ($timer) =
			grep { $_->[1] eq 'cloudmin-network-rollback.timer' &&
				$_->[0] eq 'create_system_unit' } @guard_calls;
		my ($armed) = $timer->[2] =~ /OnActiveSec=(\d+)/;
		cmp_ok($armed, '<=', $seconds,
		       'timer does not extend the saved window');
		cmp_ok($armed, '>=', $seconds - 2,
		       'timer matches the saved countdown');
		# Custom timeouts still arm boot recovery before
		# starting the apply worker.
		ok(
			grep(
				{
					$_->[1] eq 'cloudmin-network-boot.service' } @guard_calls),
			'custom timeout retains boot recovery');
		is_deeply($commands[0], [ 'systemctl', 'start', '--no-block',
					  'cloudmin-network-apply.service' ],
			  'application starts after guards are armed');
		# Re-arming uses the saved deadline, even if module
		# settings have changed.
		$timed->{'confirm_timeout'} = 900;
		$timed->install_guards($state);
		is($timed->read_state()->{'deadline'}, $state->{'deadline'},
		   'a later configuration change cannot extend the pending deadline');
		# Neither a second change nor an expired timer can
		# bypass pending recovery.
		ok(!eval { $timed->begin('br-test', 'eth-test', 'reviewed',
					 'fixture'); 1 },
		   'pending change still blocks another bridge conversion');
		ok(!eval { $timed->install_guards({ deadline => time() - 1 }); 1 },
		   'expired guard cannot be armed with a negative timeout');
		}
	# Invalid constructor input falls back to the default timeout.
	foreach my $invalid ( undef, 0, 119, 901, '180s', "180\nUnit=other" ) {
		is(Cloudmin::HostNetwork->new(confirm_timeout =>
						      $invalid)->{'confirm_timeout'},
		   180,
		   'invalid backend setting retains the default recovery window');
		}
	}
done_testing();
