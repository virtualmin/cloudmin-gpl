#!/usr/bin/perl
# Exercise Webmin's Netplan writer and native generator in an isolated root. No
# network configuration is applied to the running host.
use strict;
use warnings;
no warnings 'once';
use FindBin;
use Cwd qw(abs_path);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Test::More;

BEGIN
{
die "Linux test host as root only\n" unless $^O eq 'linux' && $< == 0;
$ENV{'WEBMIN_CONFIG'} = '/etc/webmin';
$ENV{'WEBMIN_VAR'} = '/var/webmin';
$ENV{'REMOTE_USER'} = 'root';
chdir("$FindBin::Bin/../..") || die $!;
$0 = abs_path("$FindBin::Bin/../../network-worker.pl");
}
require './server-manager-lib.pl';
require './cloudmin-network-lib.pl';
our $module_root_directory;
foreign_require('net', 'net-lib.pl');
{
	package net;
	no warnings 'redefine';
	do "$main::module_root_directory/../net/netplan-lib.pl" || die $@ || $!;
	}
my $keep = @ARGV && $ARGV[0] eq '--keep';
my $root = tempdir('/var/tmp/cloudmin-netplan.XXXXXX', CLEANUP => !$keep);
diag($root) if $keep;
make_path("$root/etc/netplan");
$net::netplan_dir = "$root/etc/netplan";
my $file = "$root/etc/netplan/source.yaml";
my $original = <<'YAML';
network:
  version: 2
  renderer: networkd
  ethernets:
    ensfixture:
      match:
        macaddress: 02:11:22:33:44:55
      set-name: ensfixture
      addresses: [192.0.2.2/24, "2001:db8:11::2/64"]
      dhcp4: false
      accept-ra: true
      mtu: 1400
      nameservers:
        addresses: [192.0.2.1, "2001:db8:11::1"]
        search: [example.test]
      routes:
        - to: default
          via: 192.0.2.1
          metric: 90
      routing-policy:
        - from: 192.0.2.2
          table: 100
YAML
write_file_contents($file, $original);
chmod(0600, $file);
{
	package NetplanFixture;
	our @ISA = ('Cloudmin::HostNetwork');

	# backend(self) selects the isolated Netplan writer.
	sub backend
	{
	return 'netplan';
	}

	# unit(self, action, record) suppresses host
	# recovery service operations.
	sub unit
	{
	}

	# inventory(self) supplies the single synthetic Ethernet interface.
	sub inventory
	{
	return { backend => 'netplan', supported => 1,
		 interfaces => [
			 { name => 'ensfixture', candidate => 1, mac =>
									 '02:11:22:33:44:55',
			   addresses => [ '192.0.2.2/24',
					  '2001:db8:11::2/64' ] } ] };
	}
	}
my $host = NetplanFixture->new(directory => "$root/state",
			       networkd_directory => "$root/etc/systemd/network");
{
	no warnings 'redefine';
	# validate_netplan_config() checks generated files
	# inside the isolated root.
	local *net::validate_netplan_config = sub {
		my $out = '';
		my $rc =
			execute_command('netplan generate --root-dir '.
					quotemeta($root), undef, \$out, \$out);
		# Retain generated YAML as diagnostics if the native
		# generator rejects it.
		if ($rc) {
			diag(read_file_contents($_))
				foreach glob("$root/etc/netplan/*.yaml");
			}
		return $rc ? $out : undef;
		};
	my $plan = $host->prepare('brfixture', 'ensfixture');
	$host->save_bridge($plan);
	my @interfaces = net::boot_interfaces();
	my ($bridge) = grep { $_->{'name'} eq 'brfixture' } @interfaces;
	my ($port) = grep { $_->{'name'} eq 'ensfixture' } @interfaces;
	is($bridge->{'address'}, '192.0.2.2', 'IPv4 moved onto Netplan bridge');
	is_deeply($bridge->{'address6'}, [ '2001:db8:11::2' ],
		  'IPv6 preserved');
	is_deeply($bridge->{'nameserver'}, [ '192.0.2.1', '2001:db8:11::1' ],
		  'both DNS families preserved');
	is_deeply($bridge->{'search'}, [ 'example.test' ],
		  'DNS search preserved');
	ok(!$port->{'address'} && !@{$port->{'address6'} || [ ]},
	   'physical port has no IP settings');
	my $text = read_file_contents($bridge->{'file'});
	like($text, qr/accept-ra: true/, 'router advertisements preserved');
	like($text, qr/routing-policy:/, 'policy routing preserved');
	unlike($text, qr/set-name:|match:/,
	       'hardware matching stays on physical port');
	my $physical = read_file_contents($file);
	like($physical, qr/set-name: ensfixture/, 'physical rename retained');
	unlike($physical, qr/nameservers:|routing-policy:|routes:/,
	       'port has no duplicate routing or DNS');
	my @generated = glob("$root/run/systemd/network/*brfixture.network");
	ok(@generated,
	   'native Netplan generator accepts bridge and creates networkd configuration');
	my $generated = read_file_contents($generated[0]);
	like($generated, qr/Gateway=192\.0\.2\.1/,
	     'generated bridge retains gateway');
	like($generated, qr/DNS=2001:db8:11::1/,
	     'generated bridge retains IPv6 DNS');
	# Removal reads the newly written bridge, then recovery
	# restores that state.
	{
		no warnings 'redefine';
		# inventory(self) models the new bridge without activating it.
		local *NetplanFixture::inventory =
			sub { return { backend => 'netplan', supported => 1,
				       interfaces => [
					       { name => 'brfixture',
						 bridge => 1,
						 ports => [ 'ensfixture' ],
						 mac => '02:11:22:33:44:55',
						 addresses => [ '192.0.2.2/24',
								'2001:db8:11::2/64' ] },
					       { name => 'ensfixture',
						 master => 'brfixture',
						 addresses => [ ] } ] }; };
		my $removal = $host->prepare_remove('brfixture');
		$host->save_removal($removal);
		my ($ethernet) =
			grep {
				$_->{'fullname'} eq
					'ensfixture' } net::boot_interfaces();
		is($ethernet->{'address'}, '192.0.2.2',
		   'removal moves current IPv4 back to Ethernet');
		is_deeply($ethernet->{'address6'}, [ '2001:db8:11::2' ],
			  'removal retains IPv6');
		like(read_file_contents($file), qr/routing-policy:/,
		     'removal retains policy routes');
		like(read_file_contents($file), qr/set-name: ensfixture/,
		     'removal retains physical matching');
		ok(!grep({ $_->{'name'} eq 'brfixture' } net::boot_interfaces()),
		   'removed bridge has no persistent definition');

		# lock(self, name, callback) runs only the isolated
		# fixture transaction.
		{ package RemovalFixtureLock;

			sub lock
			{
			$_[2]->()
			} }
		# Undo removal first, retaining creation's
		# separate backup for later.
		local $host->{'jobs'} = bless({ }, 'RemovalFixtureLock');
		$removal->{'state'} = 'applying';
		$host->write_state($removal);
		$host->rollback(1);
		is(read_file_contents($bridge->{'file'}), $text,
		   'removal boot recovery restores exact bridge YAML');
		is(read_file_contents($file), $physical,
		   'removal boot recovery restores exact Ethernet YAML');
		}
	# Restore the snapshots through the same production recovery path.
	$plan->{'state'} = 'applying';
	$host->write_state($plan);

	# FixtureLock::lock(self, name, callback) runs the
	# private journal callback.
	{ package FixtureLock;

		sub lock
		{
		$_[2]->()
		} }
	$host->{'jobs'} = bless({ }, 'FixtureLock');
	$host->rollback(1);
	is(read_file_contents($file), $original,
	   'Netplan rollback restores exact source YAML');
	ok(!-e $plan->{'new_file'} && !-e $plan->{'api_file'},
	   'Netplan rollback removes generated bridge files');
	ok(!glob("$root/run/systemd/network/*brfixture.*"),
	   'boot rollback also removes stale generated bridge units');
	# DHCP identity is saved outside YAML because
	# Netplan has no IAID option.
	my $dhcp = $original;
	$dhcp =~ s/dhcp4: false/dhcp4: true/;
	$dhcp =~ s/addresses: \[192\.0\.2\.2\/24, /addresses: [/;
	write_file_contents($file, $dhcp);
	unflush_file_lines($file);
	# command(self, argv, [quiet], [safe]) returns the
	# DUID and current lease.
	local *NetplanFixture::command = sub {
		return '{"DHCPv4Client":{"ClientIdentifier":[255,86,80,77,152,0,2,0,0,171,17,153,221,78,37,77,97,61,152]},"Addresses":[{"Address":[192,0,2,2],"ConfigSource":"DHCPv4","ConfigState":"configured"}]}';
		};
	$plan = $host->prepare('brfixture', 'ensfixture');
	$host->save_bridge($plan);
	like(read_file_contents($plan->{'dhcp4_dropin'}),
	     qr/^IAID=1448103320$/m,
	     'persistent bridge drop-in retains the DHCP client identity');
	like(read_file_contents($plan->{'dhcp4_dropin'}),
	     qr/^RequestAddress=192\.0\.2\.2$/m,
	     'persistent bridge requests the previous DHCP address');
	is((stat($plan->{'dhcp4_dropin'}))[2] & 0777, 0644,
	   'networkd can read the DHCP identity drop-in');
	ok(exists($plan->{'files'}->{$plan->{'dhcp4_dropin'}}),
	   'DHCP identity drop-in is covered by the recovery journal');
	# Removal must move the native override and recovery must move it back.
	{
		no warnings 'redefine';
		# inventory(self) models the DHCP bridge just written to disk.
		local *NetplanFixture::inventory =
			sub { return { backend => 'netplan', supported => 1,
				       interfaces => [
					       { name => 'brfixture',
						 bridge => 1,
						 ports => [ 'ensfixture' ],
						 mac => '02:11:22:33:44:55',
						 addresses => [ '192.0.2.2/24',
								'2001:db8:11::2/64' ] },
					       { name => 'ensfixture',
						 master => 'brfixture',
						 addresses => [ ] } ] }; };
		my $removal = $host->prepare_remove('brfixture');
		$host->save_removal($removal);
		like(read_file_contents($removal->{'dhcp4_dropin'}),
		     qr/^RequestAddress=192\.0\.2\.2$/m,
		     'removal requests the same lease on Ethernet');
		ok(!-e $removal->{'old_dhcp4_dropin'},
		   'removed bridge DHCP override is deleted');
		ok(!-d File::Basename::dirname(
			$removal->{'old_dhcp4_dropin'}),
		   'empty bridge override directory does not block recreating the bridge');
		# Recovery must recreate the deleted override directory too.
		$removal->{'state'} = 'applying';
		$host->write_state($removal);
		$host->rollback(1);
		ok(-f $removal->{'old_dhcp4_dropin'} &&
		   !-e $removal->{'dhcp4_dropin'},
		   'rollback restores the bridge DHCP override and removes the port override');
		}
	$plan->{'state'} = 'applying';
	$host->write_state($plan);
	$host->rollback(1);
	is(read_file_contents($file), $dhcp,
	   'DHCP source YAML restored exactly');
	ok(!-e $plan->{'dhcp4_dropin'} && !-d $plan->{'dhcp4_directory'},
	   'recovery removes the DHCP identity drop-in and its directory');
	# Hand-written and cloud-init layouts can keep both devices in one file.
	foreach my $bridge_first ( 0, 1 ) {
		# Both section orders must preserve the unrelated
		# ensother definition.
		my $ethernet =
			"  ethernets:\n    ensfixture:\n      dhcp4: false\n".
			"    ensother:\n      addresses: [198.51.100.2/24]\n      optional: true\n";
		my $bridges =
			"  bridges:\n    brfixture:\n      interfaces: [ensfixture]\n".
			"      addresses: [192.0.2.2/24, '2001:db8:11::2/64']\n".
			"      nameservers:\n        addresses: [192.0.2.1]\n";
		my $shared = "network:\n  version: 2\n  renderer: networkd\n".
			     ($bridge_first
				     ? $bridges.$ethernet
				     : $ethernet.$bridges);
		write_file_contents($file, $shared);
		unflush_file_lines($file);
		# inventory(self) models the bridge and port
		# defined in the shared file.
		local *NetplanFixture::inventory =
			sub { return { backend => 'netplan', supported => 1,
				       interfaces => [
					       { name => 'brfixture',
						 bridge => 1,
						 ports => [ 'ensfixture' ],
						 mac => '02:11:22:33:44:55',
						 addresses => [ '192.0.2.2/24',
								'2001:db8:11::2/64' ] },
					       { name => 'ensfixture',
						 master => 'brfixture',
						 addresses => [ ] } ] }; };
		my $removal = $host->prepare_remove('brfixture');
		my $ok = eval { $host->save_removal($removal); 1 };
		# Native validation catches malformed or emptied YAML sections.
		ok($ok,
		   "shared YAML removal accepted by native Netplan (bridge first: $bridge_first)") or diag($@);
		my ($port) =
			grep {
				$_->{'fullname'} eq
					'ensfixture' } net::boot_interfaces();
		my ($other) =
			grep {
				$_->{'fullname'} eq
					'ensother' } net::boot_interfaces();
		is($port->{'address'}, '192.0.2.2',
		   'shared YAML retains the transferred IPv4 address');
		is_deeply($port->{'address6'}, [ '2001:db8:11::2' ],
			  'shared YAML retains IPv6');
		is_deeply($port->{'nameserver'}, [ '192.0.2.1' ],
			  'shared YAML retains DNS');
		is($other->{'address'}, '198.51.100.2',
		   'unrelated interface survives deletion');
		unlike(read_file_contents($file) || '', qr/^  bridges:/m,
		       'no null bridge mapping remains');
		# File recovery must preserve original ordering
		# and formatting exactly.
		$removal->{'state'} = 'applying';
		$host->write_state($removal);
		$host->rollback(1);
		is(read_file_contents($file), $shared,
		   'recovery restores the exact shared file');
		}
	# Enabling DHCPv4 does not imply an IPv4 lease on an IPv6-only network.
	{
		write_file_contents($file,
				    "network:\n  version: 2\n  ethernets:\n    ensfixture:\n".
				    "      dhcp4: true\n      addresses: ['2001:db8:11::2/64']\n");
		unflush_file_lines($file);
		# command(self, argv, [quiet], [safe]) rejects
		# unexpected lease probes.
		local *NetplanFixture::command =
			sub { die "Unexpected DHCP lease probe\n" };
		# inventory(self) supplies an eligible Ethernet
		# port with only IPv6.
		local *NetplanFixture::inventory =
			sub { return { backend => 'netplan', supported => 1,
				       interfaces => [ { name => 'ensfixture',
							 candidate => 1,
							 mac => '02:11:22:33:44:55',
							 addresses => [ '2001:db8:11::2/64' ] } ] }; };
		my $creation = $host->prepare('brfixture', 'ensfixture');
		ok(!$creation->{'dhcp4_dropin'},
		   'IPv6-only creation needs no DHCPv4 lease');
		$host->save_bridge($creation);
		# inventory(self) models that same lease-free
		# configuration on a bridge.
		local *NetplanFixture::inventory =
			sub { return { backend => 'netplan', supported => 1,
				       interfaces => [
					       { name => 'brfixture',
						 bridge => 1,
						 ports => [ 'ensfixture' ],
						 mac => '02:11:22:33:44:55',
						 addresses => [ '2001:db8:11::2/64' ] },
					       { name => 'ensfixture',
						 master => 'brfixture',
						 addresses => [ ] } ] }; };
		my $removal = $host->prepare_remove('brfixture');
		ok(!$removal->{'dhcp4_dropin'},
		   'IPv6-only removal needs no DHCPv4 lease');
		$host->save_removal($removal);
		# Recovery must also skip DHCP rather than
		# inventing an IPv4 request.
		$host->restore_netplan_dhcp4($removal);
		my ($port) =
			grep {
				$_->{'fullname'} eq
					'ensfixture' } net::boot_interfaces();
		is_deeply($port->{'address6'}, [ '2001:db8:11::2' ],
			  'lease-free removal retains IPv6');
		ok($port->{'dhcp'},
		   'DHCPv4 remains enabled without inventing a lease');
		}
	# A plain cloud image may have no match, rename, MTU
	# or other port options.
	write_file_contents($file,
			    "network:\n  version: 2\n  ethernets:\n    ensfixture:\n      dhcp4: true\n");
	unflush_file_lines($file);
	$plan = $host->prepare('brfixture', 'ensfixture');
	$host->save_bridge($plan);
	ok(!net::validate_netplan_config(),
	   'minimal DHCP configuration remains valid after conversion');
	}
done_testing();
