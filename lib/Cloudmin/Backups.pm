package Cloudmin::Backups;

# Full backups preserve guest identity; only clones prepare a new identity.
use strict;
use warnings;
use File::Basename qw(dirname);
use File::Path qw(make_path remove_tree);
use File::Temp qw(tempfile);
use Digest::SHA qw(sha256_hex);
use JSON::PP qw(encode_json decode_json);
use POSIX qw(strftime);
use Fcntl qw(:DEFAULT O_NOFOLLOW);
require(dirname(__FILE__).'/Clones.pm');
our @ISA = ('Cloudmin::Clones');

# directory(self) creates private metadata storage outside the web root.
sub directory
{
my ($self) = @_;
my $dir = $self->{'directory'};
# Credentials and secure XML must remain private even in an existing directory.
make_path($dir, {mode => 0700}) if (!-e $dir);
my @st = lstat($dir);
die "Unsafe backup metadata directory\n" if (!@st || !-d _ || -l _ || $st[4] != $> || ($st[2] & 0077));
return $dir;
}

# record(self, id, [value]) reads or atomically saves a private backup record.
sub record
{
my ($self, $id, $value) = @_;
Cloudmin::Jobs::validate_id($id);
my $path = $self->directory()."/$id.json";
if ($value) {
	# Publish metadata only after writing a complete private file.
	my ($fh, $temp) = tempfile('.record-XXXXXXXX', DIR => $self->directory(), UNLINK => 1);
	print($fh encode_json($value)) && close($fh) or die "Cannot write backup record\n";
	rename($temp, $path) or die "Cannot save backup record\n";
	return $value;
}
# Missing records are normal for unfinished jobs; malformed records must fail.
return undef if (!-f $path);
open(my $fh, '<', $path) or die "Cannot read backup record\n";
local $/;
return decode_json(<$fh>);
}

# archive_filename(name, job_id, timestamp, compressed) makes archives identifiable.
# The full job ID still prevents collisions between simultaneous submissions.
sub archive_filename
{
my ($name, $id, $time, $compressed) = @_;
$name =~ s/[^a-zA-Z0-9_.-]+/-/g;
$name = substr($name, 0, 100) || 'machine';
return 'cloudmin-'.$name.'-'.strftime('%Y%m%dT%H%M%SZ', gmtime($time))."-$id.tar".($compressed ? '.gz' : '');
}

# firmware_digest(path, identity) hashes a bounded regular NVRAM file.
# Checking both file metadata and content catches writes and replacements.
sub firmware_digest
{
my ($path, $identity) = @_;
sysopen(my $fh, $path, O_RDONLY|O_NOFOLLOW) or die "Cannot read firmware variables\n";
# Match the opened inode to the source validated before quiescing.
my @before = stat($fh);
die "Invalid firmware variables file\n" if (!-f $fh || !$before[7] || $before[7] > 64*1024**2 ||
	join(':', @before[0,1]) ne $identity);
my $hash = Digest::SHA->new(256);
my ($bytes, $buffer) = (0, '');
# Bound reads even if the live firmware file grows while it is being hashed.
while (1) {
	my $n = read($fh, $buffer, 65536);
	die "Cannot read firmware variables\n" if (!defined($n));
	last if (!$n);
	$bytes += $n;
	die "Firmware variables grew during backup\n" if ($bytes > 64*1024**2);
	$hash->add($buffer);
}
# Reject metadata or length changes observed during this read.
my @after = stat($fh); close($fh);
die "Firmware variables changed during backup; retry or choose clean shutdown\n"
	if ($bytes != $before[7] || join(':', @before[0,1,7,9,10]) ne join(':', @after[0,1,7,9,10]));
return $hash->hexdigest();
}

# copy_firmware(source, destination, identity, [before]) accepts only stable bytes.
# For live backup, before is captured immediately before the disk snapshot.
sub copy_firmware
{
my ($source, $dest, $identity, $before) = @_;
$before ||= firmware_digest($source, $identity);
Cloudmin::Worker::copy_file($source, $dest, 64*1024**2);
die "Firmware variables changed during backup; retry or choose clean shutdown\n"
	if (firmware_digest($source, $identity) ne $before ||
		firmware_digest($dest, Cloudmin::VMManage::file_identity($dest)) ne $before);
}

1;
