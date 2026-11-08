package Cloudmin::TPM;

# Clone only libvirt-managed emulator state; physical TPMs cannot be duplicated.
use strict;
use warnings;
use Cwd qw(abs_path);
use Fcntl qw(:DEFAULT O_NOFOLLOW);
use Digest::SHA qw(sha256_hex);
use File::Basename qw(dirname);
require(dirname(__FILE__).'/Libvirt.pm');
require(dirname(__FILE__).'/Worker.pm');
require(dirname(__FILE__).'/Jobs.pm');

our $DIRECTORY = '/var/lib/libvirt/swtpm';
my $LIMIT = 16 * 1024**2;

# path(uuid) validates the owner UUID and returns its system TPM 2.0 directory.

sub path
{
my ($uuid) = @_;
die "Invalid TPM owner UUID\n"
	if ($uuid !~ /\A[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}\z/);
return "$DIRECTORY/$uuid/tpm2";
}

# directory(path) returns the device and inode used to detect replacement.
# Require the canonical path; symlinks in parent directories are also refused.

sub directory
{
my ($path) = @_;
my @st = lstat($path);
die "TPM state directory is missing or unsafe\n"
	if (!@st || !-d _ || -l _ || (abs_path($path) || '') ne $path);
return "$st[0]:$st[1]";
}

# source(adapter, domain, document) validates an optional software TPM. Returns
# its path and directory identity, or undef for a guest without a TPM.

sub source
{
my ($adapter, $domain, $doc) = @_;
my @devices = $doc->findnodes('/domain/devices/tpm');
# Guests without a TPM continue through ordinary disk and firmware cloning.
return undef if (!@devices);
# Only one software TPM 2.0 emulator has a supported state layout.
die "Cloning supports one libvirt-managed TPM 2.0 emulator\n"
	if (@devices != 1 ||
	    $devices[0]->findvalue('backend/@type') ne 'emulator' ||
	    $devices[0]->findvalue('backend/@version') ne '2.0');
my $path = path($domain->get_uuid_string());
my $custom = $devices[0]->findvalue('backend/source/@path');
# An explicit path is allowed only when it names the usual managed directory.
# Encrypted state also needs libvirt secret handling.
die "Cloning does not support encrypted or custom TPM storage\n"
	if ($devices[0]->exists('backend/encryption') ||
	    $devices[0]->exists('backend/source') &&
	    ($custom ne $path ||
	     $devices[0]->findvalue(
		     'backend/source/@type') ne 'dir'));
# These filesystem paths belong to the local system connection only.
die "TPM cloning requires the local system libvirt connection\n"
	if ($adapter->uri() ne 'qemu:///system');
# Reject shared state and record its identity before the clone is queued.
assert_unused($adapter, $domain->get_uuid_string(), $path);
my $identity = directory($path);
# Reject empty permanent state instead of creating a fresh TPM in the clone.
die "The source TPM permanent state is empty\n"
	if (!length(read_state("$path/tpm2-00.permall")));
return { path => $path, identity => $identity };
}

# assert_unused(adapter, uuid, path) rejects state referenced by another guest.
# uuid is the owner to exclude; path is its state directory.

sub assert_unused
{
my ($adapter, $uuid, $path) = @_;
# Another guest may explicitly point to this guest's state directory.
foreach my $other ($adapter->connect()->list_all_domains()) {
	# The owner's reference is expected and does not imply shared storage.
	next if ($other->get_uuid_string() eq $uuid);
	# Inspect live XML too; a saved edit need not match the running guest.
	my @xml = ($other->get_xml_description(0));
	# Transient guests have no saved definition to inspect.
	push(@xml, $other->get_xml_description(2)) if ($other->is_persistent());
	foreach my $xml (@xml) {
		my $doc = Cloudmin::Libvirt::parse_xml_document($xml);
		foreach my $node (
			$doc->findnodes(
				'/domain/devices/tpm/backend/source/@path')) {
			# Resolve aliases and reject
			# overlapping directory trees.
			my $shared = abs_path($node->getValue()) ||
				     $node->getValue();
			die "TPM state is shared with another virtual machine\n"
				if ($shared eq $path || index($shared,
							      "$path/") == 0 || index($path,
										      "$shared/") == 0);
			}
		}
	}
}

# read_state(path) reads up to 16 MiB without following links.

sub read_state
{
my ($path) = @_;
# Do not follow a link or block on a FIFO before checking the opened file.
sysopen(my $fh, $path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) or
	die "Cannot read TPM state\n";
my @st = stat($fh);
# Reject special files, shared inodes and oversized state before reading bytes.
die "TPM state must be a regular file without hard links, no larger than 16 MiB\n"
	if (!-f $fh || $st[3] != 1 || $st[7] > $LIMIT);
my $bytes = '';
while (1) {
	# Read in chunks so a concurrent writer cannot bypass the size limit.
	my $n = sysread($fh, my $part, 65536);
	# A read error must not be treated as a complete state file.
	die "Cannot read TPM state\n" if (!defined($n));
	# Only EOF completes the copy of this file.
	last if (!$n);
	$bytes .= $part;
	# Recheck the accumulated size even if the initial
	# stat was within bounds.
	die "TPM state exceeds 16 MiB\n" if (length($bytes) > $LIMIT);
	}
close($fh) or die "Cannot close TPM state\n";
return $bytes;
}

# files(path) lists supported swtpm state files, excluding the lock.

sub files
{
my ($path) = @_;
# Revalidate the directory before each listing, including rollback.
directory($path);
opendir(my $dh, $path) or die "Cannot list TPM state\n";
my @names = grep { $_ ne '.' && $_ ne '..' } readdir($dh);
closedir($dh);
# Unknown backend files need explicit support before copying or deleting them.
die "Unrecognized files in TPM state directory\n"
	if (grep {
		$_ !~ /\A(?:\.lock|tpm2-00\.(?:permall|volatilestate|savestate))\z/ } @names);
# The emulator's lock is runtime coordination, not persistent TPM state.
return sort grep { $_ ne '.lock' } @names;
}

# copy(source, uuid, job_id, domain, journal) copies a stopped source's TPM.
# source is the descriptor from source(); uuid belongs to the new clone.
# journal() records intent before allocation so interrupted jobs can roll back.

sub copy
{
my ($source, $uuid, $id, $domain, $journal) = @_;
Cloudmin::Jobs::validate_id($id);
# Recheck shutdown even when the source was stopped at submission.
die "Shut down the source before copying its TPM\n" if ($domain->is_active());
# A recreated directory could belong to a newly initialized TPM.
die "The source TPM state directory was replaced\n"
	if (directory($source->{'path'}) ne $source->{'identity'});
my @files = files($source->{'path'});
# Without permanent state the clone could silently initialize a new TPM.
die "The source TPM permanent state is missing\n"
	if (!grep { $_ eq 'tpm2-00.permall' } @files);
my $path = path($uuid);
my $parent = dirname($path);
directory($DIRECTORY);
# Never merge a copy into state already present under the destination UUID.
die "The clone TPM directory already exists\n" if (-e $parent || -l $parent);
# Check capacity for the bounded state files before creating anything.
die "Not enough storage for cloned TPM state\n"
	if (Cloudmin::Worker::free_space($DIRECTORY) < 64 * 1024**2);
# Record the destination before even the parent directory can be left behind.
$journal->();
mkdir($parent, 0711) or die "Cannot create clone TPM directory\n";
# Libvirt runs swtpm under its own account, even when Webmin uses umask 077.
chmod(0711, $parent) or die "Cannot set clone TPM directory permissions\n";
# The root-owned marker identifies this job's files before domain definition.
sysopen(my $marker, "$parent/clone-$id", O_WRONLY | O_CREAT | O_EXCL, 0600) or
	die "Cannot record clone TPM ownership\n";
close($marker) or die "Cannot close clone TPM ownership marker\n";
mkdir($path, 0700) or die "Cannot create clone TPM storage\n";
my %hashes;
foreach my $name (@files) {
	my $bytes = read_state("$source->{path}/$name");
	# Permanent state must still be populated after submission and shutdown.
	die "The source TPM permanent state is empty\n"
		if ($name eq 'tpm2-00.permall' && !length($bytes));
	# Hash the bytes written to each new private destination file.
	$hashes{$name} = sha256_hex($bytes);
	sysopen(my $fh, "$path/$name", O_WRONLY | O_CREAT | O_EXCL, 0600) or
		die "Cannot create cloned TPM state\n";
	print($fh $bytes) && close($fh) or
		die "Cannot write cloned TPM state\n";
	}
# Refuse source restarts, replacement or changed bytes detected after copying.
die "The source TPM changed while cloning\n" if ($domain->is_active() ||
						 directory($source->{'path'}) ne $source->{'identity'} ||
						 join(',',
						      files($source->{'path'})) ne join(',', @files) ||
						 grep { sha256_hex(
							 read_state("$source->{path}/$_")) ne $hashes{$_} } @files);
return $path;
}

# remove_copy(adapter, uuid, job_id) removes an undefined clone's owned state.
# uuid identifies the clone; job_id must match its allocation marker.

sub remove_copy
{
my ($adapter, $uuid, $id) = @_;
Cloudmin::Jobs::validate_id($id);
my $path = path($uuid);
my $parent = dirname($path);
# Libvirt or an earlier rollback may already have removed the whole directory.
return 1 if (!-e $parent && !-l $parent);
# A defined guest retains ownership of its state, even while stopped.
die "The cloned TPM is still in use\n" if ($adapter->find_domain($uuid));
# Check the directory and other guests again before deleting any files.
directory($parent);
assert_unused($adapter, $uuid, $path);
# Without a marker, remove the parent only if it is empty.
if (!-e "$parent/clone-$id") {
	rmdir($parent) or die "Clone TPM ownership changed; cleanup stopped\n";
	return 1;
	}
# Only an ordinary, unshared marker owned by the worker proves job ownership.
my @st = lstat("$parent/clone-$id");
die "Clone TPM ownership changed; cleanup stopped\n"
	if (!@st || !-f _ || -l _ || $st[3] != 1 || $st[4] != $>);
if (-e $path || -l $path) {
	# Remove state and lock files only from this job's directory.
	my @files = files($path);
	unlink("$path/$_") or
		die "Cannot remove cloned TPM state\n" foreach @files;
	# swtpm may leave a lock file behind after its state has been used.
	unlink("$path/.lock") or die "Cannot remove cloned TPM lock\n"
		if (-e "$path/.lock" || -l "$path/.lock");
	rmdir($path) or die "Cannot remove cloned TPM storage\n";
	}
# Keep the ownership marker until all state has been removed successfully.
unlink("$parent/clone-$id") or die "Cannot remove clone TPM ownership marker\n";
rmdir($parent) or die "Cannot remove clone TPM directory\n";
return 1;
}

1;
