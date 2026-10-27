#!/usr/bin/perl
# check-image-catalogue.pl
# Checks every published asset through Cloudmin's Webmin downloader on the VM.
# Reads checksum files and disk headers only; does not create jobs or volumes.
use strict;
use FindBin;
use Cwd qw(abs_path);
my $webmin_root;
use warnings;

BEGIN {
	$webmin_root = abs_path("$FindBin::Bin/../../..");
	die "Run only on a disposable Linux VM as root\n"
		unless $^O eq 'linux' && $< == 0;
	$ENV{'WEBMIN_CONFIG'} = '/etc/webmin';
	$ENV{'WEBMIN_VAR'} = '/var/webmin';
	$ENV{'REMOTE_USER'} = 'root';
	chdir("$webmin_root/server-manager") || die $!;
	$0 = "$webmin_root/server-manager/check-image-catalogue.pl";
	}
use lib "$FindBin::Bin/../../..";
require './server-manager-lib.pl';
require './lib/Cloudmin/HTTP.pm';
$| = 1;

my %manifests;
my @failures;
# An unpublished manifest lets new assets be checked before enabling them.
die "Usage: $0 [manifest-path]\n" if (@ARGV > 1);
my $catalogue = @ARGV ? Cloudmin::ImageCatalog->new('path' => $ARGV[0])
	: get_image_catalogue();
my $images = $catalogue->list_images();
foreach my $image (@$images) {
	my $label = "$image->{id} $image->{architecture}";
	my $ok = eval {
		# Exercise the production parser against each vendor's actual
		# manifest.
		my $checksum_url = $image->{'checksum_url'};
		# Reuse each checksum manifest when several catalogue entries
		# share it.
		if (!exists($manifests{$checksum_url})) {
			my $manifest = '';
			Cloudmin::HTTP::download($checksum_url, \$manifest,
				sub {
				my ($mode, $bytes) = @_;
				die "Checksum exceeds 1 MiB\n"
				if ($mode == 3 && $bytes > 1024**2);
				});
			$manifests{$checksum_url} = $manifest;
			}
		my ($filename) = $image->{'url'} =~ m{/([^/]+)$};
		Cloudmin::Images::checksum($manifests{$checksum_url}, $filename,
			$image->{'checksum_algorithm'} || 'sha256');

		# Stop after the QCOW2 header, using the verified HTTPS and
		# redirect handling of a real download.
		my $header = '';
		my $complete = eval {
			Cloudmin::HTTP::download($image->{'url'}, \$header,
				sub {
				my ($mode, $bytes) = @_;
				die "Header complete\n"
				if ($mode == 3 && $bytes >= 104);
				});
			1;
			};
		die $@ if (!$complete && $@ ne "Header complete\n");
		die "Not a QCOW2 image\n"
			if (substr($header, 0, 4) ne "QFI\xfb");
		die "Image has a backing file\n"
			if (unpack('Q>', substr($header, 8, 8)));
		my $virtual_size = unpack('Q>', substr($header, 24, 8));
		die "Minimum disk is smaller than the image\n"
			if (!$virtual_size ||
			$virtual_size > $image->{'min_disk_bytes'});
		1;
		};
	# Report all failures in one run so a bad release cannot hide other
	# entries.
	if ($ok) {
		print "PASS $label: checksum entry and QCOW2 header\n";
		}
	# Collect failures so later entries are still checked.
	else {
		push(@failures, $label);
		print "FAIL $label: $@";
		}
	}
die scalar(@failures)." catalogue assets failed\n" if (@failures);
print scalar(@$images)." catalogue assets verified\n";
