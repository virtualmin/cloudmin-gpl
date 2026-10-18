# Public Cloudmin functions backed by the configured libvirt connection.
# Optional adapters default to a new read-only Cloudmin::Libvirt object.

use strict;
use warnings;
use File::Basename ();
use Cwd ();
# Load ACL helpers once, even when callers use different paths.
require(Cwd::abs_path(File::Basename::dirname(__FILE__).'/cloudmin-access-lib.pl'));
no warnings 'once';
use List::Util qw(sum);
use POSIX qw(uname);

our (%config, %text);
our ($cloudmin_last_error, $module_root_directory, $module_var_directory,
	$module_config_directory, $remote_user);

require "$module_root_directory/lib/Cloudmin/Libvirt.pm";
require "$module_root_directory/lib/Cloudmin/SSHKeys.pm";
require "$module_root_directory/lib/Cloudmin/ImageCatalog.pm";
require "$module_root_directory/lib/Cloudmin/Images.pm";
require "$module_root_directory/cloudmin-image-sizes.pl";

# get_free_disk_space(directory)
# Returns available bytes on the directory's filesystem through Webmin's mount
# API.
sub get_free_disk_space
{
my ($directory) = @_;
local $main::error_must_die = 1;
foreign_require('mount', 'mount-lib.pl');
my ($mountpoint, undef, $type) = mount::filesystem_for_dir($directory);
# Do not mistake an unknown filesystem for unlimited staging space.
die "Cannot find the image staging filesystem.\n" if (!defined($mountpoint));
my (undef, $free) = mount::disk_space($type, $mountpoint);
# The mount API reports KiB; reject missing values before converting to bytes.
die "Cannot determine free staging space.\n"
	if (!defined($free) || $free !~ /\A\d+\z/);
return $free * 1024;
}

# lock_data_file(file, [readonly], [forcefile], [nodiff])
# Takes a Webmin lock for job stores and catalogue files, reporting failures as
# exceptions. Webmin's file locking can be turned off or limited to chosen
# directories in its configuration; without a real lock, workers and requests
# would no longer exclude each other, so that setting is an error here.
sub lock_data_file
{
my ($file, @options) = @_;
die "Changes are disabled in read-only mode\n" if (is_readonly_mode());
die "Cloudmin needs Webmin file locking enabled for $file\n"
	if (!can_lock_file($file));
local $main::error_must_die = 1;
return lock_file($file, @options);
}

1;
