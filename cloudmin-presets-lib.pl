# Templates and plans share storage and controllers, with separate Webmin pages.
use strict;
use warnings;
our (%text, %config, %in, $module_root_directory, $module_config_directory, $remote_user);
require "$module_root_directory/lib/Cloudmin/Presets.pm";

# get_presets() uses Webmin access, locking and audit helpers for preset storage.
sub get_presets
{
return Cloudmin::Presets->new(directory => $module_config_directory,
	virtualmin_enabled => virtualmin_enabled(),
	access => sub {
		# access(writing) denies writes before locking or opening configuration.
		die "Template and plan changes are disabled in read-only mode\n"
			if ($_[0] && is_readonly_mode());
		require_access($_[0] ? 'manage' : 'host');
	}, lock => \&lock_data_file, unlock => \&unlock_data_file,
	# host_cpus() reads capacity without opening a writable connection.
	host_cpus => sub { get_libvirt(0)->connect()->get_node_info()->{'cpus'} },
	template_users => \&get_template_users,
	# log(action, type, id, details) uses Webmin's normal audit trail.
	log => sub { webmin_log(@_); });
}

1;
