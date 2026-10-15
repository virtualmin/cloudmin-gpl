# Network controller integration with Webmin authentication, locks and logging.
use strict;
use warnings;
use File::Basename ();
use Cwd ();
# Use the same timeout bounds in the controller and Module Configuration.
require(Cwd::abs_path(File::Basename::dirname(__FILE__).'/cloudmin-config-lib.pl'));
# Load ACL helpers once, even when callers use different paths.
require(Cwd::abs_path(File::Basename::dirname(__FILE__).'/cloudmin-access-lib.pl'));
our ($module_root_directory, $module_var_directory, $remote_user);
require "$module_root_directory/lib/Cloudmin/Networks.pm";
require "$module_root_directory/lib/Cloudmin/HostNetwork.pm";

# get_host_network()
# Keeps rollback journals private and uses the VM controller's resource locks.
sub get_host_network
{
return Cloudmin::HostNetwork->new(directory => "$module_var_directory/networking",
	module => $module_root_directory, jobs => get_vm_jobs(),
	confirm_timeout => config_number('bridge_confirm_timeout'),
	client => $ENV{'REMOTE_ADDR'});
}

# get_network_service([writable])
# Network mutations are local-host operations; inventory shares the same adapter.
# writable defaults to false; true requests a libvirt connection for changes.
sub get_network_service
{
# Network inventory includes host interfaces outside the user's assigned VMs.
require_access('host');
my ($writable) = @_;
my $adapter = get_libvirt($writable);
die "Networking is available only for the local qemu:///system host\n"
	if ($adapter->uri() ne 'qemu:///system');
return Cloudmin::Networks->new(adapter => $adapter,
	host => get_host_network(), jobs => get_vm_jobs());
}

1;
