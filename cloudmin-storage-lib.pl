# Storage integration uses Webmin's existing access, form-token and audit APIs.
use strict;
use warnings;
use File::Basename ();
use Cwd ();
# Load ACL helpers once, even when callers use different paths.
require(Cwd::abs_path(File::Basename::dirname(__FILE__).'/cloudmin-access-lib.pl'));
our ($module_root_directory, $remote_user);
require "$module_root_directory/lib/Cloudmin/Storage.pm";
require "$module_root_directory/cloudmin-disk-labels.pl";

# get_storage_service([writable])
# Opens the configured connection without changing pools during inventory reads.
# writable defaults to false; true requests a libvirt connection for changes.
sub get_storage_service
{
# Pools and volumes are host resources, including during read-only inventory.
require_access('host');
my ($writable) = @_;
return Cloudmin::Storage->new(adapter => get_libvirt($writable),
	jobs => get_vm_jobs(), images => get_image_jobs());
}

1;
