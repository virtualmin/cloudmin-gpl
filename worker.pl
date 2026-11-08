#!/usr/bin/perl
# A systemd-launched worker loads code afresh without the controller's memory,
# file descriptors or libvirt connections. Only selected task settings and
# explicitly mounted files cross into its restricted environment.
use strict;
use warnings;
use FindBin qw($Bin);

BEGIN
{
# Reject a direct privileged launch before loading any worker libraries.
die "Image workers must run without root privileges\n"
	if ($< == 0 || $> == 0);
$ENV{'LIBROOT'} = "$FindBin::Bin/..";
unshift(@INC, $ENV{'LIBROOT'});
chdir($ENV{'LIBROOT'}) || die "Cannot load worker libraries\n";
}
use WebminCore qw(convert_to_json convert_from_json);
require "$Bin/lib/Cloudmin/WorkerTasks.pm";
$| = 1;
umask(0077);
# Webmin's download helpers report failures through error(), which would
# otherwise print an HTML page into the JSON event stream and exit.
{
	no warnings 'once';
	$main::error_must_die = 1;
	}
chdir($ENV{'STATE_DIRECTORY'} || '') ||
	die "Private worker directory is missing\n";

# emit(event) Writes one JSON event; the controller enforces stream
# and event size limits.

sub emit
{
print(convert_to_json($_[0], 0, 1), "\n") || die "Controller disconnected\n";
}

emit({ type => 'identity', uid => 0 + $<, euid => 0 + $> });
# Read a bounded request before dispatching any parser or external tool.
my $ok = eval {
	open(my $fh, '<', 'request.json') || die "Cannot read worker request\n";
	read($fh, my $json, 512 * 1024 + 1);
	# The extra byte distinguishes an oversized request
	# from an exact-size one.
	die "Worker request is too large\n" if (length($json) > 512 * 1024);
	my $request = convert_from_json($json);
	# Worker dispatch expects named fields, not an arbitrary JSON value.
	die "Invalid worker request\n" if (ref($request) ne 'HASH');
	# The SSH client starts in this same unprivileged sandbox.
	if (($request->{'task'} || '') eq 'software') {
		exec('/usr/bin/perl', "$Bin/software-worker.pl");
		die "Cannot start guest software worker\n";
		}
	my $result = Cloudmin::WorkerTasks::run($request, \&emit);
	emit({ type => 'result', data => $result });
	1;
	};
if (!$ok) {
	# Return a bounded diagnostic without serializing the request itself.
	my $error = substr($@ || 'Image worker failed', 0, 1500);
	$error =~ s/[\x00-\x08\x0b\x0c\x0e-\x1f]//g;
	emit({ type => 'error', message => $error });
	exit(1);
	}
