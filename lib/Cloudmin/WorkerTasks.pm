package Cloudmin::WorkerTasks;

# Disk parsers, network clients and provisioning tools run only in the worker.
use strict;
use warnings;
use File::Basename qw(dirname);
use Cwd qw(getcwd);
use WebminCore qw(convert_from_json read_file_contents);
use Digest::SHA ();
use IPC::Open3;
use IO::Select;
use Symbol qw(gensym);
use Fcntl qw(O_RDONLY O_NOFOLLOW O_NONBLOCK);
require(dirname(__FILE__).'/Images.pm');
require(dirname(__FILE__).'/ImageSizes.pm');
require(dirname(__FILE__).'/HTTP.pm');

# command(arguments...)
# Executes a fixed tool without a shell and bounds stdout and stderr in memory.
sub command
{
my @args = @_;
my ($input, $out, $err) = (gensym(), gensym(), gensym());
my $pid = open3($input, $out, $err, @args);
close($input);
my $select = IO::Select->new($out, $err);
my ($output, $error) = ('', '');
while ($select->count()) {
	for my $fh ($select->can_read()) {
		my $n = sysread($fh, my $data, 16384);
		# Pipe errors must not yield a partial response that
		# looks successful.
		die "Cannot read tool response\n" if (!defined($n));
		# Drain the other pipe after one stream reaches EOF.
		if (!$n) { $select->remove($fh); next; }
		if (fileno($fh) == fileno($out)) {
			# Tool stdout is returned to parsers and must fit in the
			# task limit.
			$output .= $data;
			# Parsed tool output is small; an unbounded
			# response is a task failure.
			die "Tool response is too large\n"
				if (length($output) > 1024 * 1024);
			}
		# Keep the diagnostic tail without allowing stderr to exhaust
		# memory.
		else { $error = substr($error.$data, -4096); }
		}
	}
waitpid($pid, 0);
# Include the bounded diagnostic tail only when the tool reports
# failure.
die "$args[0] failed: ".substr($error || 'no diagnostic output', 0, 1000)."\n"
	if ($?);
return $output;
}

# write_file(name, contents)
# Writes task data; callers supply fixed names in the private working directory.
sub write_file
{
my ($name, $contents) = @_;
open(my $fh, '>', $name) || die "Cannot prepare worker file\n";
binmode($fh);
print($fh $contents) && close($fh) || die "Cannot write worker file\n";
}

# disk_info(format, [path], [allow_backing])
# Rejects encrypted disks and, by default, backing links before further use.
# path defaults to the staged file named image; allow_backing defaults false.
# allow_backing is used only while relinking private, managed conversion layers.
sub disk_info
{
my ($format, $path, $allow_backing) = @_;
$path ||= 'image';
# An explicit format prevents automatic format probing of untrusted
# input.
die "Select QCOW2 or raw image format.\n"
	if (($format || '') !~ /\A(?:qcow2|raw)\z/);
my $output = command('/usr/bin/qemu-img', 'info', '--output=json', '-f',
	$format, $path);
my $info = convert_from_json($output);
# Ordinary imports must be self-contained. Managed conversion alone may retain
# backing links while replacing them; encryption and external data stay blocked.
die "Images with backing files, external data files or encryption cannot be imported.\n"
	if ((!$allow_backing && $info->{'backing-filename'}) || $info->{'encrypted'} ||
	$output =~ /"(?:data-file|encrypt)"\s*:/);
# Bound the virtual capacity separately from the smaller staged file
# size.
die "Invalid image size.\n"
	if (!$info->{'virtual-size'} || $info->{'virtual-size'} > 16 * 1024**4);
return { 'virtual-size' => 0 + $info->{'virtual-size'}, format => $format };
}

# free_space()
# Checks the actual worker filesystem, which can differ from Webmin's job store.
sub free_space
{
my $space = command('/usr/bin/stat', '-f', '-c', '%a:%S', '.');
my ($blocks, $size) = $space =~ /\A(\d+):(\d+)\s*\z/;
# Without a capacity result, continuing could fill the host filesystem.
die "Cannot determine worker staging space\n" if (!defined($blocks));
return $blocks * $size;
}

# image(request, emit)
# Acquires an image and verifies any requested checksum. QCOW2 and raw images
# undergo disk inspection; ISO imports retain their bytes without inspection.
# emit(event) publishes progress; output holds the file for the controller.
sub image
{
my ($r, $emit) = @_;
# The root controller derives this finite budget from configuration and space.
my $limit = Cloudmin::Worker::byte_limit($r->{'limit'});
my ($last, $checked) = (0, 0);
if (($r->{'task'} || '') eq 'local_image') {
	# Open the source as the worker so imports cannot expose root-only
	# files.
	my $path = $r->{'path'};
	# Host imports require a literal absolute path without control
	# characters.
	die "Invalid host image path\n" if (!defined($path) || ref($path) ||
		$path !~ m{\A/} || $path =~ /[\x00-\x1f]/);
	# These fixed read-only mounts expose host temporary files without
	# replacing the worker's own private /tmp or bypassing file permissions.
	$path =~ s{\A/tmp/}{/run/cloudmin-host-tmp/};
	$path =~ s{\A/var/tmp/}{/run/cloudmin-host-var-tmp/};
	sysopen(my $source, $path, O_RDONLY|O_NOFOLLOW|O_NONBLOCK)
		|| die "Cannot read this host image without root privileges: $!. Use a readable image file or upload it instead.\n";
	# Do not read device nodes or wait on named pipes supplied as
	# image paths.
	die "Select a regular image file\n" if (!-f $source);
	my $size = -s $source;
	# Reject files that cannot fit before creating the private copy.
	die "The image is empty or exceeds the staging limit\n"
		if (!$size || $size > $limit);
	# Keep a reserve on the worker filesystem, not just the final
	# storage pool.
	die "Not enough free space for the image\n"
		if (free_space() < $size + 256 * 1024**2);
	open(my $output, '>', 'image') ||
		die "Cannot prepare host image copy\n";
	binmode($source); binmode($output);
	my $total = 0;
	$emit->({ type => 'progress', phase => 'copying', mode => 2,
		value => $size });
	while (1) {
		my $n = sysread($source, my $buffer, 1024**2);
		# A failed read is distinct from reaching the end of the
		# host file.
		die "Cannot read host image\n" if (!defined($n));
		# EOF finishes the copy before reporting the final
		# staged size.
		last if (!$n);
		$total += $n;
		# The source may grow after the initial size check.
		die "Host image exceeds the staging limit\n"
			if ($total > $limit);
		# Concurrent imports or a growing source must leave the host a
		# reserve.
		if ($total - $checked >= 64 * 1024**2) {
			die "Image staging is running out of free space\n"
				if (free_space() < 256 * 1024**2);
			$checked = $total;
			}
		print($output $buffer) || die "Cannot copy host image\n";
		if (time() != $last) {
			# Report at most once a second while copying a large
			# host file.
			$emit->({ type => 'progress', phase => 'copying',
				mode => 3, value => $total });
			$last = time();
			}
		}
	close($source);
	close($output) || die "Cannot finish host image copy\n";
	}
if ($r->{'url'}) {
	# Download progress comes from HTTP headers and received body chunks.
	my ($redirect, $total) = (0, 0);
	Cloudmin::HTTP::download($r->{'url'}, getcwd().'/image', sub {
		# progress(mode, value) tracks redirects, response size
		# and body bytes.
		my ($mode, $value) = @_;
		# A redirect response's length does not describe the
		# final image.
		$redirect = $value if ($mode == 1);
		# Retain the final server's length for completeness
		# checks below.
		$total = $value || 0 if ($mode == 2 && !$redirect);
		# Enforce the budget against headers and the actual
		# received bytes.
		die "Image exceeds the available staging limit.\n"
			if (($mode == 3 || ($mode == 2 && !$redirect)) &&
			($value || 0) > $limit);
		if ($mode == 3 && $value - $checked >= 64 * 1024**2) {
			# Recheck space periodically because other jobs may fill
			# the disk.
			die "Image staging is running out of free space.\n"
				if (free_space() < 256 * 1024**2);
			$checked = $value;
			}
		if (($mode == 2 && !$redirect) ||
			($mode == 3 && time() != $last)) {
			# Report the final response size and throttle body
			# progress updates.
			$emit->({ type => 'progress', phase => 'downloading',
				mode => $mode, value => 0 + ($value || 0) });
			# Throttle body events without delaying the
			# initial size announcement.
			$last = time() if ($mode == 3);
			}
		});
	# Without a stated length, a connection closed early looks like a
	# complete file. Only a checksum can then prove that the download is
	# whole.
	die "The image server did not state the file size, so the download cannot be ".
		"checked for completeness. Supply a SHA-256 checksum.\n"
		if (!$total && !$r->{'sha256'} && !$r->{'checksum_url'});
	}
my $bytes = -s 'image';
# Validate uploads and completed copies even if no download callback
# ran.
die "The image is empty or exceeds the staging limit.\n"
	if (!$bytes || $bytes > $limit);
$emit->({ type => 'progress', phase => 'verifying', bytes => $bytes });
my $expected = $r->{'sha256'};
my $algorithm = 'sha256';
if ($r->{'checksum_url'}) {
	# Match the publisher's manifest entry to this exact image filename.
	$algorithm = $r->{'checksum_algorithm'} || 'sha256';
	my $manifest = '';
	Cloudmin::HTTP::download($r->{'checksum_url'}, \$manifest, sub {
		# progress(mode, value) bounds the manifest before it
		# grows in memory.
		my ($mode, $value) = @_;
		# A checksum manifest should never approach the size of
		# a disk image.
		die "The checksum file is too large\n"
		if (($mode == 2 || $mode == 3) && ($value || 0) > 1024**2);
		});
	my ($filename) = $r->{'url'} =~ m{/([^/]+)$};
	$expected = Cloudmin::Images::checksum($manifest, $filename,
		$algorithm);
	}
my $digest;
if ($expected) {
	# A supplied digest must match before the image is inspected or
	# returned.
	open(my $fh, '<', 'image') || die "Cannot read staged image\n";
	binmode($fh);
	$digest = Digest::SHA->new($algorithm eq 'sha512' ? 512
		: 256)->addfile($fh)->hexdigest();
	# A mismatch leaves the file private and prevents any libvirt
	# import.
	die "Image checksum mismatch. Nothing was added to storage; please retry.\n" if ($digest ne lc($expected));
	}
# ISO imports skip disk parsing; transfer limits and requested checksum checks
# still apply. The file size supplies the raw volume capacity.
my $info = ($r->{'format'} || '') eq 'iso'
	? { format => 'iso', 'virtual-size' => $bytes }
	: disk_info($r->{'format'});
rename('image', 'output') || die "Cannot finish processing image\n";
return { %$info, bytes => $bytes, verified => $expected ? $algorithm : '',
	checksum_digest => $digest || '' };
}

1;
