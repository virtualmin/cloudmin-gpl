use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use Test::More;
use File::Temp qw(tempdir);
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);
use WebminCore;
our (%text, %config, %in, $module_root_directory);
our $module_var_directory = tempdir(CLEANUP => 1);
$module_root_directory = "$Bin/..";
require "$module_root_directory/cloudmin-status-lib.pl";
open(my $lang, '<', "$module_root_directory/lang/en") or die $!;
while (<$lang>) { chomp; $text{$1} = $2 if (/^([^=]+)=(.*)$/); }

# Real reads distinguish an SSH banner from another TCP service or a silent
# peer.
for my $case (['SSH-2.0-Test\r\n', 1], ['Notice\r\nSSH-1.99-Test\r\n', 1],
	['HTTP/1.1 200 OK\r\n', 0], ['', 0]) {
	socketpair(my $reader, my $writer, AF_UNIX, SOCK_STREAM,
		PF_UNSPEC) or die $!;
	(my $banner = $case->[0]) =~ s/\\r\\n/\r\n/g;
	syswrite($writer, $banner) if (length($banner));
	close($writer) if (length($banner));
	no warnings qw(redefine once);
	local *IO::Socket::IP::new = sub {
		my ($class, %args) = @_;
		is($args{'PeerPort'}, 22, 'health check uses only SSH port 22');
		return $reader;
		};
	is(!!check_ssh_service(['192.0.2.1']), !!$case->[1],
		'only a valid SSH banner reports readiness');
	close($writer) if (!length($banner));
	}

{
	package StatusAdapter;
	# get_guest_status(self, uuid)
	# returns a fixture without opening libvirt.
	sub get_guest_status
	{
	$_[0]->{'calls'}++;
	return $_[0]->{'vm'};
	}
	}
my $uuid = '11111111-2222-3333-4444-555555555555';
my $vm = { state => 'running', active => 1, agent => 'responding',
	addresses => [{ address => '192.0.2.1' }, { address => '127.0.0.1' }],
	graphics => { type => 'vnc' }, serial_console => { alias => 'serial0' } };
my $adapter = bless { vm => $vm, calls => 0 }, 'StatusAdapter';
my (@probes, $readonly, $available);
my $probed_port;
$available = 1;
$config{'libvirt_uri'} = 'qemu:///system';
no warnings qw(redefine once);
local *main::get_libvirt = sub { $adapter };
local *main::foreign_check = sub { $available };
local *main::is_readonly_mode = sub { $readonly };
# check_ssh_service(addresses, [port]) records the requested probe destination.
local *main::check_ssh_service = sub {
	push(@probes, [@{$_[0]}]); $probed_port = $_[1]; return $_[0]->[0];
};

for my $id (undef, '', 'name', [], $uuid.';id') {
	ok(!eval { get_server_health($id); 1 }, 'invalid guest identity rejected');
	}
is($adapter->{'calls'}, 0, 'validation runs before libvirt or network access');
my $result = get_server_health($uuid);
is($result->{'ssh'}, 'responding', 'SSH readiness comes from a service probe');
is_deeply($probes[0], ['192.0.2.1'],
	'loopback addresses never reach the probe');
like($result->{'labels'}->{'ssh'}, qr/192\.0\.2\.1.*22/,
	'SSH status names the checked address and port');
# A saved port drives both the network probe and its public status labels.
save_terminal_port($uuid, 2222);
$result = get_server_health($uuid);
is($probed_port, 2222, 'health probe uses the saved port');
is($result->{'ssh_port'}, 2222, 'browser receives the probed port');
like($result->{'labels'}->{'ssh'}, qr/port 2222$/, 'status names the saved port');
{
	# check_ssh_service(addresses, [port]) simulates an unanswered probe.
	local *main::check_ssh_service = sub { undef };
	my $failed = get_server_health($uuid);
	is($failed->{'labels'}->{'ssh'}, 'Not responding on port 2222',
		'failed probe reports the port it actually checked');
	is(get_terminal_port($uuid), 2222, 'failed probe keeps the saved port');
}
ok($result->{'console_available'} && $result->{'terminal_available'},
	'available pages may reopen');
# Check device presence without opening the exclusive serial stream.
ok($result->{'serial_available'}, 'serial pages can reopen when the device is active');
unlike(join(' ', values(%{$result->{'labels'}})),
	qr/boot.*complete|setup.*complete/i,
	'agent and SSH replies do not imply completed guest setup');

for my $state (qw(shutoff paused crashed shutdown)) {
	local $vm->{'state'} = $state;
	local $vm->{'active'} = $state eq 'paused' ? 1 : 0;
	my $before = @probes;
	$result = get_server_health($uuid);
	is($result->{'ssh'}, 'inactive', "$state does not claim SSH is ready");
	is(scalar(@probes), $before, "$state skips network probes");
	ok(!$result->{'terminal_available'},
		"$state keeps the terminal warning");
	# Pausing execution leaves the serial device active.
	is($result->{'serial_available'}, $state eq 'paused' ? 1 : 0,
		"$state serial availability follows the active device");
	}
{
	local $vm->{'addresses'} = [];
	$result = get_server_health($uuid);
	is($result->{'ssh'}, 'no_address',
		'missing address is distinct from failed SSH');
	ok(!$result->{'terminal_available'},
		'no address keeps the terminal warning');
	# Hypervisor console access does not depend on the guest's networking.
	ok($result->{'serial_available'}, 'serial needs no guest network');
	}
{
	local $config{'libvirt_uri'} = 'qemu+ssh://remote/system';
	my $before = @probes;
	$result = get_server_health($uuid);
	is($result->{'ssh'}, 'remote',
		'remote hosts do not probe private addresses from the wrong machine');
	is(scalar(@probes), $before,
		'remote host causes no local network connection');
	ok(!$result->{'console_available'},
		'remote console remains unavailable');
	ok(!$result->{'serial_available'}, 'remote serial remains unavailable');
	}
for my $restricted ('readonly', 'missing') {
	$readonly = $restricted eq 'readonly';
	$available = $restricted ne 'missing';
	$result = get_server_health($uuid);
	ok(!$result->{'console_available'} && !$result->{'terminal_available'},
		"$restricted does not automatically open an unauthorized connection");
	ok(!$result->{'serial_available'}, "$restricted serial cannot reopen");
	}
# Stopped serial pages retain their mode without inventing a separate ACL grant.
{
	$readonly = 0;
	# can_access(action, uuid) grants only the shared console permission.
	local *main::can_access = sub { $_[0] eq 'console' };
	my $settings = convert_from_json(get_status_config({uuid => $uuid}, 'serial'));
	is($settings->{'reopen'}, 'serial', 'serial readiness has its own status key');
	like($settings->{'url'}, qr/remote_access\.cgi\?id=.*&tab=serial$/, 'reopen stays on the serial tab');
	ok(!$settings->{'readonly'}, 'serial reopen uses the console permission');
	}
# Every waiting connection reopens its own tab without losing SPA navigation.
{
	local $in{'xnavigation'} = 1;
	no warnings 'redefine';
	# can_access(action, uuid) allows each reconnect mode for URL checks.
	local *main::can_access = sub { 1 };
	for my $pair ([terminal => 'ssh'], [serial => 'serial'], [console => 'graphical']) {
		my $settings = convert_from_json(get_status_config({uuid => $uuid}, $pair->[0]));
		like($settings->{'url'}, qr/remote_access\.cgi\?id=.*&tab=$pair->[1]&xnavigation=1$/,
			"$pair->[0] reopens the selected tab in the theme");
		}
	}
done_testing();
