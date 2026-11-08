#!/usr/bin/perl
# Check worker startup and ordinary tools without requiring nested KVM.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
die "Disposable Linux VM as root only\n" if ($^O ne 'linux' || $< != 0);
require "$Bin/../../lib/Cloudmin/Worker.pm";
my $runner = Cloudmin::Worker->new();
my $tmp = tempdir('/tmp/cloudmin-platform-check-XXXXXX', CLEANUP => 1);

# ssh-keygen needs dynamic NSS lookup, unlike a Perl-only identity probe.
system('/usr/bin/ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f',
       "$tmp/identity") == 0 ||
	die "Cannot prepare fixture SSH key\n";
open(my $fh, '<', "$tmp/identity.pub") || die $!;
my $key = do { local $/; <$fh> }; close($fh);
my @ids;
# started(id) records each real unit so cleanup can be checked after the task.
my $started = sub { push(@ids, $_[0]); };
my $result = $runner->run('keys', { keys => $key }, started => $started);
is_deeply($result, { },
	  'OpenSSH validates a key under the dynamic systemd user');

# Exercise real DNS and the distribution's CA path inside the online worker.
$result = $runner->run(
	'size', {
		url =>
			'https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-arm64.qcow2',
	}, started => $started);
ok($result->{'bytes'} && $result->{'bytes'} > 1024**2,
   'worker resolves DNS and probes verified HTTPS');

# The debug host uses a self-signed Webmin certificate, which must be rejected.
my $ok = eval { $runner->run('size', { url => 'https://127.0.0.1:10000/' },
			     started => $started); 1 };
ok(!$ok, 'worker rejects the debug Webmin certificate');
like($@, qr/certificate/i, 'TLS validation failure is reported');
for my $id (@ids) {
	ok(!-e "/var/lib/private/cloudmin-workers/$id" &&
	   !-e "/var/lib/private/cloudmin-workers/$id.lease" &&
	   !-l "/var/lib/cloudmin-workers/$id",
	   'task leaves no files or public directory link');
	}
done_testing();
