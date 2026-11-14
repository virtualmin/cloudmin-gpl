#!/usr/bin/perl
# Check on a disposable Cloudmin host that a disk image is copied only in the
# format its import checked. Libvirt detects a file's format from its first
# bytes and copies the disk as root in that format. A file imported as raw can
# start with a QCOW2 header that names a root-only host file as its backing
# file, so such an image must never be imported or copied.
use strict;
use FindBin;
use Cwd qw(abs_path);
my $webmin_root;
use warnings;
use File::Temp qw(tempdir);

# Load the installed module only inside a root Linux test session.
BEGIN
{
$webmin_root = abs_path("$FindBin::Bin/../../..");
# The test creates libvirt volumes and a root-only host file.
die "Run only on a disposable Linux VM as root\n"
	unless $^O eq 'linux' && $< == 0;
# Use the service's configuration and module paths.
$ENV{'WEBMIN_CONFIG'} = '/etc/webmin';
$ENV{'WEBMIN_VAR'} = '/var/webmin';
$ENV{'REMOTE_USER'} = 'root';
chdir("$webmin_root/server-manager") || die $!;
$0 = "$webmin_root/server-manager/check-image-format.pl";
}
use lib "$FindBin::Bin/../../..";
require './server-manager-lib.pl';
$| = 1;

my ($jobs, $adapter, $pool, $work, $canary, @imports, @clones);

# Attempt fixture cleanup after success or failure, keeping the test status.
END
{
my $status = $?;
# Remove copies before their source images; refused copies may not exist.
foreach my $name (@clones) {
	my (undef, $volume) = eval { $adapter->volume($pool->{'id'}, $name) };
	# Skip a missing volume after refusal or an incomplete setup.
	eval { $volume->delete(0) } if ($volume);
	}
# Image removal also cleans its stored volume and import files.
foreach my $id (@imports) {
	eval { $jobs->remove($id); 1 } || warn "Image $id was not removed: $@";
	}
# Early setup failures may leave these paths unset.
unlink($canary) if ($canary);
# Temporary input files are independent of imported volumes.
system('rm', '-rf', '--', $work) if ($work);
$? = $status;
}

# qemu_img(arguments...) builds one fixture disk.
sub qemu_img
{
system('qemu-img', @_) == 0 || die "qemu-img @_ failed\n";
}

# import_image(path, format) Imports a host file and waits up to 180 polls for
# a ready or failed job. Records the job ID for cleanup before waiting.
sub import_image
{
my ($path, $format) = @_;
my $records = start_image_imports({ install_type => 'local', path => $path,
				    format => $format, pool => $pool->{'id'},
				    token => $jobs->form_token('root') });
my $id = $records->[0]->{'id'};
push(@imports, $id);
# Wait for the asynchronous worker so callers can inspect its final result.
foreach my $second (1 .. 180) {
	my $job = $jobs->get($id);
	# Both outcomes are terminal; callers check which one was expected.
	return $job if ($job->{'state'} =~ /\A(?:ready|failed)\z/);
	sleep(1);
	}
die "Import of $path did not finish\n";
}

# clone_image(job) Copies a completed import using VM creation's source fields
# and returns the new disk. Records the output name before allocation.
sub clone_image
{
my ($job) = @_;
my $name = "cloudmin-format-check-$$-".scalar(@clones).'.qcow2';
push(@clones, $name);
my $source = { map { $_ => $job->{$_} }
	       qw(id name pool volume volume_key volume_path format
		  virtual_size) };
return $adapter->clone_disk($pool->{'id'}, $name, $source, 1024**3, 'qcow2',
			    sub { });
}

# canary_lines(path, marker) counts marker occurrences in a copied disk.
sub canary_lines
{
my ($path, $marker) = @_;
open(my $fh, '<', $path) || die "$path: $!\n";
binmode($fh);
my $data = do { local $/; <$fh> };
close($fh);
my $count = () = $data =~ /\Q$marker\E/g;
return $count;
}

# Use an available file pool and a separate directory for fixture inputs.
$jobs = get_image_jobs();
$adapter = get_libvirt(1);
($pool) = @{get_images_info()->{'pools'} || [ ]};
# Continuing without a pool would not exercise libvirt's file handling.
die "No file storage pool is available\n" if (!$pool);
$work = tempdir('cloudmin-format-check-XXXXXX', DIR => '/var/tmp');

# A root-only host file stands in for any file an image must never reach.
my $marker = "CLOUDMIN-FORMAT-CANARY-$$-".time();
$canary = "/root/cloudmin-format-check-$$.txt";
open(my $fh, '>', $canary) || die "$canary: $!\n";
chmod(0600, $canary) || die $!;
print $fh ("$marker\n" x 4096);
close($fh) || die $!;

# The crafted file is a real QCOW2 overlay on the canary. The other two are
# ordinary empty disks. The unprivileged import worker must be able to read
# all of them.
qemu_img('create', '-q', '-f', 'qcow2', '-F', 'raw', '-b', $canary,
	 "$work/crafted.img", '16M');
qemu_img('create', '-q', '-f', 'raw', "$work/plain.img", '16M');
qemu_img('create', '-q', '-f', 'qcow2', "$work/plain.qcow2", '16M');
chmod(0755, $work) || die $!;
chmod(0644, glob("$work/*")) || die $!;

# Importing the crafted file as raw fails, and its volume is removed.
my $crafted = import_image("$work/crafted.img", 'raw');
die "A raw import that starts with a QCOW2 header was accepted\n"
	if ($crafted->{'state'} eq 'ready');
# An unrelated import error does not prove the format check worked.
die "Unexpected import failure: $crafted->{'error'}\n"
	if ($crafted->{'error'} !~ /detected as qcow2/);
my (undef, $left) = $adapter->volume($pool->{'id'}, $crafted->{'volume'});
# Rejection must also remove the volume allocated before upload.
die "The refused import left its volume behind\n" if ($left);
print "A raw import that starts with a QCOW2 header is refused and removed\n";

# Ordinary raw and QCOW2 disks still import and copy.
my $raw;
foreach my $case ([ 'plain.img', 'raw' ], [ 'plain.qcow2', 'qcow2' ]) {
	my ($file, $format) = @$case;
	my $job = import_image("$work/$file", $format);
	# Ordinary inputs must reach the ready state before copying.
	die "An ordinary $format image was not imported: $job->{'error'}\n"
		if ($job->{'state'} ne 'ready');
	my $disk = clone_image($job);
	# A successful copy must leave a nonempty disk file.
	die "An ordinary $format image was not copied\n"
		if (!$disk || !-s $disk->{'path'});
	print "An ordinary $format image is imported and copied\n";
	# Retain the raw import for the stored-image attack below.
	$raw = $job if ($format eq 'raw');
	}

# Model an image imported before the format check was added by writing the
# crafted header onto the stored raw image.
open(my $in, '<', "$work/crafted.img") || die $!;
binmode($in);
my $bytes = do { local $/; <$in> };
close($in);
# Preserve the imported file's identity while replacing its first bytes.
open(my $out, '+<', $raw->{'volume_path'}) || die "$raw->{'volume_path'}: $!\n";
binmode($out);
print $out $bytes;
close($out) || die $!;

# Copying it as VM creation does is refused before anything is allocated.
my $disk = eval { clone_image($raw) };
die "A raw image that starts with a QCOW2 header was copied, with ".
    canary_lines($disk->{'path'}, $marker)." of 4096 lines of a root-only ".
    "host file\n"
	if ($disk);
# Distinguish the intended format refusal from unrelated copy failures.
die "Unexpected copy failure: $@" if ($@ !~ /detected as qcow2/);
(undef, $left) = $adapter->volume($pool->{'id'}, $clones[-1]);
# The format check must run before destination allocation.
die "The refused copy left a volume behind\n" if ($left);
print "A stored raw image that starts with a QCOW2 header is not copied\n";

# Adding it to an existing virtual machine as a new disk is refused too.
my $accepted = eval { get_vm_manager()->clone_source($adapter,
						     $raw->{'id'}); 1 };
die "The crafted image was accepted as a source for a new disk\n"
	if ($accepted);
# This path must refuse the format mismatch too, not fail for another reason.
die "Unexpected new disk failure: $@" if ($@ !~ /detected as qcow2/);
print "The same image is refused as a source for a new disk\n";
print "Image format checks passed\n";
