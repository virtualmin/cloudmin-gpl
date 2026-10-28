#!/usr/bin/perl
# Exercise Webmin's ifupdown writer using temporary configuration files only.
use strict;
use warnings;
no warnings 'once';
use FindBin qw($Bin);
use Cwd qw(abs_path);
use File::Temp qw(tempdir);
use Test::More;
BEGIN {
	die "Disposable Linux guest as root only\n" unless $^O eq 'linux' && $< == 0;
	$ENV{'WEBMIN_CONFIG'} = '/etc/webmin';
	$ENV{'WEBMIN_VAR'} = '/var/webmin';
	$ENV{'REMOTE_USER'} = 'root';
	chdir("$Bin/../..") || die $!;
	$0 = abs_path("$Bin/../../network-worker.pl");
}
require './server-manager-lib.pl';
require './cloudmin-network-lib.pl';
foreign_require('net', 'net-lib.pl');
our $module_root_directory;
{
	package net;
	no warnings 'redefine';
	do "$main::module_root_directory/../net/ifupdown-lib.pl" || die $@ || $!;
	do "$main::module_root_directory/../net/debian-linux-lib.pl" || die $@ || $!;
}
my $root = tempdir('/var/tmp/cloudmin-ifupdown.XXXXXX', CLEANUP => 1);
local $net::network_interfaces_config = "$root/interfaces";
my $source_file = "$root/source";
my $original = "# Preserve order, spacing and comments\nauto enp0s123\n".
	"iface enp0s123 inet manual\n\n  auto lo ethfixture\n".
	"iface lo inet loopback\n\nsource $source_file\n";
my $source = "iface ethfixture inet static\n\taddress 192.0.2.2/24\n\tmtu 9000\n\n".
	"iface ethfixture inet6 static\n\taddress 2001:db8::2/64\n";
write_file_contents($net::network_interfaces_config, $original);
write_file_contents($source_file, $source);
{
	package IfupdownFixture;
	our @ISA = ('Cloudmin::HostNetwork');
	# backend(self) selects the temporary ifupdown files without host detection.
	sub backend { 'debian-linux' }
	# unit(self, action, arguments...) omits host-wide recovery service changes.
	sub unit { }
	# command(self, arguments...) prohibits network activation in this file test.
	sub command { die "Unexpected host command\n" }
	# ipv6_address_mode(self, device) supplies the fixture's normal kernel mode.
	sub ipv6_address_mode { 'eui64' }
	package IfupdownFixtureLock;
	# lock(self, name, callback) runs against the private fixture journal.
	sub lock { $_[2]->() }
}
my $host = IfupdownFixture->new(directory => "$root/state",
	jobs => bless({}, 'IfupdownFixtureLock'));
my $plan = {mode => 'debian-linux', name => 'brfixture', source => 'ethfixture',
	mac => '02:11:22:33:44:55', state => 'armed',
	defs => [grep { $_->[0] eq 'ethfixture' } net::get_interface_defs()],
	files => $host->snapshot([$net::network_interfaces_config, $source_file])};
$host->write_state($plan);
$host->save_bridge($plan);
is(read_file_contents($net::network_interfaces_config), $original."auto brfixture\n",
	'actual ifupdown writer preserves all unrelated startup lines and stanzas');
is_deeply([net::get_auto_defs()], [qw(enp0s123 lo ethfixture brfixture)],
	'original startup order is preserved and bridge is appended');
my @defs = net::get_interface_defs();
my ($v4) = grep { $_->[0] eq 'brfixture' && $_->[1] eq 'inet' } @defs;
my ($v6) = grep { $_->[0] eq 'brfixture' && $_->[1] eq 'inet6' } @defs;
ok($v4 && $v6, 'both bridge address families survive the real parser');
ok(grep({ $_->[0] eq 'address' && $_->[1] eq '192.0.2.2/24' } @{$v4->[3]}),
	'bridge retains IPv4 address');
ok(grep({ $_->[0] eq 'address' && $_->[1] eq '2001:db8::2/64' } @{$v6->[3]}),
	'bridge retains IPv6 address');
ok(grep({ $_->[0] eq 'mtu' && $_->[1] eq '9000' } @{$v4->[3]}), 'bridge retains MTU');
ok(!grep({ $_->[2] ne 'manual' || @{$_->[3]} }
	grep { $_->[0] eq 'ethfixture' } @defs), 'port stanzas no longer carry addresses');
# Remove the newly saved bridge and recover its current dual-stack stanzas.
{
	no warnings 'redefine';
	# inventory(self) models the bridge without activating any host interfaces.
	local *IfupdownFixture::inventory = sub { return {backend => 'debian-linux', supported => 1,
		interfaces => [{name => 'brfixture', bridge => 1, ports => ['ethfixture'],
			addresses => ['192.0.2.2/24'], mac => '02:11:22:33:44:55'},
			{name => 'ethfixture', master => 'brfixture', addresses => []}]}; };
	my $before = read_file_contents($source_file);
	my $removal = $host->prepare_remove('brfixture');
	$host->save_removal($removal);
	my @removed = net::get_interface_defs();
	ok(!grep({ $_->[0] eq 'brfixture' } @removed), 'removed bridge stanzas disappear');
	my ($port4) = grep { $_->[0] eq 'ethfixture' && $_->[1] eq 'inet' } @removed;
	my ($port6) = grep { $_->[0] eq 'ethfixture' && $_->[1] eq 'inet6' } @removed;
	ok($port4 && $port6, 'removal restores both address families on Ethernet');
	ok(grep({ $_->[0] eq 'address' && $_->[1] eq '192.0.2.2/24' } @{$port4->[3]}),
		'current bridge address moves to Ethernet');
	ok(!grep({ $_->[0] =~ /^bridge_/ } @{$port4->[3]}), 'Ethernet has no bridge options');
	ok(!grep({ $_ eq 'brfixture' } net::get_auto_defs()), 'removed bridge does not start at boot');
	# This backup restores the bridge, rather than the original standalone port.
	$removal->{'state'} = 'armed';
	$host->write_state($removal);
	$host->rollback(1);
	is(read_file_contents($source_file), $before, 'removal recovery restores exact bridge and port stanzas');
}
# Then undo creation using its original, separate journal snapshot.
$host->write_state($plan);
$host->rollback(1);
is(read_file_contents($net::network_interfaces_config), $original, 'rollback restores main file byte for byte');
is(read_file_contents($source_file), $source, 'rollback restores included source file byte for byte');
done_testing();
