# Guest Webmin offers direct links and an optional same-origin host proxy.
use strict;
use warnings;
no warnings 'once';
our ($module_root_directory, $module_config_directory, $remote_user, %text);

# can_vm_webmin(uuid) checks access to the Webmin tab for the host's root login.
# Registered entries also need the per-server check when resolving their URLs.
sub can_vm_webmin
{
my ($uuid) = @_;
# Check the host login and guest visibility before loading native permissions.
return 0 if (($remote_user || '') ne 'root' || is_readonly_mode() || !can_access('view', $uuid) ||
	!foreign_available('servers'));
foreign_require('servers', 'servers-lib.pl');
# Cloudmin's root-only gate does not replace Servers Index's link permission.
return $servers::access{'links'} ? 1 : 0;
}

# require_webmin_registration([finishing]) checks server-list permissions.
# finishing is reserved for a worker completing an already accepted creation.
sub require_webmin_registration
{
# Registration stores host-side logins and requires Cloudmin management access.
die "Only root can register guest Webmin access through this host\n"
	if (($remote_user || '') ne 'root');
require_access($_[0] ? 'recover' : 'manage');
# Check module access before reading its separate add, edit and link grants.
die "Webmin Servers Index access is required to register a virtual machine\n"
	if (!foreign_available('servers'));
foreign_require('servers', 'servers-lib.pl');
die "Permission to add, edit and connect to Webmin servers is required\n"
	if (!$servers::access{'edit'} || !$servers::access{'add'} || !$servers::access{'links'});
}

1;
