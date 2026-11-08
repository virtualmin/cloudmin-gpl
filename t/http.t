use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use Test::More;
require "$Bin/../lib/Cloudmin/Images.pm";
require "$Bin/../lib/Cloudmin/HTTP.pm";

# Redirects retain the origin unless an explicit new authority is supplied.
for my $case (
	[ 'disk.qcow2', 'https://images.example.test:8443/cloud/disk.qcow2' ],
	[ '../disk.qcow2',
	  'https://images.example.test:8443/cloud/../disk.qcow2' ],
	[ '/current/disk.qcow2',
	  'https://images.example.test:8443/current/disk.qcow2' ],
	[ '?download=1',
	  'https://images.example.test:8443/cloud/latest?download=1' ],
	[ '//mirror.example.test/disk.qcow2',
	  'https://mirror.example.test/disk.qcow2' ],
	[ 'https://mirror.example.test:9443/disk.qcow2',
	  'https://mirror.example.test:9443/disk.qcow2' ],
) {
	is(Cloudmin::HTTP::redirect($case->[0], 'images.example.test', 8443,
				    '/cloud/latest?old=1'),
	   $case->[1], "resolves $case->[0]");
	}
is(Cloudmin::HTTP::authority('2001:db8::1', 8443), '[2001:db8::1]:8443',
   'IPv6 host headers retain brackets and port');
is(Cloudmin::HTTP::authority('images.example.test', 443), 'images.example.test',
   'default HTTPS port can be omitted');
is(Cloudmin::HTTP::redirect('/disk.qcow2', '2001:db8::1', 443, '/old'),
   'https://[2001:db8::1]/disk.qcow2', 'IPv6 redirects remain valid URLs');
for my $location ( undef, '', 'http://mirror.example.test/disk',
		   'file:///etc/shadow',
		   '//user:password@mirror.example.test/disk',
		   "/disk\r\nInjected: header" ) {
	ok(!eval { Cloudmin::HTTP::redirect($location,
					    'images.example.test',
					    443, '/cloud/latest'); 1 },
	   'unsafe or missing redirect is rejected');
	}
done_testing();
