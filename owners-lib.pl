# Functions for managing Webmin users who own VM2 systems.

# list_system_owners()
# Returns a list of Webmin user objects for additional VM2 logins
sub list_system_owners
{
&foreign_require("acl", "acl-lib.pl");
local @rv;
foreach my $u (&acl::list_users()) {
	next if (&indexof($module_name, @{$u->{'modules'}}) < 0);
	local %acl = &get_module_acl($u->{'name'});
	next if (!$acl{'owner'});
	$u->{'acl'} = \%acl;
	push(@rv, $u);
	}
return @rv;
}

# get_system_owner(name)
# Returns the hash ref for a VM2 system owner user
sub get_system_owner
{
local ($name) = @_;
&foreign_require("acl", "acl-lib.pl");
local ($u) = grep { $_->{'name'} eq $name } &acl::list_users();
return undef if (!$u);
local %acl = &get_module_acl($u->{'name'});
return undef if (!$acl{'owner'});
$u->{'acl'} = \%acl;
return $u;
}

# save_system_owner(&user, [&old])
# Create or update a Webmin user who can manage VM2 systems
sub save_system_owner
{
local ($u, $oldu) = @_;
&foreign_require("acl", "acl-lib.pl");
local $acl = $u->{'acl'};
delete($u->{'acl'});
if ($oldu) {
	&acl::modify_user($oldu->{'name'}, $u);
	}
else {
	$u->{'modules'} ||= [ $module_name ];
	&acl::create_user($u);
	}
$acl->{'owner'} = 1;
&save_module_acl($acl, $u->{'name'});
&reload_miniserv();
}

# delete_system_owner(&user)
# Remove a Webmin user who can manage VM2 systems
sub delete_system_owner
{
local ($u) = @_;
&foreign_require("acl", "acl-lib.pl");
&acl::delete_user($u->{'name'});
&reload_miniserv();
}

# list_owner_actions()
# Returns a list of all possible actions
sub list_owner_actions
{
return ( 'startup', 'shutdown', 'reboot', 'graph', 'view', 'run' );
}

# can_action(&server, [action])
# Returns if the current user can perform some action on some server
sub can_action
{
local ($server, $action) = @_;
return 1 if (!$access{'owner'});
if ($access{'servers'} ne '*') {
	local @servers = split(/\s+/, $access{'servers'});
	return 0 if (&indexof($server->{'id'}, @servers) < 0);
	}
if ($action && $access{'actions'} ne '*') {
	local @actions = split(/\s+/, $access{'actions'});
	return 0 if (&indexof($action, $actions) < 0);
	}
return 1;
}

1;

