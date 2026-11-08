use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib", "$Bin/../lib";
use CloudminTest;
use Test::More;
use File::Temp qw(tempdir);
use WebminCore;
# get_system_hostname() keeps template defaults independent of this host.
{
	no warnings 'redefine';
	*WebminCore::get_system_hostname = sub { 'host.example.test' };
	}
require "$Bin/../lib/Cloudmin/Networks.pm";
require "$Bin/../lib/Cloudmin/HostNetwork.pm";

{
	package RemovalJobs;

	# lock(self, name, callback) runs the isolated
	# journal without host locks.
	sub lock
	{
	$_[2]->()
	}

	# list(self, [owner], [pending]) supplies active work
	# for reservation checks.
	sub list
	{
	$_[0]->{'active'} || [ ]
	}
	package RemovalHost;
	our @ISA = ('Cloudmin::HostNetwork');

	# inventory(self) supplies only the fixture bridge and Ethernet port.
	sub inventory
	{
	$_[0]->{'data'}
	}

	# backend(self) avoids loading a workstation network backend.
	sub backend
	{
	'nm'
	}

	# unit(self, method, [args...]) records recovery guard actions.
	sub unit
	{
	push(@{$_[0]->{'units'}}, [ @_[1 .. $#_] ])
	}

	# command(self, argv, [quiet], [safe]) records calls
	# without running them.
	sub command
	{
	push(@{$_[0]->{'commands'}}, $_[1]); return ''
	}
	}
# Keep every file and journal write inside the temporary fixture directory.
my $dir = tempdir(CLEANUP => 1);
my $jobs = bless({ }, 'RemovalJobs');
my $bridge = { name => 'br0', bridge => 1, persistent => 1, active => 1,
	       ports => [ 'eth0' ], addresses => [ '192.0.2.2/24' ], mac =>
									     '02:11:22:33:44:55', mtu => 1500, management => 1 };
my $port =
	{ name => 'eth0', active => 1, master => 'br0', kind => '',
	  addresses => [ ] };
my $host =
	RemovalHost->new(directory => "$dir/state", jobs => $jobs, module =>
									   "$Bin/..",
			 data =>
				 { backend => 'nm', supported => 1,
				   interfaces => [ $bridge,
						   $port ],
				   management => [ 'br0' ] });

# nm_section(name, [pairs...]) builds Webmin sections from name/value pairs.
sub nm_section
{
my ($name, %fields) = @_;
return { sect => $name, members =>
				[ map { { name => $_,
					  value => $fields{$_} } } sort keys %fields ] };
}
# Give the bridge and port different IP, MTU and metadata settings to track.
my $saved =
	{ name => 'br0', fullname => 'br0', bridge => 1, file => "$dir/bridge",
	  cfg => [
		  nm_section('connection', uuid => 'bridge-uuid', type =>
									  'bridge'),
		  nm_section('bridge', stp => 'false'),
		  nm_section('ipv4', method => 'manual', address1 =>
								 '192.0.2.2/24',
			     dns => '192.0.2.1;'),
		  nm_section('ipv6', method => 'disabled',
			     mtu => '1280') ] };
# The destination must retain its UUID and metadata while losing membership.
my $saved_port =
	{ name => 'eth0', fullname => 'eth0', file => "$dir/port", cfg => [
		nm_section('connection', uuid => 'port-uuid', type =>
								      'ethernet', 'interface-name' => 'eth0',
			   master => 'br0', 'slave-type' => 'bridge'),
		nm_section('ethernet', mtu => '9000'),
		nm_section('ipv4', method => 'disabled'),
		nm_section('user', origin => 'fixture') ] };
write_file_contents($_, "original $_\n") for ($saved->{'file'},
					      $saved_port->{'file'});
no warnings qw(redefine once);
# boot_interfaces() exposes only these two saved fixture profiles.
local *net::boot_interfaces = sub { ( $saved, $saved_port ) };
# find_nm_config(cfg, section, key) reads fixture values like Webmin's parser.
local *net::find_nm_config = sub {
	my ($cfg, $section, $key) = @_;
	my ($s) = grep { $_->{'sect'} eq $section } @$cfg;
	my ($v) = grep { $_->{'name'} eq $key } @{$s->{'members'} || [ ]};
	return $v ? $v->{'value'} : undef;
	};
# Review must capture both current files and reject an outdated revision.
my $plan = $host->prepare_remove('br0');
is($plan->{'operation'}, 'remove', 'review identifies bridge removal');
is($plan->{'source'}, 'eth0', 'destination is the sole Ethernet port');
is_deeply([ sort keys %{$plan->{'files'}} ],
	  [ sort ($saved->{'file'}, $saved_port->{'file'}) ],
	  'both current files are backed up');
ok(!eval { $host->begin('br0', 'eth0', 'stale', 'root', 'remove'); 1 },
   'stale removal review rejected');
ok(!-e "$dir/state/bridge.json", 'stale review never arms recovery');

# Kernel link names identify local dependencies; peer indexes
# are namespace-local.
{
	local *RemovalHost::inventory = \&Cloudmin::HostNetwork::inventory;
	my $links = [
		{ ifindex => 2, ifname => 'eth0', link_type => 'ether',
		  master =>
			  'br0' },
		{ ifindex => 3, ifname => 'br0', address => $bridge->{'mac'},
		  link_type => 'ether', linkinfo =>
						{ info_kind => 'bridge' } } ];
	# ip_json(self, args...) supplies links for inventory
	# and no client routes.
	local *RemovalHost::ip_json = sub {
		return grep({ $_ eq 'address' } @_[1 .. $#_]) ? $links : [ ];
		};
	foreach my $parent ( 'br0', 'eth0' ) {
		foreach my $kind ( 'vlan', 'macvlan' ) {
			local $links->[2] =
				{ ifname => 'child0', link => $parent,
				  link_type => 'ether',
				  linkinfo => { info_kind => $kind } };
			ok(!eval { $host->prepare_remove('br0'); 1 },
			   "$kind on $parent blocks removal");
			like($@, qr/Other host interfaces depend/,
			     'dependency refusal precedes file changes');
			}
		}
	# A peer's numeric index must not resolve against this
	# namespace's devices.
	local $links->[2] =
		{ ifname => 'veth0', link_index => 3, link_netnsid => 0,
		  link_type => 'ether',
		  linkinfo => { info_kind => 'veth' } };
	my ($peer) = grep { $_->{'name'} eq 'veth0' }
		     @{$host->inventory()->{'interfaces'}};
	is($peer->{'parent'}, '',
	   'foreign peer index is not mistaken for local br0');
	}

# Review refuses unsupported topology without changing either file.
for my $case (
	# callback() reviews a bridge whose only port disappeared.
	[ sub { local $bridge->{'ports'} = [ ]; $host->prepare_remove('br0'); },
	  qr/one Ethernet/ ],
	# callback() reviews ambiguous multi-port removal.
	[ sub { local $bridge->{'ports'} =
		[ 'eth0', 'eth1' ]; $host->prepare_remove('br0'); },
	  qr/one Ethernet/ ],
	# callback() substitutes a VLAN for the plain Ethernet destination.
	[ sub { local $port->{'kind'} = 'vlan'; $host->prepare_remove('br0'); },
	  qr/plain Ethernet/ ],
	# callback() gives the destination separate addresses that must survive.
	[ sub { local $port->{'addresses'} =
		[ '192.0.2.5/24' ]; $host->prepare_remove('br0'); },
	  qr/own addresses/ ],
	# callback() makes boot_interfaces() return conflicting
	# saved port profiles.
	[ sub { local *net::boot_interfaces =
		sub { ( $saved, $saved_port,
			$saved_port ) }; $host->prepare_remove('br0'); },
	  qr/one persistent/ ] ) {
	ok(!eval { $case->[0]->(); 1 },
	   'unsafe topology rejected');
	like($@, $case->[1],
	     'refusal explains the unsupported topology');
	}

# Apply and recovery must check opposite destinations and the same host address.
ok(!eval { $host->check_connection($plan); 1 },
   'existing bridge does not count as completed removal');
$host->check_connection($plan, 1);
pass('removal recovery checks the restored bridge');
{
	local $host->{'data'} =
		{ %{$host->{'data'}}, management => [ 'eth0' ], interfaces => [
			{ %$port, master => '',
				addresses => [ '192.0.2.2/24' ] } ] };
	$host->check_connection($plan);
	pass('removed bridge and preserved port address pass confirmation');
	local $host->{'data'}->{'interfaces'}->[0]->{'addresses'} = [ ];
	ok(!eval { $host->check_connection($plan); 1 },
	   'lost host address blocks confirmation');
	}

# The writer copies current bridge settings, retaining the port identity.
$plan->{'id'} = 'fixture';
$plan->{'state'} = 'armed';
$host->write_state($plan);
$host->save_removal($plan);
my $contents = read_file_contents($saved_port->{'file'});
like($contents, qr/uuid=port-uuid/, 'Ethernet UUID retained');
like($contents, qr/address1=192\.0\.2\.2\/24/, 'current bridge address copied');
like($contents, qr/dns=192\.0\.2\.1;/, 'current DNS copied');
like($contents, qr/origin=fixture/, 'port metadata retained');
like($contents, qr/cloned-mac-address=02:11:22:33:44:55/,
     'bridge MAC retained');
like($contents, qr/^mtu=1500$/m, 'current bridge MTU retained');
like($contents, qr/\[ipv6\]\n[^\[]*mtu=1280/m,
     'IPv6-specific MTU retained separately');
unlike($contents, qr/^(?:master|controller|slave-type|port-type)=/m,
       'Ethernet profile is standalone');
ok(!-e $saved->{'file'}, 'only bridge profile removed');
# Boot recovery restores files without activating workstation networking.
$host->rollback(1);
is(read_file_contents($saved->{'file'}), "original $saved->{file}\n",
   'boot recovery restores bridge byte for byte');
is(read_file_contents($saved_port->{'file'}), "original $saved_port->{file}\n",
   'boot recovery restores port byte for byte');

# Starting removal preserves the existing NM bridge UUID for rollback.
$plan = $host->prepare_remove('br0');
$host->begin('br0', 'eth0', $plan->{'revision'}, 'root', 'remove');
is($host->read_state()->{'bridge_uuid'}, 'bridge-uuid',
   'removal never allocates a replacement bridge UUID');
is($host->public_state()->{'operation'}, 'remove',
   'public status includes removal direction');
ok(!exists($host->public_state()->{'files'}),
   'public status excludes private snapshots');
ok(!eval { $host->confirm($host->read_state()->{'id'}, 'other'); 1 },
   'another owner cannot confirm removal');

# Debian bridge-utils disables address generation on ports and leaves them down.
{
	# ip_json(self, args...) supplies a bridge with the
	# kernel's EUI-64 mode.
	local *RemovalHost::ip_json =
		sub { [ { ifname => 'br0', inet6_addr_gen_mode => 'eui64' } ] };
	is($host->ipv6_address_mode('br0'), 'eui64',
	   'kernel IPv6 mode can be preserved in the review');
	local $host->{'commands'} = [ ];
	$host->activate_removal({ %$plan, mode => 'debian-linux', defs => [ ],
				  ipv6_address_mode => 'eui64' }, 0);
	my @last = @{$host->{'commands'}}[-4 .. -1];
	is_deeply(
		\@last, [
			[ 'ip', 'link', 'set', 'dev', 'eth0', 'down' ],
			[ 'ip', 'link', 'set', 'dev', 'eth0', 'addrgenmode',
			  'eui64' ],
			[ 'ip', 'link', 'set', 'dev', 'eth0', 'up' ],
			[ 'ifup', '--force', 'eth0' ] ],
		'removal restores IPv6 generation and link before applying addresses');
	}

# Both saved guest references and persistent-only network changes block removal.
{
	package RemovalNetwork;

	# is_persistent(self) makes inventory inspect saved as well as live XML.
	sub is_persistent
	{
	1
	}

	# get_name(self) identifies the dependent network in refusal messages.
	sub get_name
	{
	'fixture-net'
	}

	# get_xml_description(self, flags) selects live or inactive fixture XML.
	sub get_xml_description
	{
	$_[0]->{$_[1] ? 'saved' : 'live'}
	}
	package RemovalConnection;

	# list_all_networks(self, flags) returns the fixture
	# networks, ignoring flags.
	sub list_all_networks
	{
	@{$_[0]->{'networks'}}
	}
	package RemovalAdapter;

	# connect(self) returns the in-memory connection
	# without opening libvirt.
	sub connect
	{
	$_[0]->{'connection'}
	}
	package main;
	my $network =
		bless({ live => '<network/>', saved =>
						      '<network><bridge name="br0"/></network>' },
		      'RemovalNetwork');
	my $connection = bless({ networks => [ $network ] },
			       'RemovalConnection');
	my $service = Cloudmin::Networks->new(host => $host, jobs => $jobs,
					      adapter =>
						      bless({ connection => $connection }, 'RemovalAdapter'));
	# guest_links(self) isolates the virtual-network dependency check.
	local *Cloudmin::Networks::guest_links = sub { [ ] };
	ok(!eval { $service->prepare_bridge_removal('br0'); 1 },
	   'persistent-only network reference blocks removal');
	like($@, qr/fixture-net uses/, 'refusal names the dependent network');
	$connection->{'networks'} = [ ];
	# guest_links(self) supplies a stopped VM whose saved
	# NIC uses the bridge.
	local *Cloudmin::Networks::guest_links =
		sub { [ { bridge => 'br0', active => 0 } ] };
	ok(!eval { $service->prepare_bridge_removal('br0'); 1 },
	   'stopped guest blocks removal');
	like($@, qr/Detach virtual machines/,
	     'guest refusal explains next step');
	# guest_links(self) supplies a stopped VM attached directly to the port.
	local *Cloudmin::Networks::guest_links =
		sub { [ { device => 'eth0', active => 0 } ] };
	ok(!eval { $service->prepare_bridge_removal('br0'); 1 },
	   'direct attachment to the port blocks removal');
	}

# API review returns public fields only; mutations retain token and ACL checks.
{
	our ($module_root_directory, $module_var_directory, $remote_user);
	$module_root_directory = "$Bin/..";
	$remote_user = 'root';
	require "$Bin/../cloudmin-network-lib.pl";
	my ($readonly, $denied, $busy, $started) = ( 0, 0, 0, 0 );
	my $service = Cloudmin::Networks->new(host => $host, jobs => $jobs);
	# get_network_service() substitutes the isolated network controller.
	local *main::get_network_service = sub { $service };
	# is_readonly_mode() lets each request choose the current access mode.
	local *main::is_readonly_mode = sub { $readonly };
	# require_access(permission) simulates an access denial when requested.
	local *main::require_access = sub { die "Denied\n" if $denied };
	# get_image_jobs() supplies the fixture's token checker.
	local *main::get_image_jobs = sub { bless({ }, 'RemovalTokens') };
	# get_vm_jobs() supplies the isolated reservation and locking service.
	local *main::get_vm_jobs = sub { $jobs };
	# webmin_log(args...) prevents fixture actions from
	# writing the host log.
	local *main::webmin_log = sub { };
	# assert_idle(self) simulates a conflicting job only for the busy case.
	local *Cloudmin::Networks::assert_idle = sub { die "Busy\n" if $busy };
	# prepare_bridge_removal(self, name) reuses the reviewed fixture plan.
	local *Cloudmin::Networks::prepare_bridge_removal = sub { $plan };
	# begin(self, name, source, revision, owner, [operation]) Counts worker
	# starts without launching a process.
	local *RemovalHost::begin = sub { $started++; 'transaction' };

	# check_token(self, owner, token) accepts only the
	# fixture's signed value.
	{ package RemovalTokens;

		sub check_token
		{
		die "Token rejected\n"
			if (($_[2] || '') ne 'signed')
		} }
	my $review =
		main::call_bridge_api('bridge_remove_review',
				      { name => 'br0', token => 'signed' });
	is($review->{'revision'}, $plan->{'revision'},
	   'API review supplies the required revision');
	ok(!exists($review->{'saved'}) && !exists($review->{'files'}),
	   'API review excludes saved host configuration');
	# Denied, unsigned and busy requests must never reach
	# the worker launcher.
	$readonly = 1;
	ok(!eval { main::call_bridge_api('bridge_remove',
					 { token => 'signed' }); 1 },
	   'read-only API cannot remove');
	$readonly = 0; $denied = 1;
	ok(!eval { main::call_bridge_api('bridge_status', { }); 1 },
	   'status also requires host access');
	$denied = 0;
	ok(!eval { main::call_bridge_api('bridge_remove',
					 { token => 'bad' }); 1 },
	   'unsigned API removal rejected');
	$busy = 1;
	ok(!eval { main::call_bridge_api('bridge_remove',
					 { token => 'signed' }); 1 },
	   'pending jobs block API removal');
	is($started, 0, 'rejected API requests never launch workers');
	# The same controller accepts an authorized request and
	# rejects stale polls.
	$busy = 0;
	main::call_bridge_api('bridge_remove',
			      { name => 'br0', revision => $plan->{'revision'},
				token =>
					'signed' });
	is($started, 1, 'authorized API removal uses the shared controller');
	ok(!eval { main::call_bridge_api('bridge_status',
					 { id => 'stale' }); 1 },
	   'stale status ID rejected');
	}

done_testing();
