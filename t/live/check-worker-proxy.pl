#!/usr/bin/perl
# Exercise Webmin's proxy settings through actual unprivileged download workers.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../..";
use IO::Socket::INET;
use MIME::Base64 qw(encode_base64);
use Test::More;
use POSIX ();
die "Disposable Linux guest as root only\n" if $^O ne 'linux' || $< != 0;
require "$Bin/../../lib/Cloudmin/Worker.pm";
$| = 1;

foreach my $task (qw(image size)) {
	my $listener = IO::Socket::INET->new(LocalAddr => '127.0.0.1',
					     LocalPort => 0, Listen => 1,
					     Proto => 'tcp') || die $!;
	my $port = $listener->sockport();
	my $pid = fork();
	die $! if !defined($pid);
	if (!$pid) {
		# A local proxy verifies CONNECT and authentication, then
		# rejects the request so this fixture needs neither Internet
		# access nor a trusted CA.
		alarm(45);
		my $client = $listener->accept() || POSIX::_exit(2);
		my $headers = '';
		while (my $line = <$client>) {
			last if $line =~ /^\r?\n$/;
			$headers .= $line;
			}
		my $auth = encode_base64('fixture-user:fixture-password', '');
		my $ok = $headers =~ m{^CONNECT 192\.0\.2\.123:443 HTTP/1.0} &&
			 $headers =~ /Proxy-Authorization: Basic \Q$auth\E/i;
		print $client "HTTP/1.0 403 Fixture proxy denied\r\nContent-Length: 0\r\n\r\n";
		close($client);
		POSIX::_exit($ok ? 0 : 3);
		}
	close($listener);
	no warnings 'once';
	local %WebminCore::gconfig = ( http_proxy => "http://127.0.0.1:$port",
				       proxy_user => 'fixture-user',
				       proxy_pass => 'fixture-password',
				       proxy_fallback => 0 );
	my $id;
	my $ok = eval { Cloudmin::Worker->new()->run($task,
						     { url => 'https://192.0.2.123/disk', format => 'raw',
						       limit => 1048576 },
						     started => sub { $id = $_[0] }); 1 };
	my $error = $@;
	waitpid($pid, 0);
	is($?, 0, "$task worker reached the proxy with authentication");
	ok(!$ok, "$task preserves the proxy refusal");
	like($error, qr/403|proxy/i, "$task reports a proxy failure");
	unlike($error, qr/fixture-password/,
	       "$task does not expose proxy credentials");
	ok($id && !-e "/var/lib/private/cloudmin-workers/$id",
	   "$task removes its private proxy configuration after failure");
	}
done_testing();
