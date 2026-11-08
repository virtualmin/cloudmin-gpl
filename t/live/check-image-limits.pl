#!/usr/bin/perl
# check-image-limits.pl
# Imports a 9 GiB fixture through real workers and libvirt on a debug host.
use strict;
use warnings;
use FindBin qw($Bin);
use Cwd qw(abs_path);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Test::More;
my $root;

BEGIN
{
die "Run only on an authorized Linux test host as root\n"
	unless $^O eq 'linux' && $< == 0;
$root = abs_path("$Bin/../../..");
$ENV{'WEBMIN_CONFIG'} = '/etc/webmin';
$ENV{'WEBMIN_VAR'} = '/var/webmin';
$ENV{'REMOTE_USER'} = 'root';
chdir("$root/server-manager") or die $!;
unshift(@INC, $root);
$0 = "$root/server-manager/check-image-limits.pl";
}
require './server-manager-lib.pl';
$| = 1;
my $gib = 1024**3;
my $size = 9 * $gib;
my $dir = tempdir('/var/tmp/cloudmin-image-limit-check-XXXXXX', CLEANUP => 1);
chmod(0755, $dir) or die $!;
plan skip_all =>
	'At least 24 GiB free space is required for this large import fixture'
	if (get_free_disk_space($dir) < 24 * $gib ||
	    Cloudmin::Worker::free_space('/var/lib') < 24 * $gib);
make_path("$dir/pool", { mode => 0755 });
make_path("$dir/jobs", { mode => 0700 });
my $jobs = get_image_jobs();
$jobs->{'directory'} = "$dir/jobs";
my $conn = get_libvirt(1)->connect();
my ($pool, @ids);
my $tail = "cloudmin-large-image-fixture\n";
my $ok = eval {
	# Keep the source sparse; the real copy and libvirt upload still cross
	# 8 GiB.
	open(my $source, '>', "$dir/source.raw") or die $!;
	binmode($source);
	seek($source, $size - length($tail), 0) or die $!;
	print { $source } $tail;
	close($source) or die $!;
	chmod(0644, "$dir/source.raw") or die $!;
	my $name = 'cloudmin-image-limit-check-'.(split('/', $dir))[-1];
	$pool =
		$conn->define_storage_pool(
			"<pool type='dir'><name>$name</name>".
			"<target><path>$dir/pool</path></target></pool>");
	$pool->create();
	my $request =
		{ source => 'local', format => 'raw', slug => 'large-limit',
		  name => 'Large import limit fixture',
		  path => "$dir/source.raw",
		  pool => $pool->get_uuid_string(), pool_name => $name };

	# A configured cap must stop native acquisition before
	# copying the payload.
	$jobs->{'max_bytes'} = 8 * $gib;
	my $blocked =
		$jobs->create('root', $jobs->form_token('root'), $request);
	push(@ids, $blocked->{'id'});
	$jobs->run($blocked->{'id'});
	is($jobs->get($blocked->{'id'})->{'state'}, 'failed',
	   'configured 8 GiB cap rejects a 9 GiB host file');
	like($jobs->get($blocked->{'id'})->{'error'}, qr/staging limit/,
	     'native worker explains the size rejection');

	# The default available-space mode must complete the
	# same import unchanged.
	$jobs->{'max_bytes'} = 0;
	my $job = $jobs->create('root', $jobs->form_token('root'), $request);
	push(@ids, $job->{'id'});
	$jobs->run($job->{'id'});
	$job = $jobs->get($job->{'id'});
	is($job->{'state'}, 'ready',
	   '9 GiB import completes with the available-space default');
	die "Large import failed: ".($job->{'error'} ||
				     'unknown error')."\n" if ($job->{'state'} ne 'ready');
	is($job->{'bytes'}, $size,
	   'job records all bytes beyond the old ceiling');
	is($job->{'virtual_size'}, $size,
	   'libvirt receives the complete raw disk capacity');
	my $volume = $pool->get_volume_by_name($job->{'volume'});
	is(-s $volume->get_path(), $size,
	   'destination file has the exact 9 GiB length');
	open(my $disk, '<', $volume->get_path()) or die $!;
	binmode($disk);
	seek($disk, $size - length($tail), 0) or die $!;
	read($disk, my $actual, length($tail)) == length($tail) or die $!;
	close($disk);
	is($actual, $tail,
	   'data beyond 8 GiB survives worker handoff and libvirt upload');
	is(-s "$dir/source.raw", $size, 'source file remains unchanged');

	# Inspection copies a large existing image through
	# its own bounded worker.
	my $info = Cloudmin::Worker->new()->run('inspect', { format => 'raw' },
						files => { image => $volume->get_path() });
	is($info->{'virtual-size'}, $size,
	   'existing images larger than 8 GiB can also be inspected');
	1;
	};
my $error = $@;
# Delete only this run's jobs and pool, even when an assertion or worker fails.
foreach my $id (@ids) {
	my $removed = eval { $jobs->remove($id) };
	ok($removed, 'fixture import and its volume are removed') or diag($@);
	}
# An early import failure may still leave the private test pool defined.
if ($pool) {
	my $removed =
		eval { $pool->destroy()
			if ($pool->is_active()); $pool->undefine(); 1 };
	ok($removed, 'fixture storage pool is removed') or diag($@);
	}
die $error if (!$ok);
done_testing();
