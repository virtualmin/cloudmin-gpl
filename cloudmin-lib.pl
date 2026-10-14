# Versioned controller entry points for the VM UI and API.
use strict;
use warnings;
use File::Basename ();
use Cwd ();
# Load ACL helpers once, even when callers use different paths.
require(Cwd::abs_path(File::Basename::dirname(__FILE__).'/cloudmin-access-lib.pl'));
no warnings 'once';
use Digest::SHA qw(sha256_hex);
use WebminCore qw(convert_to_json);
use MIME::Base64 ();
our (%config, %text, $module_root_directory, $module_var_directory,
	$remote_user);
require "$module_root_directory/lib/Cloudmin/Jobs.pm";
require "$module_root_directory/lib/Cloudmin/VMs.pm";
require "$module_root_directory/lib/Cloudmin/VMManage.pm";
require "$module_root_directory/cloudmin-presets-lib.pl";
require "$module_root_directory/cloudmin-webmin-lib.pl";

# get_snapshot_manager()
# Snapshot jobs share the VM journal and honor the module's read-only ACL.
sub get_snapshot_manager
{
require "$module_root_directory/lib/Cloudmin/Snapshots.pm";
return Cloudmin::Snapshots->new(jobs => get_vm_jobs(),
	images => get_image_jobs(), readonly => is_readonly_mode(),
	adapter => sub { get_libvirt(!is_readonly_mode()) });
}

# get_vm_jobs()
# Returns the private SQLite job store with Webmin locks and audit callbacks.
sub get_vm_jobs
{
# log(action, type, id, details) uses Webmin's existing audit log.
return Cloudmin::Jobs->new(directory => "$module_var_directory/vm-jobs",
	# Recheck at durable submission too; workers resume existing jobs unchanged.
	admit => sub { require_cloudmin_license() if (defined(&require_cloudmin_license)); },
	lock_file => \&lock_data_file,
	unlock_file => \&unlock_data_file, test_lock => \&test_lock,
	# host_guard() blocks resource changes while bridge recovery is pending.
	host_guard => sub {
		return if (!-f "$module_var_directory/networking/bridge.json");
		require "$module_root_directory/cloudmin-network-lib.pl";
		die "Wait for the pending bridge change to finish\n" if (get_host_network()->pending());
		},
	log => sub { webmin_log(@_); });
}

# get_vm_service()
# Creates a VM service with connections opened when needed.
sub get_vm_service
{
# adapter() creates a writable adapter; host_memory() returns available bytes.
return Cloudmin::VMs->new(jobs => get_vm_jobs(),
	images => get_image_jobs(), catalogue => get_image_catalogue(),
	adapter => sub { get_libvirt(1) },
	ssh_keys => get_ssh_keys(),
	# Enforce installer policy in shared preparation, including CLI/API calls.
	virtualmin_enabled => virtualmin_enabled(),
	# register_webmin(job, address) runs after pinned SSH confirms installation.
	# It completes accepted creation even if the license has since expired.
	register_webmin => sub { register_vm_webmin($_[0], $_[1], 1) },
	host_memory => sub {
		foreign_require('proc', 'proc-lib.pl');
		my (undef, $available) = proc::get_memory_info();
		return $available * 1024;
		});
}

1;
