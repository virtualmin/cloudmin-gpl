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

# vm_webmin_server(uuid, [creation_job]) finds only Cloudmin's own registration.
# Supplying creation_job prevents a reused UUID from adopting an older login.
sub vm_webmin_server
{
my ($uuid, $job) = @_;
# An uninstalled module has no registration to find or remove.
return if (!foreign_check('servers'));
foreign_require('servers', 'servers-lib.pl');
my ($server) = grep { ($_->{'cloudmin_uuid'} || '') eq ($uuid || '') &&
	(!defined($job) || ($_->{'cloudmin_job'} || '') eq $job) } servers::list_servers();
return $server;
}

# vm_webmin_lock(uuid, callback) serializes changes to a guest's registration.
# Invoke callback with no arguments and return its result after unlocking.
sub vm_webmin_lock
{
my ($uuid, $code) = @_;
# The UUID becomes part of a lock filename, so accept no path characters.
die "Invalid virtual machine ID\n"
	if (($uuid || '') !~ /\A[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}\z/);
my $path = "$module_config_directory/webmin-$uuid";
lock_data_file($path);
# Catch native errors so failed callbacks still release the lock.
local $main::error_must_die = 1;
my $result = eval { $code->() };
my $error = $@;
unlock_data_file($path);
# Rethrow the callback error after releasing the lock.
die $error if ($error);
return $result;
}

# vm_webmin_server_change(server, callback) excludes login files from audit copies.
# The callback saves or deletes this entry through the native Servers Index API.
sub vm_webmin_server_change
{
my ($server, $code) = @_;
my $file = "$servers::module_config_directory/$server->{'id'}.serv";
# Acquire the native file lock without capturing credentials for diffs or undo.
lock_data_file($file, 0, 0, 1);
local $main::error_must_die = 1;
my $ok = eval { $code->(); 1 };
my $error = $@;
# Native saves release the lock themselves; deletes and failures may not.
unlock_data_file($file);
# Preserve the native failure after releasing the credential file's lock.
die $error if (!$ok);
}

1;
