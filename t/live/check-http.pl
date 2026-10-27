#!/usr/bin/perl
# Exercise download redirects with Webmin's real response parser on a debug VM.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use Cwd qw(abs_path);
our $webmin_root;
BEGIN {
	$webmin_root = abs_path("$FindBin::Bin/../../..");
	die "Disposable Linux VM as root only\n" if ($^O ne 'linux' || $< != 0);
	$ENV{'LIBROOT'} = "$webmin_root";
	chdir($ENV{'LIBROOT'}) || die $!;
	}
use lib "$FindBin::Bin/../../..";
require "$Bin/../../lib/Cloudmin/Images.pm";
require "$Bin/../../lib/Cloudmin/HTTP.pm";

# download(url, responses...) feeds raw HTTP responses to the download parser.
sub download
{
my ($url, @responses) = @_;
my (@connections, $closed, $body);
$body = '';
no warnings qw(redefine once);
# make_http_connection(args...) records requests and feeds one raw response.
local *Cloudmin::HTTP::make_http_connection = sub {
	push(@connections, [ @_ ]);
	die "Missing fixture response\n" if (!@responses);
	return { lines => [ split(/(?<=\n)/, shift(@responses)) ] };
	};
# read_http_connection(connection) supplies lines to Webmin's actual parser.
local *WebminCore::read_http_connection =
	sub { return shift(@{$_[0]->{'lines'}}); };
# close_http_connection(connection) counts cleanup in both parser namespaces.
local *WebminCore::close_http_connection = sub { $closed++; };
local *Cloudmin::HTTP::close_http_connection = sub { $closed++; };
my $ok = eval { Cloudmin::HTTP::download($url, \$body, sub {}); 1 };
return ($ok, "$@", $body, \@connections, $closed);
}

# Relative, absolute-path and cross-host redirects must preserve verified HTTPS.
for my $case (
	[ 'disk.qcow2', 'images.example.test', 8443, '/cloud/disk.qcow2' ],
	[ '/disk.qcow2', 'images.example.test', 8443, '/disk.qcow2' ],
	[ '//mirror.example.test:9443/disk.qcow2', 'mirror.example.test', 9443,
	  '/disk.qcow2' ],
	[ '?download=1', 'images.example.test', 8443,
	  '/cloud/latest?download=1' ],
) {
	my ($ok, $error, $body, $calls,
		$closed) = download('https://images.example.test:8443/cloud/latest',
		"HTTP/1.1 302 Found\r\nLocation: $case->[0]\r\nContent-Length: 999\r\n\r\n",
		"HTTP/1.1 200 OK\r\nContent-Length: 7\r\n\r\npayload");
	ok($ok, "download follows $case->[0]") || diag($error);
	is($body, 'payload',
		'redirect response is never included in the image');
	is_deeply([ @{$calls->[1] || []}[0, 1, 4] ], [ @$case[1..3] ],
		'request reaches the correct host, port and path');
	is($closed, 2, 'both connections are closed');
	# Every hop must preserve the destination host, port and TLS
	# verification.
	for my $call (@$calls) {
		my %headers = map { @$_ } @{$call->[5]};
		is($headers{'Host'}, Cloudmin::HTTP::authority(@$call[0,1]),
			'Host header includes the custom port');
		ok($call->[2] && $call->[7]->{'capath'} && $call->[7]->{'host'}
			eq $call->[0],
			'TLS chain and hostname verification survive each redirect');
		}
	}
# Reject redirects that drop TLS, introduce credentials or omit a destination.
for my $location ('http://insecure.example.test/disk',
	'//user:pass@mirror.example.test/disk', '') {
	my ($ok, $error, $body,
		$calls) = download('https://images.example.test/cloud/latest',
		"HTTP/1.1 302 Found\r\nLocation: $location\r\n\r\n");
	ok(!$ok, 'unsafe or missing redirect fails');
	is(scalar(@$calls), 1, 'unsafe redirect target is never contacted');
	}
# Scheme matching is case-insensitive even when Webmin's URL parser is not.
my ($upper_ok, $upper_error, $upper_body,
	$upper_calls) = download('HTTPS://images.example.test/disk.raw',
	"HTTP/1.1 200 OK\r\nContent-Length: 7\r\n\r\npayload");
ok($upper_ok, 'uppercase HTTPS scheme is normalized before parsing') ||
	diag($upper_error);
is_deeply([ @{$upper_calls->[0] || []}[0, 1, 4] ],
	['images.example.test', 443, '/disk.raw'],
	'uppercase scheme reaches the intended endpoint');
# Error pages and unsolicited partial responses are not raw disk images.
for my $status ('400 Bad Request', '206 Partial Content') {
	my ($ok, $error,
		$body) = download('https://images.example.test/disk.raw',
		"HTTP/1.1 $status\r\nContent-Length: 7\r\n\r\npayload");
	ok(!$ok, "HTTP $status is rejected");
	is($body, '', 'rejected HTTP body is not written to the destination');
	}
done_testing();
