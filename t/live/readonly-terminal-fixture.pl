#!/usr/bin/perl
# Start the real SSH supervisor with an in-memory guest inventory fixture. stdin
# supplies the test account, session, guest UUID and local SSH listener.
# Optional probe checks read-only startup. Optional startup_diagnostic tests
# event parsing. Guest discovery is stubbed; permissions, proxy, sandbox
# and SSH remain real.
use strict;
use warnings;
use FindBin qw($Bin);
use Cwd qw(abs_path);
use JSON::PP qw(decode_json encode_json);

die "Run on a Linux test host as root\n" if ($^O ne 'linux' || $< != 0);
my $input = decode_json(do { local $/; <STDIN> });
die "Invalid fixture identity\n" if (
	($input->{'user'} || '') !~ /\Acloudmin-terminal-check-[a-f0-9]{8}\z/ ||
	($input->{'uuid'} ||
	 '') !~ /\A[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}\z/ ||
	($input->{'session'} || '') !~ /\A\S{1,256}\z/ ||
	($input->{'address'} || '') !~ /\A\d{1,3}(?:\.\d{1,3}){3}\z/ ||
	($input->{'port'} || '') !~ /\A\d{1,5}\z/ ||
	$input->{'port'} < 1024 || $input->{'port'} > 65535);

# Load the same Webmin identity as a detached terminal controller.
my $module = abs_path("$Bin/../..");
$ENV{'WEBMIN_CONFIG'} = '/etc/webmin';
$ENV{'WEBMIN_VAR'} = '/var/webmin';
$ENV{'REMOTE_USER'} = $input->{'user'};
$ENV{'SESSION_ID'} = $input->{'session'};
$ENV{'HTTPS'} = 'ON';
chdir($module) or die $!;
$0 = "$module/terminal-server.pl";
unshift(@INC, "$module/..", $module);
require './server-manager-lib.pl';
our ($session_id, $remote_user, $error_must_die);
$error_must_die = 1;
die "Fixture session was not loaded\n" if (!$session_id ||
					   $session_id ne $input->{'session'} || $remote_user ne $input->{'user'});

# A local listener stands in for the guest SSH service; no guest login is made.
{
	no warnings qw(redefine once);
	# get_libvirt([write]) must never be reached by the
	# read-only startup probe.
	*main::get_libvirt = sub {
		die "Read-only supervisor reached guest lookup\n"
			if ($input->{'probe'});
		return bless { }, 'ReadonlyTerminalGuest';
		};
	}
package ReadonlyTerminalGuest;

# get_domain(self, uuid) exposes only this test's synthetic guest destination.
sub get_domain
{
die "Unexpected fixture VM\n" if ($_[1] ne $input->{'uuid'});
return { uuid => $input->{'uuid'}, state => 'running',
	 addresses => [ { address => $input->{'address'} } ] };
}
package main;

# Emit a startup diagnostic before readiness to test event boundaries.
if ($input->{'startup_diagnostic'}) {
	require './cloudmin-terminal-lib.pl';
	# Load status dependencies before overriding their terminal helpers.
	require './cloudmin-status-lib.pl';
	my $build = \&build_terminal_command;
	no warnings 'redefine';
	# build_terminal_command(request, id, user, credential)
	# keeps normal isolation.
	*build_terminal_command = sub {
		# Prefix the real launcher's diagnostics with a fixed line.
		return ( $^X, '-e',
			 'syswrite(STDERR, "Cloudmin fixture startup diagnostic\n"); '.
			 'exec @ARGV; die "Cannot start fixture relay: $!\n";',
			 '--', $build->(@_) );
		};
	}

# Read-only startup tests enter the real supervisor without allocating a route.
my $port = $input->{'probe'}
	? 65534
	: allocate_miniserv_websocket('server-manager');
my $id = generate_miniserv_websocket_token();
@ARGV = ( $port, $id, $input->{'uuid'}, 'cloudmin', $input->{'address'},
	  $input->{'port'}, 'password' );
if (!$input->{'probe'}) {
	# Record the same pending attempt that the real page launcher creates.
	require './cloudmin-terminal-lib.pl';
	save_terminal_login($input->{'uuid'}, $id, 'pending', {
		username => 'cloudmin', address => $input->{'address'},
		port => $input->{'port'}, auth => 'password' });
	# Return route data privately before redirecting
	# detached supervisor output.
	$| = 1;
	print encode_json({ port => $port, attempt => $id,
			    socket_url =>
				    get_miniserv_websocket_url($port,
							       '127.0.0.1:10000',
							       'server-manager') })."\n";
	my $log = "/var/webmin/modules/server-manager/terminal-$port.log";
	open(STDOUT, '>', $log) or die $!;
	chmod(0600, $log) or die $!;
	open(STDERR, '>&', \*STDOUT) or die $!;
	}
my $ok =
	eval { do './terminal-server.pl'; die($@ || $! ||
					      'Supervisor returned'); };
my $error = $@;
remove_miniserv_websocket($port, 'server-manager') if (!$input->{'probe'});
die $error;
