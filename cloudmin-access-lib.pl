# Shared permission checks for pages, controllers and authenticated sockets.
use strict;
use warnings;
no warnings 'once';
use File::Basename ();
use Cwd ();
# Canonical paths avoid loading the policy twice through different entry points.
require(
	Cwd::abs_path(File::Basename::dirname(__FILE__).
		      '/lib/Cloudmin/Access.pm'));
our (%access, %text, $module_name);

# access_policy() returns the current request's effective Webmin permissions.
sub access_policy
{
# Tests may run without Webmin; real requests also check global read-only mode.
return Cloudmin::Access->new(\%access,
			     defined(&is_readonly_mode) && is_readonly_mode());
}

# can_access(action, [uuid]) checks permission for a page or controller action.
sub can_access
{
return access_policy()->allows(@_);
}

# require_access(action, [uuid]) checks ACLs and licensing for new changes. Use
# this at action entry, before resource lookup or changes.
sub require_access
{
die(($text{'acl_denied'} || 'Access denied by Cloudmin permissions')."\n")
	if (!can_access(@_));
# Keep forms and controls visible; check licensing when submitting a change.
require_cloudmin_license() if (defined(&require_cloudmin_license) &&
			       $_[0] =~ /\A(?:manage|power|force|password)\z/);
}

# power_permission(action) selects the ordinary or forced power grant. action
# must already be one of the supported VM power actions.
sub power_permission
{
return $_[0] =~ /\A(?:force_off|reset)\z/ ? 'force' : 'power';
}

# session_access(session) rereads the login and its current permissions. Status
# and relay processes must check each session's user, not their launcher.
# Returns identity and policy, or undef if the login or
# module access is invalid.
sub session_access
{
my ($session) = @_;
# Reject missing or oversized session IDs before opening Webmin's database.
return if (!$session || length($session) > 256);
# Read the session database directly; the launcher may lack Webmin Users access.
foreign_require('acl', 'acl-lib.pl');
my %miniserv;
get_miniserv_config(\%miniserv);
acl::open_session_db(\%miniserv);
my $entry = $acl::sessiondb{$session} ||
	    $acl::sessiondb{acl::hash_session_id($session)};
dbmclose(%acl::sessiondb);
# Reject missing logins and those that exceeded Webmin's inactivity limit.
my ($user, $last) = split(/\s+/, $entry || '');
return if (!$user || ($miniserv{'logouttime'} &&
		      time() - ($last || 0) > $miniserv{'logouttime'} * 60));
# Bypass cached permissions so open connections see later ACL edits.
local %main::acl_hash_cache;
local %main::acl_array_cache;
local %main::read_file_cache;
local %main::read_file_missing;
# Check module access and grants for the session's user.
my %modules;
read_acl(\%modules, undef, [ $user ]);
return if (!$modules{$user, $module_name} && !$modules{$user, '*'});
# Global read-only mode also blocks console and terminal grants.
my %global = get_module_acl($user, '');
my %acl = get_module_acl($user, $module_name);
return { user => $user, readonly => $global{'readonly'} ? 1 : 0,
	 policy => Cloudmin::Access->new(\%acl, $global{'readonly'}) };
}

1;
