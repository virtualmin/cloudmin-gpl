#!/usr/bin/perl
# Check real libvirt networks and guest traffic on a disposable Cloudmin host.
# Only objects created by this run are cleaned up.
use strict;
use warnings;
use FindBin;
use Cwd qw(abs_path);
use Test::More;
use Digest::SHA qw(sha256_hex);

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
our ($remote_user);
$remote_user = 'root';
my $svc = get_network_service(1);
my $host = $svc->{'host'};
my $conn = $svc->{'adapter'}->connect();
my (@created, $guest, $namespace, $port);
my $ok = eval {
	foreach my $mode (qw(nat route isolated)) {
		my $number = 240 + @created;
		my $name = 'cmtest'.$mode;
		die "Fixture name already in use\n"
			if (
				grep {
					$_->get_name() eq $name } $conn->list_all_networks(
						0));
		$svc->create({ name => $name, mode => $mode, ipv4 =>
								     "192.168.$number.1/24",
			       ipv6 => "fd12:3456:$number\::1/64",
			       autostart => 1,
			       dhcp => 1,
			       dhcp_start => "192.168.$number.10",
			       dhcp_end => "192.168.$number.30" });
		my ($net) =
			grep { $_->get_name() eq $name } $conn->list_all_networks(
				0);
		push(@created, $net);
		ok($net->is_active() && $net->is_persistent() &&
		   $net->get_autostart(),
		   "$mode active, persistent and starts at boot");
		my $xml = $net->get_xml_description(0);
		my $doc = Cloudmin::Libvirt::parse_xml_document($xml);
		my $bridge = $doc->findvalue('/network/bridge/@name');
		diag('Bridge: '.
		     $doc->findnodes('/network/bridge')->[0]->toString());
		my $ns = 'cmnetfixture';
		# Create an isolated guest-side interface and
		# exercise the real bridge.
		$host->command([ 'ip', 'netns', 'add', $ns ]); $namespace = $ns;
		$host->command([ 'ip', 'link', 'add', 'cmnetport', 'type',
				 'veth', 'peer', 'name',
				 'cmguest' ]); $port = 'cmnetport';
		$host->command([ 'ip', 'link', 'set', 'cmguest', 'netns',
				 $ns ]);
		$host->command([ 'ip', 'link', 'set', $port, 'master',
				 $bridge ]);
		$host->command([ 'ip', 'link', 'set', $port, 'up' ]);
		$host->command([ 'ip', '-n', $ns, 'link', 'set', 'cmguest',
				 'up' ]);
		my $lease =
			$host->command([ 'ip', 'netns', 'exec', $ns, 'busybox',
					 'udhcpc',
					 '-i', 'cmguest', '-n', '-q', '-s',
					 '/bin/true',
					 '-t', '20', '-T', '2' ]);
		like($lease, qr/lease of 192\.168\.$number\./,
		     "$mode supplies DHCP to guest");
		$host->command([ 'ip', '-n', $ns, 'address', 'add',
				 "192.168.$number.50/24", 'dev', 'cmguest' ]);
		$host->command([ 'ip', '-n', $ns, 'route', 'add', 'default',
				 'via', "192.168.$number.1" ]);
		$host->command([ 'ip', 'netns', 'exec', $ns, 'ping', '-c', '1',
				 '-W', '2', "192.168.$number.1" ]);
		pass("$mode guest reaches bridge gateway");
		# Only the NAT fixture checks outbound HTTPS access.
		if ($mode eq 'nat') {
			$host->command([ 'ip', 'netns', 'exec', $ns, 'curl',
					 '-4', '-fsSI', '--max-time', '20',
					 'https://deb.debian.org/debian/' ]);
			pass('NAT guest reaches Debian mirror over HTTPS');
			}
		$host->command([ 'ip', 'link', 'delete', $port ]); undef $port;
		$host->command([ 'ip', 'netns', 'delete',
				 $namespace ]); undef $namespace;
		}
	# A stopped VM still protects its saved network from
	# destructive changes.
	die "Fixture VM already exists\n"
		if (
			grep {
				$_->get_name() eq 'cmnetfixture' } $conn->list_all_domains(
					0));
	$guest =
		$conn->define_domain(
			'<domain type="qemu"><name>cmnetfixture</name><memory unit="MiB">64</memory><vcpu>1</vcpu><os><type>hvm</type></os><devices><interface type="network"><source network="cmtestnat"/></interface></devices></domain>');
	my $net = $created[0];
	my $rev = sha256_hex($net->get_xml_description(0));
	ok(!eval { $svc->change('stop', $net->get_uuid_string(), $rev); 1 },
	   'attached stopped VM blocks stopping network');
	like($@, qr/Detach/, 'protected network explains why');
	$guest->undefine(); undef $guest;
	foreach my $net (@created) {
		my $uuid = $net->get_uuid_string();
		my $revision = sha256_hex($net->get_xml_description(0));
		$svc->change('autostart', $uuid, $revision, 0);
		ok(!$net->get_autostart(), 'boot policy can be disabled');
		$svc->change('stop', $uuid, $revision);
		ok(!$net->is_active(), 'unused network stops');
		$svc->change('start', $uuid,
			     sha256_hex($net->get_xml_description(0)));
		ok($net->is_active(), 'saved network restarts');
		$svc->change('stop', $uuid,
			     sha256_hex($net->get_xml_description(0)));
		$svc->change('delete', $uuid,
			     sha256_hex($net->get_xml_description(0)));
		pass('inactive network deleted through controller');
		}
	@created = ();
	1;
	};
my $error = $@;
# Cleanup runs even when an assertion or command failed
# halfway through a fixture.
eval { $guest->undefine() } if $guest;
eval { $host->command([ 'ip', 'netns', 'delete', $namespace ]) } if $namespace;
eval { $host->command([ 'ip', 'link', 'delete', $port ]) } if $port;
foreach my $net (@created) {
	eval {
		$net->destroy() if $net->is_active();
		$net->undefine();
		};
	}
die $error if !$ok;
done_testing();
