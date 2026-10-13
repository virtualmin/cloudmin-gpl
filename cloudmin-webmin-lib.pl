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

1;
