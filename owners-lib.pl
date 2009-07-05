# Functions for managing Webmin users who own Cloudmin systems.

# list_system_owners()
# Returns a list of Webmin user objects for additional Cloudmin logins
sub list_system_owners
{
&foreign_require("acl", "acl-lib.pl");
local @rv;
my @plans = &list_plans();
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
	 'domains', 'update', 'script', 'pause', 'reset',
	 'create', 'delete', 'advanced', 'ips', 'limits', 'disks' );
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
# Returns 1 if creating a virtual system of some type is allowed.
sub can_create_server
{
local ($type) = @_;
local $tdesc = $text{$type.'_typeshort'};
local @rv;
local %actions = map { $_, 1 } split(/\s+/, $access{'actions'});
if (!$access{'owner'}) {
	# Master admin can do anything
	@rv = ( 1, undef );
	}
elsif ($actions{'actions'}) {
	# Creation not allowed at all
	@rv = ( 0, $text{'can_ecreateany'} );
	}
elsif ($access{'types'} && $access{'types'} !~ /\Q$type\E/) {
	# Cannot create this type
	@rv = ( 0, &text('can_ecreate', $tdesc) );
	}
else {
	# Check limits
	local $limits = &get_owner_limits();
	if (!$limits->{'max_servers'} ||
	    $limits->{'max_servers'} > $limits->{'servers'}) {
		# Under limit
		@rv = ( 1, undef );
		}
	else {
		# At limit
		@rv = ( 0,  &text('can_ecreatelimit',
				  $limits->{'max_servers'}) );
		}
	}
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

# Returns non-zero if switching to system owners is possible
sub supports_switch
{
return $main::session_id;
}

# get_owner_limits([username])
# Returns a hash ref of limits and counts for the current system owner. The
# keys are max_servers, servers, max_disk, disk, max_ram and ram
sub get_owner_limits
{
my ($name) = @_;
$name ||= $base_remote_user;
my $owner = &get_system_owner($name);
return undef if (!$owner);
my $rv = { 'max_servers' => $owner->{'acl'}->{'max_servers'},
	   'servers' => 0,
	   'max_ram' => $owner->{'acl'}->{'max_ram'},
	   'ram' => 0,
	   'max_disk' => $owner->{'acl'}->{'max_disk'},
	   'disk' => 0,
	   'max_cpu' => $owner->{'acl'}->{'max_cpu'},
	   'cpu' => 0,
	   'list' => [ ],
	 };
my %owned = map { $_, 1 } split(/\s+/, $owner->{'acl'}->{'servers'});
foreach my $s (grep { $owned{$_->{'id'}} } &list_managed_servers()) {
	$rv->{'servers'}++;
	push(@{$rv->{'servers'}}, $s);

	# Get disk limit, and add to total count
	my $dfunc = "type_".$s->{'manager'}."_get_disk_size";
	my $disk = defined(&$dfunc) ? &$dfunc($s) : undef;
	if (defined($disk)) {
		if ($disk) { $rv->{'disk'} += $disk; }
		else { $rv->{'disk_unlimited'}++; }
		}

	# Get RAM limit, and add to total count
	my $mfunc = "type_".$s->{'manager'}."_get_memory_size";
	my $ram = defined(&$mfunc) ? &$mfunc($s) : undef;
	if (defined($ram)) {
		if ($ram) { $rv->{'ram'} += $ram; }
		else { $rv->{'ram_unlimited'}++; }
		}

	# Get CPU limit
	my $cfunc = "type_".$s->{'manager'}."_get_cpu_size";
	my $cpu = defined(&$cfunc) ? &$cfunc($s) : undef;
	if (defined($cpu)) {
		if ($cpu) { $rv->{'cpu'} += $cpu; }
		else { $rv->{'cpu_unlimited'}++; }
		}
	}
return $rv;
}

# get_owner_plan([username])
# Returns the plan hash ref for the current user
sub get_owner_plan
{
my ($name) = @_;
$name ||= $base_remote_user;
my %oaccess = &get_module_acl($name);
return undef if (!$oaccess{'plan'});
return &get_plan($oaccess{'plan'});
}

# Returns non-zero if this Cloudmin install supports plans
sub supports_plans
{
return scalar(@virtual_server_management_types);
}

# list_plans()
# Returns a list of owner plan objects, each of which is a hash ref. If none
# exist yet, a default plan is returned.
sub list_plans
{
my @rv;
opendir(PLANS, $owner_plans_dir);
foreach my $f (readdir(PLANS)) {
	next if ($f eq "." || $f eq "..");
	my %plan;
	&read_file("$owner_plans_dir/$f", \%plan);
	$plan{'id'} = $f;
	push(@rv, \%plan);
	}
closedir(PLANS);
if (!@rv) {
	push(@rv, { 'id' => 1,
		    'default' => 1,
		    'desc' => $text{'plans_defplan'},
		    'max_servers' => 5,
		    'max_ram' => 1024*1024*1024,
		    'max_disk' => 10*1024*1024*1024,
		    'types' => join(' ', @virtual_server_management_types),
		    'actions' => join(' ', &list_owner_actions()),
		  });
	}
return @rv;
}

# get_plan(id)
# Returns a plan looked up by ID
sub get_plan
{
my ($id) = @_;
my ($rv) = grep { $_->{'id'} eq $id } &list_plans();
return $rv;
}

# save_plan(&plan)
# Create or update an account plan
sub save_plan
{
my ($plan) = @_;
if (!-d $owner_plans_dir) {
	&make_dir($owner_plans_dir, 0700);
	}
$plan->{'id'} ||= &server_id();
&write_file("$owner_plans_dir/$plan->{'id'}", $plan);
}

# delete_plan(&delete)
# Delete an existing plan
sub delete_plan
{
my ($plan) = @_;
&unlink_file("$owner_plans_dir/$plan->{'id'}");
}

# describe_plan(&plan)
# Returns a description of a plan and its limits
sub describe_plan
{
my ($plan) = @_;
return $plan->{'desc'}.' ('.
       &text('plan_dstr',
	     $plan->{'max_servers'} || $text{'domains_unlimited'},
	     $plan->{'max_ram'} ? &nice_size($plan->{'max_ram'})
				: $text{'domains_unlimited'},
	     $plan->{'max_disk'} ? &nice_size($plan->{'max_disk'})
				: $text{'domains_unlimited'}).')';
}

# apply_plan(&plan)
# Update limits on all system owners from this plan
sub apply_plan
{
my ($plan) = @_;
foreach my $o (grep { $_->{'acl'}->{'plan'} eq $plan->{'id'} }
		    &list_system_owners()) {
	&apply_plan_to_owner($plan, $o);
	&save_system_owner($o, $o);
	}
}

# apply_plan_to_owner(&plan, &owner)
# Update an owner's ACL with plan limits
sub apply_plan_to_owner
{
my ($plan, $o) = @_;
$o->{'acl'}->{'max_servers'} = $plan->{'max_servers'};
$o->{'acl'}->{'max_ram'} = $plan->{'max_ram'};
$o->{'acl'}->{'max_disk'} = $plan->{'max_disk'};
$o->{'acl'}->{'max_cpu'} = $plan->{'max_cpu'};
$o->{'acl'}->{'types'} = $plan->{'types'};
if ($o->{'acl'}->{'actions_def'}) {
	$o->{'acl'}->{'actions'} = $plan->{'actions'};
	}
}

1;

