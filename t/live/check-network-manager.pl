#!/usr/bin/perl
# Check cloud-init keyfile preparation without changing host connections.
use strict;
use warnings;
no warnings 'once';
use FindBin qw($Bin);
use Cwd qw(abs_path);
use File::Temp qw(tempdir);
use Test::More;

BEGIN
{
die "Linux test host as root only\n" unless $^O eq 'linux' && $< == 0;
$ENV{'WEBMIN_CONFIG'} = '/etc/webmin';
$ENV{'WEBMIN_VAR'} = '/var/webmin';
$ENV{'REMOTE_USER'} = 'root';
chdir("$Bin/../..") || die $!;
$0 = abs_path("$Bin/../../network-worker.pl");
}
require './server-manager-lib.pl';
require './cloudmin-network-lib.pl';
foreign_require('net', 'net-lib.pl');
die "NetworkManager backend required\n" unless defined(&net::read_nm_config);
my $root = tempdir('/var/tmp/cloudmin-nm-review.XXXXXX', CLEANUP => 1);
local $net::nm_conn_dir = $root;
my $file = "$root/source.nmconnection";
my $original =
	"[connection]\nid=fixture\nuuid=ebf40ec8-cfe3-4482-a2fc-fb343f87ab01\ntype=ethernet\ninterface-name=ensfixture\n\n[ipv4]\nmethod=auto\n\n[ipv6]\nmethod=auto\n\n[user]\norg.freedesktop.NetworkManager.origin=cloud-init\n";
write_file_contents($file, $original);
chmod(0600, $file);
{
	package NMFixture;
	our @ISA = ('Cloudmin::HostNetwork');

	# inventory(self) supplies the isolated NetworkManager profile.

	sub inventory
	{
	return { backend => 'nm', supported => 1, interfaces => [
		{ name => 'ensfixture', candidate => 1, mac =>
								'02:11:22:33:44:55', addresses =>
											     [ '192.0.2.2/24' ] } ] };
	}
	}
my $host = NMFixture->new(directory => "$root/state");
# The synthetic port has no live DHCP client; supply its active lease options.
local *Cloudmin::HostNetwork::command = sub {
	return "DHCP4.OPTION[1]:ip_address = 192.0.2.2\n".
	       "DHCP4.OPTION[2]:dhcp_client_identifier = ff:12:34:56:78:00:02:00:00:ab:11:01:02\n";
	};
my $plan = $host->prepare('brfixture', 'ensfixture');
ok($plan, 'cloud-init origin metadata is accepted');
$plan->{'bridge_uuid'} = 'de3d11a2-71ce-4467-95eb-c5d4d811beac';
{
	# Suppress activation requests; only the isolated keyfile writer runs.
	no warnings 'redefine';
	local *Cloudmin::HostNetwork::command = sub { };
	local *net::save_nm_config = sub { };
	$host->save_bridge($plan);
	}
is(read_file_contents($file), $original,
   'original cloud-init metadata is retained');
my $bridge = net::read_nm_config($plan->{'new_file'});
is(net::find_nm_config($bridge, 'connection', 'type'), 'bridge',
   'bridge keyfile is generated');
is(net::find_nm_config($bridge, 'ipv4', 'method'), 'auto',
   'IPv4 method moves to the bridge');
is(net::find_nm_config($bridge, 'ipv4', 'dhcp-client-id'),
   'ff:12:34:56:78:00:02:00:00:ab:11:01:02',
   'bridge retains the active DHCP client identity');
is(net::find_nm_config($bridge, 'ipv6', 'method'), 'auto',
   'IPv6 method moves to the bridge');
unlink($plan->{'new_file'}) || die $!;
write_file_contents($file, $original."\n[802-1x]\neap=tls;\n");
ok(!eval { $host->prepare('brfixture', 'ensfixture'); 1 },
   'authentication settings still require manual conversion');
like($@, qr/authentication/, 'unsupported connection has an explicit error');
done_testing();
