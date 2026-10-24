#!/usr/bin/perl
# import-candidate.pl manifest-path image-id record-path Import an unpublished
# candidate through the production image worker. Save its job ID for
# check_machine_create.py and image-volume.pl cleanup, even on failure.
use strict;
use FindBin;
use Cwd qw(abs_path);
my $webmin_root;
use warnings;
BEGIN {
	$webmin_root = abs_path("$FindBin::Bin/../../..");
	die "Run on a disposable Linux VM as root\n" unless $^O eq 'linux' &&
		$< == 0;
	$ENV{'WEBMIN_CONFIG'} = '/etc/webmin';
	$ENV{'WEBMIN_VAR'} = '/var/webmin';
	$ENV{'REMOTE_USER'} = 'root';
	chdir("$webmin_root/server-manager") || die $!;
	$0 = "$webmin_root/server-manager/import-candidate.pl";
	}
use lib "$FindBin::Bin/../../..";
require './server-manager-lib.pl';
die "Usage: $0 manifest-path image-id record-path\n" unless @ARGV == 3;
my ($manifest, $id, $record) = @ARGV;
my $catalogue = Cloudmin::ImageCatalog->new(path => $manifest);
my $image = $catalogue->find_image($id, get_host_image_architecture())
	|| die "No candidate for host architecture\n";
my $data = get_images_info();
my ($pool) = grep { $_->{'name'} eq 'default' } @{$data->{'pools'}};
die "Default storage pool missing\n" unless $pool;

# Keep fixture ownership so the existing cleanup helper can remove the image.
my $request = { source => 'download', pool => $pool->{'id'},
	pool_name => $pool->{'name'}, slug => 'compat-'.$id,
	checksum_source => 'vendor', map { $_ => $image->{$_} }
	qw(name format url checksum_url checksum_algorithm architecture firmware
	cloud_init guest_agent min_disk_bytes) };
my $jobs = get_image_jobs();
my $owner = 'cloudmin-ui-check';
my $job = $jobs->create($owner, $jobs->form_token($owner), $request, $id);
Cloudmin::Images::write_private_file($record,
	convert_to_json({ id => $job->{'id'} }));

# A ready job has passed the complete vendor checksum and disk-format checks.
$jobs->run($job->{'id'});
$job = $jobs->get($job->{'id'});
die(($job->{'error'} || 'Image import did not finish')."\n")
	unless $job->{'state'} eq 'ready';
print convert_to_json({ map { $_ => $job->{$_} }
	qw(id name verified checksum_digest volume_path architecture) });
