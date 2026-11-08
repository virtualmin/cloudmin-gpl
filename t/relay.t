use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use Cloudmin::Relay;
use MIME::Base64 qw(encode_base64);
require "$Bin/../cloudmin-console-lib.pl";
require "$Bin/../cloudmin-relay-lib.pl";
our ($module_name, $module_root_directory);
$module_name = 'server-manager';
$module_root_directory = "$Bin/..";

# Only the session key rewritten by miniserv can authorize this relay.
ok(Cloudmin::Relay::authenticated(encode_base64('session-one'), 'session-one'),
   'accepts the authorized proxy session');
for my $key ( undef, '', 'session-one', encode_base64('session-two') ) {
	ok(!Cloudmin::Relay::authenticated($key, 'session-one'),
	   'rejects missing, raw and foreign session keys');
	}
ok(!Cloudmin::Relay::authenticated('', ''),
   'empty sessions cannot authenticate');

# Compare the real xterm helper in a source checkout or an installed Webmin.
# Configuration access is stubbed only in this test, never in a relay process.
subtest 'xterm handshake compatibility' => sub {
	my ($library) = grep { -f $_ }
			( "$Bin/../../webmin/xterm/xterm-lib.pl",
			  "$Bin/../../xterm/xterm-lib.pl" );
	# A source-only Cloudmin checkout cannot compare the real Webmin helper.
	plan skip_all => 'Webmin xterm sources are not available'
		if (!$library);
	{
		no warnings 'once';
		local $INC{'WebminCore.pm'} = 1;
		# import(package, [symbols...]) bypasses Webmin
		# initialization in this test.
		local *WebminCore::import = sub { };
		local @INC = @INC;
		package RelayXtermTest;

		# init_config() prevents test setup from
		# loading host configuration.

		sub init_config
		{
		}

		# get_module_acl() supplies no privileges to
		# this helper-only test.

		sub get_module_acl
		{
		return ();
		}
		require $library;
		}
	# Compare missing, encoded and whitespace-wrapped keys
	# for several sessions.
	for my $session ( undef, '', 'session-one', 'long-session' x 20 ) {
		my $valid = encode_base64($session || '');
		for my $key ( undef, '', ' ', 'wrong-key', $valid,
			      " \t$valid\r\n",
			      encode_base64('another-session') ) {
			is(Cloudmin::Relay::authenticated($key,
							  $session) ? 1 : 0,
			   RelayXtermTest::verify_websocket_key($key,
								$session)
									? 1
									: 0,
			   'relay and xterm agree on missing, wrapped and foreign keys');
			}
		}
	};

# A console service has no management group or capabilities, even on low-port
# Webmin installations; it receives a socket already bound by the controller.
my @command = build_console_command('a' x 32, '/private/session');
my $command = join(' ', @command);
like($command, qr/DynamicUser=yes/, 'console gets a non-root service identity');
like($command, qr/CapabilityBoundingSet= /, 'console has no capabilities');
unlike($command, qr/SupplementaryGroups|SESSION_ID=/,
       'no libvirt group or session secret in command arguments');
like($command, qr/LoadCredential=session:/, 'session uses private credentials');
like($command, qr/console-relay\.pl/, 'service starts a fresh relay program');
# The relay must receive the selected mode to choose its startup deadline.
is($command[-1], 'graphical', 'omitting the mode selects graphical');
my @serial = build_console_command('b' x 32, '/private/session', 'serial');
is($serial[-1], 'serial', 'serial mode reaches the isolated relay');
ok(!eval { build_console_command('a' x 32, '/private/session', 'unknown'); 1 },
   'unknown console modes cannot reach systemd');
for my $id ( '../bad', 'a' x 31, 'a' x 33 ) {
	ok(!eval { build_console_command($id, '/private/session'); 1 },
	   'unsafe unit IDs cannot reach systemd');
	}
done_testing();
