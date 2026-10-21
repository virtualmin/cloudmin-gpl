#!/usr/bin/perl
# Authorize one console and supervise its isolated browser relay.
use strict;
use warnings;
require './server-manager-lib.pl';
require './cloudmin-console-lib.pl';
require './cloudmin-relay-lib.pl';
our ($module_root_directory, $session_id);
our $error_must_die = 1;
my ($port, $uuid, $mode) = @ARGV;
# Recheck the wrapper's session and console grant before opening a guest device.
die "Console access requires a Webmin session\n" if (!$session_id);
die "Console access requires write permission\n" if (is_readonly_mode());
require_access('console', $uuid);
my $adapter = get_libvirt(1);
my $vm = $adapter->get_domain($uuid) || die "Virtual machine not found\n";
check_console($vm, $mode);
$mode = console_mode($mode);
# The service gets one guest byte socket, never a management connection or
# the guest's VNC password.
my $graphics;
if ($mode eq 'serial') {
	# Open the serial stream and its connection after the supervisor forks.
	# Libvirt streams cannot be passed as descriptors or shared across a fork.
	# transport() creates the stream and its byte-socket bridge in that process.
	$graphics = sub {
		require Sys::Virt::Event;
		require "$module_root_directory/lib/Cloudmin/SerialConsole.pm";
		# Register events before connecting so stream I/O uses this loop.
		Sys::Virt::Event::register_default();
		my $serial_adapter = get_libvirt(1);
		my $stream = $serial_adapter->open_serial_console($uuid);
		# Lock the port, then use one log cursor for history and live output.
		# This avoids skipped or repeated bytes at the transition.
		my $transport = eval { Cloudmin::SerialConsole->new($serial_adapter,
			$stream, $serial_adapter->serial_history($uuid)) };
		if (!$transport) {
			# Release the port if history setup fails.
			my $error = $@;
			eval { $stream->abort(); };
			die $error;
			}
		return $transport;
		};
	}
else {
	# VNC supplies a socket that remains usable after closing libvirt.
	$graphics = $adapter->open_console($uuid);
	}
# Release the setup connection before forking. Serial opens its own connection
# in the supervisor; VNC needs only the already-authorized display socket.
undef $adapter;
my $id = generate_miniserv_websocket_token();
# command(credential_path) builds the unit after its private session file exists.
run_interactive_relay($port, "cloudmin-console-$id", sub {
	# Keep the relay's startup deadline consistent with the opened device.
	build_console_command($id, $_[0], $mode);
	}, $graphics, sub {
	# authorized() rechecks this session's console grant throughout the relay.
	my $access = session_access($session_id);
	return $access && $access->{'policy'}->allows('console', $uuid);
	});
