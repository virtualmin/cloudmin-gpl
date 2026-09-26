package Cloudmin::Worker;

# The controller retains job records and libvirt access. A fresh systemd service
# processes each task under its own temporary UID, with no inherited
# credentials.
use strict;
use warnings;
use JSON::PP qw(encode_json decode_json);
use File::Path qw(make_path remove_tree);
use File::Basename qw(dirname);
use Cwd qw(abs_path);
use Fcntl qw(:DEFAULT O_NOFOLLOW);
use Errno qw(EEXIST EXDEV);
use IPC::Open3;
use IO::Select;
use Symbol qw(gensym);
use POSIX qw(WNOHANG);
use Time::HiRes qw(time);

my $ROOT = '/var/lib/private/cloudmin-workers';
my $PUBLIC = '/var/lib/cloudmin-workers';
my %TIMEOUT = (image => 3600, local_image => 3600, convert => 3600, inspect => 180, clone_prepare => 900,
	backup_archive => 7200, backup_transfer => 7200, backup_host_key => 30,
	seed => 60, keys => 30, keypair => 30, size => 20, software => 7500);
my $SMALL_FILE = 16 * 1024**2;
my $RESERVE_BYTES = 256 * 1024**2;

# byte_limit(value)
# Accepts positive byte budgets representable exactly in controller and UI JSON.
sub byte_limit
{
my ($value) = @_;
die "Invalid image byte limit\n" if (!defined($value) || ref($value) ||
	$value !~ /\A[1-9]\d{0,15}\z/ || $value > 9007199254740991);
return 0 + $value;
}

# new(class)
# Creates a runner without touching the host during ordinary page rendering.
sub new
{
return bless({}, $_[0]);
}

# generate_id()
# Allocates a private task identifier independent of all user input.
sub generate_id
{
open(my $fh, '<', '/dev/urandom') || die "Cannot allocate image worker\n";
read($fh, my $bytes, 16) == 16 || die "Cannot allocate image worker\n";
return unpack('H*', $bytes);
}

# path(id)
# Checks a task ID's format before deriving its private directory path.
sub path
{
my ($id) = @_;
# Reject traversal and arbitrary service names before using the
# identifier.
die "Invalid image worker identifier\n" if (($id || '') !~ /\A[a-f0-9]{32}\z/);
return "$ROOT/$id";
}

1;
