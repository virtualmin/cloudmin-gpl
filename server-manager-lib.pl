# Common Cloudmin module setup and public functions.

# Make WebminCore available when the CGI runs from this module's directory.

BEGIN
{
push(@INC, '..');
}

use strict;
use warnings;
no warnings 'once';
use WebminCore;

our (%access, %config, %text);
our ($module_config_directory, $module_name, $module_root_directory,
     $module_var_directory);

# Load Webmin's configuration, language, and module access controls.
init_config();
%access = get_module_acl();
$config{'libvirt_uri'} ||= 'qemu:///system';

# License checks admit new work; workers can still finish accepted jobs.
require "$module_root_directory/cloudmin-license-lib.pl";

# Load backend functions before the widget builders that display their results.
require "$module_root_directory/server-manager-lib-funcs.pl";
require "$module_root_directory/cloudmin-pages.pl";
require "$module_root_directory/cloudmin-print.pl";
require "$module_root_directory/cloudmin-lib.pl";
require "$module_root_directory/cloudmin-tab-lib.pl";

1;

# Webmin's scheduler loads this file before calling registered functions.
# Load backup and notification callbacks for it and interactive requests.
require "$module_root_directory/cloudmin-backups-lib.pl";
require "$module_root_directory/cloudmin-notifications-lib.pl";
