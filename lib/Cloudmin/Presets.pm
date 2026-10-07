package Cloudmin::Presets;

# Saved creation defaults. These records do not own or modify existing VMs.
use strict;
use warnings;
use WebminCore qw(read_file_contents write_file_contents convert_to_json convert_from_json);
use File::Basename qw(dirname);
require(dirname(__FILE__).'/VMs.pm');

# new(class, directory => path, access => callback, lock => callback,
#     unlock => callback, log => callback, [host_cpus => callback],
#     [template_users => callback], [virtualmin_enabled => boolean])
# access(writing) must refuse unauthorized callers before any file access.
# lock(path) and unlock(path) protect writes; log(action, kind, id, details)
# records successful changes without copying template settings into the log.
# host_cpus() sizes the unedited bundled plan for this compute host.
# template_users() maps template IDs to guest names and is required for deletion.
# virtualmin_enabled defaults to true. When false, it blocks templates that
# select Virtualmin.
sub new
{
my ($class, %args) = @_;
return bless(\%args, $class);
}

# path(self, kind) limits storage to the two supported configuration files.
sub path
{
my ($self, $kind) = @_;
die "Unknown preset type\n" if ($kind !~ /\A(?:template|plan)\z/);
return "$self->{directory}/${kind}s.json";
}

1;
