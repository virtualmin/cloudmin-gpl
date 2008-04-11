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
}

1;

