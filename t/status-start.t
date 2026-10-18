use strict;
use warnings;
no warnings 'once';
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use WebminCore;
use File::Temp qw(tempdir);
use Test::More;

our $module_root_directory = "$Bin/..";
our $module_name = 'server-manager';
our $module_var_directory = tempdir(CLEANUP => 1);
our $module_config_directory = $module_var_directory;
our %config = (libvirt_uri => 'qemu:///system');
our $cloudmin_status_protocol;
require "$module_root_directory/cloudmin-status-lib.pl";

# Startup uses temporary files and mocked miniserv helpers, with no listener,
# child process, Webmin configuration or libvirt connection on the workstation.
local $INC{'Net/WebSocket/Server.pm'} = __FILE__;
local $INC{'Sys/Virt/Event.pm'} = __FILE__;
local $main::session_id = 'fixture-session';
local $main::readonly_mode_cache = 1;
my (%routes, $launches, $removals, $fail);
my $port = 12345;
my $route = "websockets_/$module_name/ws-$port";
no warnings 'redefine';
local *main::get_miniserv_config = sub { %{$_[0]} = %routes; };
local *main::get_miniserv_config_file = sub { "$module_var_directory/miniserv.conf" };
local *main::lock_file = sub { ok(!is_readonly_mode(), 'startup can lock miniserv'); };
local *main::unlock_file = sub { ok(!is_readonly_mode(), 'startup can unlock miniserv'); };
local *main::put_miniserv_config = sub {
	ok(!is_readonly_mode(), 'startup can save the shared route');
	%routes = %{$_[0]};
};
local *main::reload_miniserv = sub { ok(!is_readonly_mode(), 'startup can reload miniserv'); };
local *main::allocate_miniserv_websocket = sub {
	ok(!is_readonly_mode(), 'read-only viewer can allocate status route');
	$routes{$route} = "host=127.0.0.1 port=$port user=viewer token=fixture";
	return $port;
};
local *main::remove_miniserv_websocket = sub {
	ok(!is_readonly_mode(), 'failed startup can remove its route');
	delete($routes{$route});
	$removals++;
};
local *main::get_miniserv_websocket_url = sub { "wss://fixture/ws-$_[0]" };
local *main::create_wrapper = sub {
	ok(!is_readonly_mode(), 'startup can create the wrapper');
	write_file_contents($_[0], '# fixture');
	chmod(0700, $_[0]) or die $!;
};
local *main::system_logged = sub {
	ok(!is_readonly_mode(), 'Webmin does not silently veto collector launch');
	$launches++;
	return 1 if ($fail);
	write_file_contents("$module_var_directory/status-server.json",
		convert_to_json({port => $port, pid => $$,
			uri => $config{'libvirt_uri'}, protocol => $cloudmin_status_protocol}));
	return 0;
};
local *IO::Socket::IP::new = sub { return bless({}, 'FixtureListener'); };

is_deeply(start_status(), {socket_url => "wss://fixture/ws-$port"},
	'read-only viewer starts shared status');
ok(is_readonly_mode(), 'CGI remains read-only after startup');
unlike($routes{$route}, qr/user=/, 'route allows other authenticated viewers');
ok(-f "$module_var_directory/status-server.log", 'startup writes its private log');
start_status();
is($launches, 1, 'subsequent request reuses the existing collector');
ok(is_readonly_mode(), 'reuse preserves read-only permissions');

# A stale collector must be replaced, and failed replacement must unwind.
unlink("$module_var_directory/status-server.json") or die $!;
$fail = 1;
ok(!eval { start_status(); 1 }, 'failed collector launch reaches the caller');
like($@, qr/Cannot start status server/, 'startup failure is explicit');
ok(!$routes{$route} && $removals, 'failed launch leaves no proxy route');
ok(is_readonly_mode(), 'failure restores read-only permissions');

{
	local $main::session_id;
	my $before = $launches;
	ok(!eval { start_status(); 1 }, 'missing session cannot start the collector');
	is($launches, $before, 'session check precedes privileged bookkeeping');
	ok(is_readonly_mode(), 'unauthenticated refusal keeps caller permissions');
}
done_testing();
