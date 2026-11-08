use strict;
use warnings;
no warnings 'once';
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";
use CloudminTest;
use Test::More;
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);
use POSIX ();
use Scalar::Util qw(weaken);
use Cloudmin::Libvirt;
require "$Bin/../cloudmin-console-lib.pl";
our (%text, %config);
open(my $lang, '<', "$Bin/../lang/en") or die $!;
while (<$lang>) { chomp; $text{$1} = $2 if (/^([^=]+)=(.*)$/); }
my $readonly = 0;
my $xterm = 1;
{
	no warnings 'redefine';
	# is_readonly_mode() supplies the caller's current fixture permission.
	*is_readonly_mode = sub { $readonly };
	# foreign_check(module) reports whether Webmin's Terminal
	# module is installed.
	*foreign_check = sub { $_[0] eq 'xterm' ? $xterm : 0 };
	}
$config{'libvirt_uri'} = 'qemu:///system';
my $uuid = '11111111-2222-3333-4444-555555555555';
my $vm = { uuid => $uuid, active => 1, graphics => { type => 'vnc' } };
ok(eval { check_console($vm); 1 }, 'local active VNC guest is allowed');
for my $change ( { active => 0 }, { graphics => undef },
		 { graphics => { type => 'spice' } } ) {
	ok(!eval { check_console({ %$vm, %$change }); 1 },
	   'unsupported console is rejected');
	}
$xterm = 0;
ok(!eval { check_console($vm); 1 },
   'console needs the Terminal module for proxy checks');
like($@, qr/Terminal module/, 'missing Terminal module is explained');
$xterm = 1;
{
	local $config{'libvirt_uri'} = 'qemu+ssh://remote/system';
	ok(!eval { check_console($vm); 1 },
	   'remote guests cannot open a local console');
	}
$readonly = 1;
ok(!eval { check_console($vm); 1 }, 'read-only users cannot send guest input');
$readonly = 0;

# Serial uses the existing console gate, including headless
# guests and bad modes.
my $serial_vm =
	{ %$vm, graphics => undef, serial_console => { alias => 'serial0' } };
ok(eval { check_console($serial_vm, 'serial'); 1 },
   'headless serial guest is allowed');
ok(!eval { check_console($vm, 'serial'); 1 },
   'missing serial device is rejected');
like($@, qr/no supported serial console/, 'missing serial device is explained');
for my $mode ( 'Serial', 'ssh', 'serial;id' ) {
	ok(!eval { check_console($serial_vm, $mode); 1 },
	   'unknown console mode is rejected');
	}
# Serial input needs the same write permission and local connection as VNC.
$readonly = 1;
ok(!eval { check_console($serial_vm, 'serial'); 1 },
   'read-only users cannot open serial');
$readonly = 0;
{
	local $config{'libvirt_uri'} = 'qemu+ssh://remote/system';
	ok(!eval { check_console($serial_vm, 'serial'); 1 },
	   'serial also requires local libvirt');
	}

{
	package ConsoleDomain;

	# new(class, fields) supplies the domain's active state and devices.
	sub new
	{
	bless $_[1], $_[0]
	}

	# get_uuid_string(self) returns the fixture's UUID.
	sub get_uuid_string
	{
	$_[0]->{'uuid'}
	}

	# get_name(self) supplies a name that must not be
	# accepted as a console ID.
	sub get_name
	{
	'fixture'
	}

	# is_active(self) supplies the current power state.
	sub is_active
	{
	$_[0]->{'active'}
	}

	# get_xml_description(self, flags) Returns the fixture's graphics and
	# serial device definitions.
	sub get_xml_description
	{
	$_[0]->{'xml'}
	}

	# open_graphics_fd(self, index, flags) records authorization
	# and returns a socket.
	sub open_graphics_fd
	{
	my ($self, @args) = @_;
	$self->{'args'} = \@args;
	return POSIX::dup(fileno($self->{'socket'}));
	}

	# open_console(self, stream, device, flags) records safe console
	# attachment. A busy fixture rejects a second client so failure
	# cleanup can be checked.
	sub open_console
	{
	$_[0]->{'serial_args'} =
		[ @_[1 .. 3] ]; die "Port busy\n" if $_[0]->{'busy'};
	}
	package ConsoleConnection;

	# list_all_domains(self, flags) supplies the available domains.
	sub list_all_domains
	{
	$_[0]->{'domain'}
	}

	# new_stream(self, flags) records the flags and
	# supplies a fixture stream.
	sub new_stream
	{
	$_[0]->{'stream_flags'} = $_[1]; return bless { },
						'ConsoleStream';
	}
	package ConsoleStream;

	# abort(self) records release after failed attachment.
	sub abort
	{
	$_[0]->{'aborted'}++;
	}
	}
socketpair(my $socket, my $peer, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die $!;
my $domain = ConsoleDomain->new({ uuid => $uuid, active => 1, socket => $socket,
				  xml =>
					  '<domain><devices><graphics type="spice"/><graphics type="vnc"/></devices></domain>' });
# factory() supplies a libvirt connection containing only the fixture domain.
my $factory = sub { bless { domain => $domain }, 'ConsoleConnection' };
my $adapter = Cloudmin::Libvirt->new(readonly => 0,
				     connection_factory => $factory);
my $console = $adapter->open_console($uuid);
is_deeply($domain->{'args'}, [ 1, 1 ],
	  'selects the VNC device and authorizes only the returned connection');
syswrite($peer, 'RFB');
sysread($console, my $data, 3);
is($data, 'RFB', 'returned console handle carries the guest stream');
close($console);
for my $id ( 'fixture', '../guest', $uuid.';id',
	     'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' ) {
	ok(!eval { $adapter->open_console($id); 1 },
	   'invalid or missing UUID is rejected');
	}
for my $opts ( { readonly => 1 }, { uri => 'qemu+ssh://remote/system' } ) {
	my $other = Cloudmin::Libvirt->new(readonly => 0,
					   connection_factory => $factory,
					   %$opts);
	ok(!eval { $other->open_console($uuid); 1 },
	   'adapter enforces local write access');
	}
$domain->{'active'} = 0;
ok(!eval { $adapter->open_console($uuid); 1 },
   'power state is checked again at connection time');
$domain->{'active'} = 1;
$domain->{'xml'} = '<domain><devices/></domain>';
ok(!eval { $adapter->open_console($uuid); 1 }, 'headless guest is rejected');

# Select libvirt's default console, never an arbitrary host
# device or agent channel.
for my $xml ( '<domain><devices/></domain>',
	      '<domain><devices><channel type="pty"/></devices></domain>',
	      '<domain><devices><console type="file"/></devices></domain>' ) {
	ok(!Cloudmin::Libvirt::extract_serial_console($xml),
	   'unsupported serial backend stays unavailable');
	}
# Request a nonblocking stream without forcing other clients off the port.
$domain->{'xml'} =
	'<domain><devices><console type="pty"><alias name="serial0"/></console></devices></domain>';
my $stream = $adapter->open_serial_console($uuid);
is_deeply($domain->{'serial_args'}, [ $stream, 'serial0', 2 ],
	  'opens the authorized console with SAFE, never FORCE');
is($adapter->connect()->{'stream_flags'}, 1, 'serial stream is nonblocking');
# Direct adapter callers must satisfy the same identity and access constraints.
for my $id ( 'fixture', '../guest', $uuid.';id' ) {
	ok(!eval { $adapter->open_serial_console($id); 1 },
	   'serial rejects names and invalid UUIDs');
	}
for my $opts ( { readonly => 1 }, { uri => 'qemu+ssh://remote/system' } ) {
	my $other =
		Cloudmin::Libvirt->new(readonly => 0, connection_factory =>
							      $factory, %$opts);
	ok(!eval { $other->open_serial_console($uuid); 1 },
	   'serial adapter requires local write access');
	}
# An occupied port must release the failed stream without taking over the port.
$domain->{'busy'} = 1;
ok(!eval { $adapter->open_serial_console($uuid); 1 },
   'busy console is not stolen');
ok($domain->{'serial_args'}->[0]->{'aborted'},
   'failed attachment aborts the stream');
delete $domain->{'busy'};
# A guest can stop between page rendering and the connection request.
$domain->{'active'} = 0;
ok(!eval { $adapter->open_serial_console($uuid); 1 },
   'serial rechecks the current power state');
$domain->{'active'} = 1;

# Exercise the actual setup script: its management adapter must be released
# before the supervisor starts, while the authorized display socket still works.
{
	no warnings qw(redefine once);
	local $INC{'./server-manager-lib.pl'} = 1;
	local $INC{'./cloudmin-console-lib.pl'} = 1;
	local $INC{'./cloudmin-relay-lib.pl'} = 1;
	local $main::session_id = 'fixture-session';
	local $domain->{'xml'} =
		'<domain><devices><graphics type="vnc"/></devices></domain>';
	# get_domain(self, uuid) supplies the previously
	# validated fixture record.
	local *Cloudmin::Libvirt::get_domain = sub { $vm };
	my $setup_adapter;
	# get_libvirt([fresh]) tracks adapter lifetime
	# without retaining it here.
	local *main::get_libvirt = sub {
		my $new = Cloudmin::Libvirt->new(readonly => 0,
						 connection_factory => $factory);
		$setup_adapter = $new;
		weaken($setup_adapter);
		return $new;
		};
	# generate_miniserv_websocket_token() supplies a valid,
	# deterministic unit ID.
	local *main::generate_miniserv_websocket_token = sub { 'a' x 32 };
	# run_interactive_relay(port, unit, command, graphics)
	# checks setup, then stops.
	local *main::run_interactive_relay = sub {
		ok(!defined($setup_adapter),
		   'supervisor does not retain the libvirt adapter');
		syswrite($peer, 'RFB');
		sysread($_[3], my $greeting, 3);
		is($greeting, 'RFB',
		   'display stream survives release of the adapter');
		die "Setup verified\n";
		};
	local @ARGV = ( 555, $uuid );
	do "$Bin/../console-server.pl";
	like($@, qr/Setup verified/, 'console setup reached the supervisor');
	}

# Log creation happens after route allocation; failure must release the port.
require "$Bin/../cloudmin-terminal-lib.pl";
{
	no warnings qw(redefine once);
	local $INC{'Net/WebSocket/Server.pm'} = 1;
	local $main::session_id = 'fixture-session';
	local $main::module_name = 'server-manager';
	local $main::module_config_directory = '/unused-fixture';
	local $main::module_var_directory = '/unused-fixture';
	my @login_states;
	# save_terminal_login(uuid, attempt, state, [request])
	# records preference writes.
	local *main::save_terminal_login = sub { push(@login_states, $_[2]); };
	# create_wrapper(path, module, script) avoids writing a
	# real Webmin wrapper.
	local *main::create_wrapper = sub { };
	# has_command(path) reports availability without launching Linux tools.
	local *main::has_command = sub { $_[0] };
	# generate_miniserv_websocket_token() supplies a
	# deterministic fixture ID.
	local *main::generate_miniserv_websocket_token = sub { 'a' x 32 };
	# allocate_miniserv_websocket(module) reserves only a
	# fixture port number.
	local *main::allocate_miniserv_websocket = sub { 555 };
	my @removed;
	# remove_miniserv_websocket(port, module) records the requested cleanup.
	local *main::remove_miniserv_websocket = sub { push(@removed,
							    [ @_ ]); };
	# write_file_contents(path, contents) simulates a full or
	# unwritable log disk.
	local *main::write_file_contents =
		sub { die "Cannot write session log\n"; };
	# system_logged(command) must never run after the log write fails.
	local *main::system_logged =
		sub { die "Backend must not start without its log\n"; };
	for my $kind ( 'console', 'terminal' ) {
		@removed = ();
		@login_states = ();
		eval { $kind eq 'console'
			? start_console($vm)
			: start_terminal({ }); };
		like($@, qr/Cannot write session log/,
		     "$kind reports the log failure");
		is_deeply(\@removed, [ [ 555, 'server-manager' ] ],
			  "$kind releases the unused route");
		is_deeply(\@login_states, [ 'pending', 'failed' ],
			  'failed terminal startup pauses automatic connection')
			if ($kind eq 'terminal');
		# Missing prerequisites fail before any
		# proxy route is allocated.
		for my $missing ( '/usr/bin/systemd-run', '/usr/bin/python3',
				  ($kind eq 'terminal' ? '/usr/bin/ssh' : ()) ) {
			# has_command(path) makes exactly one
			# prerequisite unavailable.
			local *main::has_command =
				sub { $_[0] eq $missing ? undef : $_[0] };
			# allocate_miniserv_websocket(module) detects
			# premature allocation.
			local *main::allocate_miniserv_websocket =
				sub {
					die "Route allocated without required tools\n"; };
			eval { $kind eq 'console'
				? start_console($vm)
				: start_terminal({ }); };
			like($@, qr/require systemd/,
			     "$kind rejects missing $missing");
			}
		}
	}
done_testing();
