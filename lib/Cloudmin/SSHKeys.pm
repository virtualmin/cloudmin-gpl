package Cloudmin::SSHKeys;

# Host login keys belong to one VM creation, never to an administrator account.
use strict;
use warnings;
use WebminCore qw(make_dir);

# new(class, directory)
# Uses Cloudmin's private module data directory, outside the web document root.
sub new
{
return bless({ directory => $_[1] }, $_[0]);
}

# path(self, uuid, job_id)
# Binds a key to both the guest UUID and its creation marker.
sub path
{
my ($self, $uuid, $job) = @_;
# Both identifiers become path components and must have their exact formats.
die "Invalid virtual machine SSH key identity\n" if (
	($uuid || '') !~ /\A[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}\z/ ||
	($job || '') !~ /\A[a-f0-9]{32}\z/);
return "$self->{directory}/$uuid-$job";
}

1;
