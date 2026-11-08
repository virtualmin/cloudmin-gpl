use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use Test::More;
use WebminCore qw(convert_from_json);
require "$Bin/../lib/Cloudmin/NetworkPreflight.pm";

# Canonical subnet matching must accept both libvirt address representations.
my $network = { type => 'network', name => 'default', forward => 'nat',
		bridge => 'virbr0', address => '192.168.122.1', netmask =>
									'255.255.255.0' };
my $cidr = '192.168.122.0/24';
is(Cloudmin::NetworkPreflight::subnet($network), $cidr,
   'canonical subnet from netmask');
is(Cloudmin::NetworkPreflight::subnet({ %$network, prefix => 24 }), $cidr,
   'explicit prefix');
ok(!Cloudmin::NetworkPreflight::subnet({ %$network, netmask => '255.0.255.0' }),
   'invalid mask refused');

# Native nftables output uses null verdicts and named bridge matches.
my $native = <<'JSON';
{"nftables":[
 {"chain":{"family":"ip","table":"libvirt_network","name":"forward","hook":"forward"}},
 {"chain":{"family":"ip","table":"libvirt_network","name":"guest_output"}},
 {"chain":{"family":"ip","table":"libvirt_network","name":"guest_input"}},
 {"chain":{"family":"ip","table":"libvirt_network","name":"guest_nat","hook":"postrouting"}},
 {"rule":{"family":"ip","table":"libvirt_network","chain":"forward","expr":[{"jump":{"target":"guest_output"}}]}},
 {"rule":{"family":"ip","table":"libvirt_network","chain":"forward","expr":[{"jump":{"target":"guest_input"}}]}},
 {"rule":{"family":"ip","table":"libvirt_network","chain":"guest_output","expr":[
   {"match":{"op":"==","left":{"payload":{"protocol":"ip","field":"saddr"}},"right":{"prefix":{"addr":"192.168.122.0","len":24}}}},
   {"match":{"op":"==","left":{"meta":{"key":"iif"}},"right":"virbr0"}},{"accept":null}]}},
 {"rule":{"family":"ip","table":"libvirt_network","chain":"guest_input","expr":[
   {"match":{"op":"==","left":{"payload":{"protocol":"ip","field":"daddr"}},"right":{"prefix":{"addr":"192.168.122.0","len":24}}}},
   {"match":{"op":"==","left":{"meta":{"key":"oif"}},"right":"virbr0"}},{"accept":null}]}},
 {"rule":{"family":"ip","table":"libvirt_network","chain":"guest_nat","expr":[
   {"match":{"op":"==","left":{"payload":{"protocol":"ip","field":"saddr"}},"right":{"prefix":{"addr":"192.168.122.0","len":24}}}},
   {"match":{"op":"!=","left":{"payload":{"protocol":"ip","field":"daddr"}},"right":{"prefix":{"addr":"192.168.122.0","len":24}}}},
   {"masquerade":null}]}}
]}
JSON

# The iptables backend can be legacy or nft-compatible with
# the same save format.
my $legacy = <<'SAVE';
*filter
:FORWARD ACCEPT [0:0]
:LIBVIRT_FWO - [0:0]
:LIBVIRT_FWI - [0:0]
-A FORWARD -j LIBVIRT_FWO
-A FORWARD -j LIBVIRT_FWI
-A LIBVIRT_FWO -s 192.168.122.0/24 -i virbr0 -j ACCEPT
-A LIBVIRT_FWI -d 192.168.122.0/24 -o virbr0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
COMMIT
*nat
:POSTROUTING ACCEPT [0:0]
:LIBVIRT_PRT - [0:0]
-A POSTROUTING -j LIBVIRT_PRT
-A LIBVIRT_PRT -s 192.168.122.0/24 ! -d 192.168.122.0/24 -j MASQUERADE
COMMIT
SAVE

# Exercise complete, detached, wrong-network and partially erased rulesets.
for my $backend ( 'nft', 'iptables' ) {
	my $source = $backend eq 'nft' ? $native : $legacy;
	my $parse = $backend eq 'nft'
		? sub { Cloudmin::NetworkPreflight::nft_chains(
			convert_from_json($_[0])) }
		: sub { Cloudmin::NetworkPreflight::iptables_chains($_[0]) };
	my $chains = $parse->($source);
	ok(!Cloudmin::NetworkPreflight::missing_rules($network, $cidr, $chains),
	   "$backend complete rules pass");
	my $other = $source;
	$other =~ s/192\.168\.122/192.168.123/g;
	like(Cloudmin::NetworkPreflight::missing_rules($network, $cidr,
						       $parse->($other)),
	     qr/forwarding/,
	     "$backend another network cannot hide missing rules");
	$_->{'hook'} =
		'' for grep { ($_->{'hook'} || '') eq 'postrouting' } @$chains;
	is(Cloudmin::NetworkPreflight::missing_rules($network, $cidr, $chains),
	   'IPv4 NAT rules',
	   "$backend detached NAT rules refused");
	ok(!Cloudmin::NetworkPreflight::missing_rules({ %$network, forward =>
									   'route' }, $cidr, $chains),
	   "$backend routed networks need no NAT");
	$_->{'rules'} =
		[ ] for grep { ($_->{'hook'} || '') eq 'forward' } @$chains;
	is(Cloudmin::NetworkPreflight::missing_rules($network, $cidr, $chains),
	   'IPv4 forwarding rules',
	   "$backend detached forward chains refused");
	}
# iptables-nft may use compatibility NAT expressions and interface-name keys.
my $compat = $native;
$compat =~ s/"masquerade":null/"xt":{"type":"target","name":"MASQUERADE"}/;
$compat =~ s/"([io]if)"/"${1}name"/g;
ok(!Cloudmin::NetworkPreflight::missing_rules($network, $cidr,
					      Cloudmin::NetworkPreflight::nft_chains(
						      convert_from_json($compat))),
   'iptables-nft compatibility expressions accepted');

# Command failures stay distinct from an inspected but empty ruleset.
{
	no warnings qw(redefine once);
	my ($forward, $nft, $iptables, @calls) = ( '1', $native, $legacy );
	local *Cloudmin::NetworkPreflight::read_file_contents =
		sub { $forward };
	local *Cloudmin::NetworkPreflight::command = sub {
		push(@calls, $_[0]);
		return $_[0] eq 'nft' ? $nft : $iptables;
		};
	ok(eval { Cloudmin::NetworkPreflight::check($network); 1 },
	   'live prerequisites accepted');
	$forward = '0';
	ok(!eval { Cloudmin::NetworkPreflight::check($network); 1 },
	   'disabled forwarding refused');
	like($@, qr/IPv4 forwarding is disabled/,
	     'disabled forwarding explained');
	$forward = '1';
	$nft = $iptables = undef;
	ok(!eval { Cloudmin::NetworkPreflight::check($network); 1 },
	   'unreadable firewall refused');
	like($@, qr/Cannot read/, 'inspection failure explained');
	$nft = '{"nftables":[]}';
	ok(!eval { Cloudmin::NetworkPreflight::check($network); 1 },
	   'erased firewall refused');
	like($@, qr/Open Host Overview and use Restore Network Rules/,
	     'missing rules name the recovery page and action');
	$iptables = $legacy;
	ok(eval { Cloudmin::NetworkPreflight::check($network); 1 },
	   'legacy rules accepted when nft is empty');
	@calls = ();
	for my $skip ({ %$network, type => 'bridge' },
		      { %$network, forward => 'isolated' },
		      { %$network, address => '' }) {
		ok(eval { Cloudmin::NetworkPreflight::check($skip); 1 },
		   'unmanaged or IPv6-only forwarding skipped');
		}
	is(scalar(@calls), 0, 'skipped networks do not run firewall commands');
	}
# Overview and creation share the same diagnosis, without
# inspecting skipped networks.
{
	package PreflightAdapter;

	# uri(self) defaults to local QEMU but permits a remote-connection case.

	sub uri
	{
	$_[0]->{'uri'} || 'qemu:///system'
	}

	# list_networks(self) returns the chosen mix of active
	# and unmanaged networks.

	sub list_networks
	{
	$_[0]->{'networks'}
	}

	# disconnect(self) records disposal of the pre-restart connection.

	sub disconnect
	{
	$_[0]->{'disconnected'}++
	}
	package main;
	no warnings qw(redefine once);
	my $adapter = bless({ networks => [ { %$network, active => 1 },
					    { %$network, active => 0,
					      name => 'stopped' },
					    { %$network, active => 1,
					      forward => 'isolated',
					      name => 'isolated' } ] },
			    'PreflightAdapter');
	my ($inspections, $restored, @commands);
	local *Cloudmin::NetworkPreflight::inspect = sub {
		$inspections++;
		return { forwarding => 1, readable => 1,
			 chains => $restored
				 ? Cloudmin::NetworkPreflight::iptables_chains(
					 $legacy)
				 : [ ] };
		};
	my $report = Cloudmin::NetworkPreflight::report($adapter);
	is(scalar(@$report), 1, 'overview checks only active managed networks');
	is($inspections, 1, 'overview reads the firewall once');
	ok(!$report->[0]->{'ok'} && $report->[0]->{'repairable'},
	   'missing rules offer recovery');
	local *Cloudmin::NetworkPreflight::read_file_contents = sub { '1' };
	local *Cloudmin::NetworkPreflight::service_command = sub {
		push(@commands, [ @_[0, 1] ]);
		# This fixture uses monolithic libvirt, not the
		# modular network daemon.
		return undef if ($_[1] eq 'virtnetworkd.service');
		# Merely checking service state must not repair
		# the simulated firewall.
		$restored = 1 if ($_[0] eq 'restart');
		return '';
		};
	my $reconnected;
	is(Cloudmin::NetworkPreflight::restore($adapter,
					       sub { $reconnected++; $adapter }),
	   'libvirtd.service', 'monolithic service restores the rules');
	is($reconnected, 1,
	   'verification reconnects after the service restart');
	is($adapter->{'disconnected'}, 1,
	   'old connection is closed before restarting its daemon');
	is_deeply($commands[-1], [ 'restart', 'libvirtd.service' ],
		  'restarts the daemon, not a network');
	ok(Cloudmin::NetworkPreflight::report($adapter)->[0]->{'ok'},
	   'overview clears the repaired failure');
	@commands = ();
	Cloudmin::NetworkPreflight::restore($adapter,
					    sub { die 'unneeded reconnect' });
	is(scalar(@commands), 0,
	   'repeated recovery leaves healthy networking alone');
	$restored = 0;
	local *Cloudmin::NetworkPreflight::service_command = sub { return '' };
	ok(!eval { Cloudmin::NetworkPreflight::restore($adapter,
						       sub { $adapter }); 1 },
	   'service success alone cannot claim recovery');
	like($@, qr/missing IPv4 forwarding/,
	     'verification failure remains visible');
	local $adapter->{'uri'} = 'qemu+ssh://remote/system';
	is_deeply(Cloudmin::NetworkPreflight::report($adapter), [ ],
		  'remote connections do not inspect the local firewall');
	ok(!eval { Cloudmin::NetworkPreflight::restore($adapter,
						       sub { $adapter }); 1 },
	   'remote connection cannot restart local services');
	}
# A slow stop must have time to finish before startup and rule verification.
{
	no warnings qw(redefine once);
	my ($exit, $stderr, $command) = ( 0, '', '' );
	local *Cloudmin::NetworkPreflight::execute_command = sub {
		$command = $_[0];
		${$_[2]} = ''; ${$_[3]} = $stderr;
		return $exit;
		};
	my $reason;
	is(Cloudmin::NetworkPreflight::service_command('restart',
						       'libvirtd.service',
						       \$reason), '',
	   'successful restart proceeds to verification');
	like($command, qr/timeout -k 2 60 /,
	     'restart wait exceeds the 30-second daemon shutdown');
	$exit = 124 << 8;
	# A timed-out client does not imply that systemd
	# abandoned its restart job.
	ok(!defined(Cloudmin::NetworkPreflight::service_command('restart',
								'libvirtd.service', \$reason)),
	   'timeout does not claim success');
	like($reason, qr/may still be restarting/,
	     'timeout does not claim systemd stopped the restart');
	$exit = 1 << 8; $stderr = "Job failed.\nSee the service journal.\n";
	# Ordinary service failures retain useful diagnostics
	# without raw newlines.
	Cloudmin::NetworkPreflight::service_command('restart',
						    'libvirtd.service',
						    \$reason);
	like($reason, qr/Job failed\. See the service journal\./,
	     'service failure retains its diagnostic');
	}
done_testing();
