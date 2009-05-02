# Functions for managing Webmin users who own Cloudmin systems.

# list_system_owners()
# Returns a list of Webmin user objects for additional Cloudmin logins
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
# Returns the hash ref for a Cloudmin system owner user
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
# Create or update a Webmin user who can manage Cloudmin systems
sub save_system_owner
{
local ($u, $oldu) = @_;
&foreign_require("acl", "acl-lib.pl");
local $acl = $u->{'acl'};
delete($u->{'acl'});
$u->{'readonly'} = $module_name;
$u->{'modules'} = [ $module_name, "servers" ];
if ($oldu) {
	&acl::modify_user($oldu->{'name'}, $u);
	}
else {
	&acl::create_user($u);
	}
$acl->{'owner'} = 1;
$acl->{'noconfig'} = 1;
$acl->{'real'} = $u->{'real'};
&save_module_acl($acl, $u->{'name'});

# Grant access to just owned servers
local %sacl = ( 'servers' => $acl->{'servers'},
		'edit' => 0,
		'find' => 0,
		'auto' => 0,
		'add' => 0,
		'links' => 1 );
&save_module_acl(\%sacl, $u->{'name'}, "servers");

&reload_miniserv();
}

# delete_system_owner(&user)
# Remove a Webmin user who can manage Cloudmin systems
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
return ( 'startup', 'shutdown', 'reboot', 'console', 'graph', 'view', 'run',
	 'domains', 'update', 'script', 'pause' );
}

# can_action([&server|&servers], [action])
# Returns if the current user can perform some action on some server
sub can_action
{
local ($server, $action) = @_;
if (!$access{'owner'}) {
	# Master admin can do anything
	return wantarray ? ( 1, undef ) : 1;
	}
local @rv = ( 1, undef );
if ($server && $access{'servers'} ne '*') {
	if (!defined(%can_servers_cache)) {
		foreach my $id (split(/\s+/, $access{'servers'})) {
			$can_servers_cache{$id} = 1;
			}
		}
	if (ref($server) eq 'ARRAY') {
		# Test a bunch of servers
		foreach my $s (@$server) {
			if (!$can_servers_cache{$s->{'id'}}) {
				@rv = ( 0, &text('can_eserver', $s->{'host'}) );
				}
			}
		}
	else {
		if (!$can_servers_cache{$server->{'id'}}) {
			@rv = ( 0, &text('can_eserver', $server->{'host'}) );
			}
		}
	}
if ($action && $access{'actions'} ne '*' && $rv[0]) {
	if (!defined(%can_actions_cache)) {
		foreach my $a (split(/\s+/, $access{'actions'})) {
			$can_actions_cache{$a} = 1;
			}
		$can_actions_cache{'refresh'} = 1;	# Always allowed
		}
	if (!$can_actions_cache{$action}) {
		@rv = ( 0, &text('can_eaction', $text{'owner_action_'.$action}
						|| $action) );
		}
	}
return wantarray ? @rv : $rv[0];
}

# can_action_error([&server|&servers], [action])
# Check if some action is allowed, call error if not
sub can_action_error
{
local ($server, $action) = @_;
local ($ok, $why) = &can_action($server, $action);
$ok || &error($why);
}

# can_create_server(type)
# Returns 1 if create a virtual system of some type is allowed.
# Only true for master admin right now
sub can_create_server
{
local ($type) = @_;
local $tdesc = $text{$type.'_typeshort'};
local @rv = !$access{'owner'} ? ( 1, undef )
			      : ( 0, &text('can_ecreate', $tdesc) );
return wantarray ? @rv : $rv[0];
}

# can_add_server(type)
# Returns 1 if adding a system of some type is allowed.
# Only true for master admin right now
sub can_add_server
{
local ($type) = @_;
local $tdesc = $text{$type.'_typeshort'};
local @rv = !$access{'owner'} ? ( 1, undef )
			      : ( 0, &text('can_eadd', $tdesc) );
return wantarray ? @rv : $rv[0];
}

# Calls error if the current user can't create a server
sub can_create_server_error
{
local ($type) = @_;
local ($ok, $why) = &can_create_server($type);
$ok || &error($why);
}

# Calls error if the current user can't add a server
sub can_add_server_error
{
local ($type) = @_;
local ($ok, $why) = &can_add_server($type);
$ok || &error($why);
}

# Returns 1 if the current user can re-check and see licence info
sub can_licence
{
return !$access{'owner'};
}

# get_server_owners(&server)
# Returns a list of owner objects for some server
sub get_server_owners
{
local ($server) = @_;
local @rv;
foreach my $o (&list_system_owners()) {
	local @acc = split(/\s+/, $o->{'acl'}->{'servers'});
	push(@rv, $o) if (&indexof($server->{'id'}, @acc) >= 0);
	}
return @rv;
}

1;

