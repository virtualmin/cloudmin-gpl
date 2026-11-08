#!/usr/bin/perl
# Inspect a custom image through the same unprivileged worker used by the UI.
use strict;
use warnings;
use FindBin qw($Bin);
use JSON::PP qw(encode_json);
require "$Bin/lib/Cloudmin/Worker.pm";

# This helper needs the Linux hypervisor's systemd sandbox.
die "Run image inspection on the Linux hypervisor\n" if ($^O ne 'linux');
# Both the image path and format are required to launch inspection.
die "Expected image path and format\n" if (@ARGV != 2);
my $result = eval { Cloudmin::Worker->new()->run('inspect',
						 { format => $ARGV[1],
						   guest => 1 }, files =>
									 { image => $ARGV[0] }); };
if (!$result) {
	# Keep malformed guest data and unbounded library
	# diagnostics out of the UI.
	my $error = substr($@ || 'Cannot inspect this image', 0, 1000);
	$error =~ s/[\x00-\x08\x0b\x0c\x0e-\x1f]//g;
	print STDERR $error;
	exit(1);
	}
print encode_json($result), "\n";
