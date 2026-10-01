package Cloudmin::CloneGuest;

# Clone preparation runs inside the unprivileged worker. Libguestfs mounts only
# independent copies, never source volumes or host filesystems.
use strict;
use warnings;
use File::Basename qw(dirname);
use JSON::PP qw(encode_json);
require(dirname(__FILE__).'/ImageInspector.pm');

# read_small(guestfs, path) bounds guest-controlled text before parsing it.
sub read_small
{
my ($g, $path) = @_;
return '' if (!$g->is_file($path, followsymlinks => 1));
die "Guest configuration is too large: $path\n" if ($g->filesize($path) > 1024*1024);
return $g->read_file($path);
}

# write_private(guestfs, path, content, [mode]) writes a root-owned guest file.
# mode defaults to 0600; callers can adjust ownership after writing.
# Replacing a symlink affects only its entry, never an unrelated guest target.
sub write_private
{
my ($g, $path, $content, $mode) = @_;
$g->mkdir_p(dirname($path));
$g->rm($path) if ($g->is_symlink($path));
$g->write($path, $content);
$g->chmod($mode // 0600, $path);
$g->chown(0, 0, $path);
}

1;
