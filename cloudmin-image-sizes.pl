# Cached download estimates using the same HTTPS requirements as image imports.
use strict;
use warnings;
our ($module_var_directory, $module_root_directory);
require "$module_root_directory/lib/Cloudmin/ImageSizes.pm";

# get_image_sizes()
# Supplies Webmin locking and a bounded HTTPS size probe to the cache.
sub get_image_sizes
{
return Cloudmin::ImageSizes->new(
	directory => "$module_var_directory/image-sizes",
	probe => \&probe_image_size,
	lock_file => \&lock_data_file,
	unlock_file => \&unlock_data_file, test_lock => \&test_lock,
);
}

# probe_image_size(url)
# Keeps response headers and TLS processing outside Webmin's privileged process.
sub probe_image_size
{
my ($url) = @_;
return Cloudmin::Worker->new()->run('size', { url => $url })->{'bytes'};
}

1;
