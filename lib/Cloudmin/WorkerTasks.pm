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

1;
