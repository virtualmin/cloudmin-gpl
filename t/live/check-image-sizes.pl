#!/usr/bin/perl
# Run on a disposable VM to exercise Webmin's HTTP adapter and HTTPS size
# probes.
use strict;
use FindBin;
use Cwd qw(abs_path);
my $webmin_root;
use warnings;
use Test::More;
BEGIN {
	$webmin_root = abs_path("$FindBin::Bin/../../..");
	die "Disposable Linux VM only\n" unless $^O eq 'linux' && $< == 0;
	$ENV{'WEBMIN_CONFIG'} = '/etc/webmin';
	$ENV{'WEBMIN_VAR'} = '/var/webmin';
	$ENV{'REMOTE_USER'} = 'root';
	chdir("$webmin_root/server-manager") or die $!;
	$0 = "$webmin_root/server-manager/check-image-sizes.pl";
	}
use lib "$FindBin::Bin/../../..";
require './server-manager-lib.pl';
require './lib/Cloudmin/HTTP.pm';

# probe(responses...) feeds raw HTTP headers through the production parser.
sub probe
{
my (@responses) = @_;
my (@methods, @urls);
my $closed = 0;
no warnings 'redefine';
# make_http_connection(args...) records request methods and feeds raw headers.
local *Cloudmin::HTTP::make_http_connection = sub {
	push(@methods, $_[3]); push(@urls, $_[0].$_[4]);
	die "Missing fixture response\n" if !@responses;
	return { lines => [ shift(@responses) =~ /.*?\n/g ] };
	};
# read_http_connection(connection) supplies the next header line to the parser.
local *Cloudmin::HTTP::read_http_connection =
	sub { shift(@{$_[0]->{'lines'}}) };
# close_http_connection(connection) counts cleanup after every probe attempt.
local *Cloudmin::HTTP::close_http_connection = sub { $closed++ };
my $bytes = eval { Cloudmin::HTTP::probe('https://images.example.test/cloud/disk.qcow2') };
return ($bytes, \@methods, $closed, "$@", \@urls);
}

# Prefer HEAD; fall back to a range request without mistaking its length for
# total.
my ($bytes, $methods, $closed, $error,
	$urls) = probe("HTTP/1.1 200 OK\r\nContent-Length: 123456\r\n\r\n");
is($bytes, 123456, 'HEAD reads the file size without reading its body');
is_deeply($methods, ['HEAD'], 'normal publisher needs only one HEAD');
is($closed, 1, 'probe closes the connection');
($bytes,
	$methods) =
		probe("HTTP/1.1 405 Not Allowed\r\nContent-Length: 999\r\n\r\n",
	"HTTP/1.1 206 Partial Content\r\nContent-Length: 1\r\nContent-Range: bytes 0-0/654321\r\n\r\n");
is($bytes, 654321,
	'range fallback uses total length, not the one-byte response');
is_deeply($methods, ['HEAD', 'GET'], 'HEAD rejection triggers a range request');
($bytes) = probe("HTTP/1.1 200 OK\r\n\r\n",
	"HTTP/1.1 200 OK\r\nContent-Length: 777\r\n\r\n");
is($bytes, 777, 'server ignoring ranges still supplies the full file length');
# Redirect metadata must not become the reported image size.
($bytes, $methods, $closed, $error, $urls) = probe(
	"HTTP/1.1 302 Found\r\nLocation: ../current.qcow2\r\nContent-Length: 24\r\n\r\n",
	"HTTP/1.1 200 OK\r\nContent-Length: 888\r\n\r\n");
is($bytes, 888, 'redirect body length is never treated as the image size');
is($urls->[1], 'images.example.test/cloud/../current.qcow2',
	'relative redirects use the image directory');
($bytes, $methods, $closed,
	$error) = probe("HTTP/1.1 302 Found\r\nLocation: http://insecure.example.test/disk\r\n\r\n");
ok(!defined($bytes), 'HTTPS downgrade does not return a size');
like($error, qr/HTTPS/, 'HTTPS downgrade is rejected before connecting');
is(scalar(@$methods), 1, 'redirect target is not contacted');
# Failed responses and unknown range totals must leave the estimate unavailable.
for my $response (
	"HTTP/1.1 404 Not Found\r\nContent-Length: 123\r\n\r\n",
	"HTTP/1.1 503 Unavailable\r\nContent-Length: 123\r\n\r\n",
	"HTTP/1.1 206 Partial\r\nContent-Length: 1\r\nContent-Range: bytes 0-0/*\r\n\r\n",
) {
	($bytes) = probe($response);
	ok(!defined($bytes),
		'error bodies and unknown range totals cannot become estimates');
	}

# Make a real request through verified TLS without creating an import job.
my $entry = get_available_server_image('debian-13');
my $actual = probe_image_size($entry->{'url'});
ok(Cloudmin::ImageSizes::valid_bytes($actual),
	'official Debian image returns a size over verified HTTPS');
done_testing();
