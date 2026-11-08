#!/usr/bin/perl
# Verify failed service startup releases its listener, credential and route.
use strict;
use warnings;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Digest::MD5 qw(md5_hex);
use Test::More;
use IO::Socket::INET;
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);
die "Run on a Linux test host as root\n" if ($^O ne 'linux' || $< != 0);
require "$Bin/../../cloudmin-console-lib.pl";
require "$Bin/../../cloudmin-relay-lib.pl";
our ($module_name, $module_root_directory, $module_var_directory,
     $session_id);
$module_name = 'server-manager';
$module_root_directory = "$Bin/../..";
$module_var_directory = tempdir('relay-check-XXXXXXXX',
				DIR => '/var/webmin', CLEANUP => 1);
$session_id = 'private-fixture-session';

# remove_miniserv_websocket(port, module) records supervisor cleanup without
# changing any real browser routes on the test host.

sub remove_miniserv_websocket
{
open(my $file, '>', "$module_var_directory/removed") || die $!;
print $file join(' ', @_);
close($file);
}

# Choose an unused loopback port without allocating a real miniserv route.
my $probe = IO::Socket::INET->new(Listen => 1, LocalAddr => '127.0.0.1',
				  LocalPort => 0, Proto => 'tcp') || die $!;
my $port = $probe->sockport();
close($probe);
my $id = md5_hex($$.time().rand());
my $unit = "cloudmin-console-$id";
socketpair(my $graphics, my $peer, AF_UNIX, SOCK_STREAM, PF_UNSPEC) || die $!;
my $owner = $$;
# Keep the real sandbox and descriptor handoff, but make Perl startup fail.
my $ok = eval {
	# command(credential_path) preserves isolation but
	# selects a missing script.
	run_interactive_relay($port, $unit, sub {
		my @command = build_console_command($id, $_[0]);
		# Replace the script path; keep the final mode argument intact.
		$command[-2] = "$module_var_directory/missing-relay.pl";
		return @command;
		}, $graphics);
	1;
	};
# Only the original caller checks results; the supervisor must exit on error.
if ($$ != $owner) {
	print STDERR $@;
	exit(1);
	}
ok(!$ok && $@ =~ /Cannot start isolated relay/,
   'failed relay startup returns an error instead of a connection URL');
ok(-f "$module_var_directory/removed", 'supervisor removes the proxy route');
# Readiness failure must leave neither private files nor a listening socket.
my @credentials = glob("$module_var_directory/relay-*");
is(scalar(@credentials), 0, 'failed startup removes its private credential');
$probe = IO::Socket::INET->new(Listen => 1, LocalAddr => '127.0.0.1',
			       LocalPort => $port, Proto => 'tcp');
ok($probe, 'failed startup releases the listening socket');
# Collected units may be absent; only a still-running service is a failure.
my $state = `/usr/bin/systemctl is-active $unit.service 2>/dev/null`;
unlike($state, qr/^(?:active|activating|deactivating)\s*$/,
       'failed startup leaves no active service');
done_testing();
