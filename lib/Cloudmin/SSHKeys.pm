package Cloudmin::SSHKeys;

# Host login keys belong to one VM creation, never to an administrator account.
use strict;
use warnings;
use WebminCore qw(make_dir);

# new(class, directory) Uses Cloudmin's private module data directory, outside
# the web document root.

sub new
{
return bless({ directory => $_[1] }, $_[0]);
}

# path(self, uuid, job_id) Binds a key to both the guest UUID and
# its creation marker.

sub path
{
my ($self, $uuid, $job) = @_;
# Both identifiers become path components and must have their exact formats.
die "Invalid virtual machine SSH key identity\n" if (
	($uuid || '') !~ /\A[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}\z/ ||
	($job || '') !~ /\A[a-f0-9]{32}\z/);
return "$self->{directory}/$uuid-$job";
}

# check_directory(self, [create]) Requires a private directory owned by the
# controller's user (root in Webmin). create defaults to false; only allocation
# creates a missing directory.

sub check_directory
{
my ($self, $create) = @_;
my $dir = $self->{'directory'};
# Only new-key allocation may create storage; lookups remain read-only.
make_dir($dir, 0700, 1) ||
	die "Cannot create virtual machine SSH key directory\n"
	if ($create && !-e $dir && !-l $dir);
my @s = lstat($dir);
# A host that has never saved a key has no directory yet.
return 0 if (!@s && !$create);
# Never trust a shared, foreign-owned or redirected credential directory.
die "Unsafe virtual machine SSH key directory\n"
	if (!@s || !-d _ || -l _ || $s[4] != $> || ($s[2] & 0077));
return 1;
}

# destination(self, uuid, job_id) Prepares a new key's location without
# replacing an existing credential.

sub destination
{
my ($self, $uuid, $job) = @_;
my $path = $self->path($uuid, $job);
$self->check_directory(1);
# Retries must not overwrite the private key from an earlier creation.
die "A virtual machine SSH key already exists\n" if (-e $path || -l $path);
return $path;
}

# find(self, uuid, job_id) Returns a protected key path, or undef when this
# guest has no managed key.

sub find
{
my ($self, $uuid, $job) = @_;
my $path = $self->path($uuid, $job);
# An absent store means no managed key, rather than an unsafe credential.
return undef if (!$self->check_directory());
my @s = lstat($path);
# Guests created without host login keys have no matching file.
return undef if (!@s);
# Only a small, private, unshared regular file can be passed to SSH.
die "Unsafe virtual machine SSH key file\n" if (!-f _ || -l _ || $s[3] != 1 ||
						$s[4] != $> || ($s[2] & 0077) || !$s[7] || $s[7] > 16384);
return $path;
}

# remove(self, uuid, job_id) Removes only this creation's key after rollback or
# successful guest deletion.

sub remove
{
my ($self, $uuid, $job) = @_;
my $path = $self->path($uuid, $job);
# Deletion is also valid on hosts that never enabled managed SSH keys.
return if (!$self->check_directory());
# Remove a stale link itself without following its target.
unlink($path) || die "Cannot remove virtual machine SSH key: $!\n"
	if (-e $path || -l $path);
}

1;
