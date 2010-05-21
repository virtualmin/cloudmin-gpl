# Functions for managing Webmin users who own Cloudmin systems.

# list_system_owners()
# Returns a list of Webmin user objects for additional Cloudmin logins
sub list_system_owners
{
&foreign_require("acl", "acl-lib.pl");
my @rv;
my @plans = &list_plans();
foreach my $u (&acl::list_users()) {
	next if (&indexof($module_name, @{$u->{'modules'}}) < 0);
	my %acl = &get_module_acl($u->{'name'});
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
my ($name) = @_;
&foreign_require("acl", "acl-lib.pl");
my ($u) = grep { $_->{'name'} eq $name } &acl::list_users();
return undef if (!$u);
my %acl = &get_module_acl($u->{'name'});
return undef if (!$acl{'owner'});
$u->{'acl'} = \%acl;
return $u;
}

# save_system_owner(&user, [&old], [acl-only])
# Create or update a Webmin user who can manage Cloudmin systems
sub save_system_owner
{
my ($u, $oldu, $aclonly) = @_;
&foreign_require("acl", "acl-lib.pl");
my $acl = $u->{'acl'};
if (!$aclonly) {
	delete($u->{'acl'});
	$u->{'readonly'} = $module_name;
	$u->{'modules'} = [ $module_name, "servers" ];
	if ($oldu) {
		&acl::modify_user($oldu->{'name'}, $u);
		}
	else {
		&acl::create_user($u);
		}
	&reload_miniserv();
	}
$acl->{'owner'} = 1;
$acl->{'noconfig'} = 1;
$acl->{'real'} = $u->{'real'};
&lock_file("$module_config_directory/$u->{'name'}.acl");
&save_module_acl($acl, $u->{'name'});
&unlock_file("$module_config_directory/$u->{'name'}.acl");

# Grant access to just owned servers
my %sacl = ( 'servers' => $acl->{'servers'},
		'edit' => 0,
		'find' => 0,
		'auto' => 0,
		'add' => 0,
		'links' => 1 );
&lock_file("$config_directory/servers/$u->{'name'}.acl");
&save_module_acl(\%sacl, $u->{'name'}, "servers");
&unlock_file("$config_directory/servers/$u->{'name'}.acl");
}

# delete_system_owner(&user)
# Remove a Webmin user who can manage Cloudmin systems
sub delete_system_owner
{
my ($u) = @_;
&foreign_require("acl", "acl-lib.pl");
&acl::delete_user($u->{'name'});
if (defined(&list_backups)) {
	foreach my $backup (grep { $_->{'owner'} eq $u->{'name'} }
				 &list_backups()) {
		&delete_backup($backup);
		}
	}
&unlink_logged("$module_config_directory/$u->{'name'}.acl");
&unlink_logged("$config_directory/servers/$u->{'name'}.acl");
&reload_miniserv();
}

# list_owner_actions()
# Returns a list of all possible actions
sub list_owner_actions
{
return ( 'startup', 'shutdown', 'reboot', 'console', 'graph', 'view', 'run',
	 'pass', 'domains', 'update', 'script', 'pause', 'reset',
	 'create', 'add', 'delete', 'advanced', 'ips', 'ifaces', 'realifaces',
	 'reverse', 'limits', 'disks', 'devices', 'sshkeys', 'backup', 'webmin',
	 'virtualmin', 'api' );
}

# list_safe_owner_actions()
# Returns a set of actions that are reasonable for system owners
sub list_safe_owner_actions
{
return ( 'startup', 'shutdown', 'reboot', 'console', 'graph', 'view', 'run',
	 'pass', 'domains', 'update', 'script', 'pause', 'reset',
         'create', 'delete', 'ifaces', 'reverse', 'limits', 'disks',
	 'webmin', 'virtualmin', 'api' );
}

# can_action([&server|&servers], [action])
# Returns if the current user can perform some action on some server
sub can_action
{
my ($server, $action) = @_;
if (!$access{'owner'}) {
	# Master admin can do anything
	return wantarray ? ( 1, undef ) : 1;
	}
my @rv = ( 1, undef );
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

# can_owner_action(&owner, [&server|&servers], [action])
# Returns 1 if some system owner can perform some action
sub can_owner_action
{
my ($owner, $server, $action) = @_;
local %access = %{$owner->{'acl'}};
return &can_action($server, $action);
}

# can_action_error([&server|&servers], [action])
# Check if some action is allowed, call error if not
sub can_action_error
{
my ($server, $action) = @_;
my ($ok, $why) = &can_action($server, $action);
$ok || &error($why);
}

# can_action_usage([&server|&servers], [action])
# Check if some action is allowed, call usage if not
sub can_action_usage
{
my ($server, $action) = @_;
my ($ok, $why) = &can_action($server, $action);
$ok || &usage($why);
}

# can_create_server(type)
# Returns 1 if creating a virtual system of some type is allowed.
sub can_create_server
{
my ($type) = @_;
my $tdesc = $text{$type.'_typeshort'};
my @rv;
my %actions = map { $_, 1 } split(/\s+/, $access{'actions'});

# First check global license cap
my %licence;
&read_file_cached($licence_status, \%licence);
if ($licence{'servers'} > 0) {
	my @allservers = grep { &is_virtual_server($_) }
				 &list_managed_servers();
	if (scalar(@allservers) > $licence{'servers'}) {
		@rv = ( 0, &text('can_ecreatelic', $licence{'servers'}) );
		return wantarray ? @rv : $rv[0];
		}
	}

if (!$access{'owner'}) {
	# Master admin can do anything
	@rv = ( 1, undef );
	}
elsif (!&can_action(undef, 'create')) {
	# Creation not allowed at all
	@rv = ( 0, $text{'can_ecreateany'} );
	}
elsif ($access{'types'} && $access{'types'} !~ /\Q$type\E/) {
	# Cannot create this type
	@rv = ( 0, &text('can_ecreate', $tdesc) );
	}
else {
	# Check limits
	my $limits = &get_owner_limits();
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
my ($type) = @_;
my $tdesc = $text{$type.'_typeshort'};

# First check global license cap
my %licence;
&read_file_cached($licence_status, \%licence);
if ($licence{'servers'} > 0 && $type ne 'real') {
	my @allservers = grep { &is_virtual_server($_) }
				 &list_managed_servers();
	if (scalar(@allservers) > $licence{'servers'}) {
		my @rv = ( 0, &text('can_ecreatelic', $licence{'servers'}) );
		return wantarray ? @rv : $rv[0];
		}
	}

if (!$access{'owner'}) {
	# Master admin can do anything
	@rv = ( 1, undef );
	}
elsif (!&can_action(undef, 'add')) {
	# Creation not allowed at all
	@rv = ( 0, $text{'can_eaddany'} );
	}
elsif ($access{'types'} && $access{'types'} !~ /\Q$type\E/) {
	# Cannot create this type
	@rv = ( 0, &text('can_eadd', $tdesc) );
	}
else {
	# Check limits
	my $limits = &get_owner_limits();
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

# Calls error if the current user can't create a server
sub can_create_server_error
{
my ($type) = @_;
my ($ok, $why) = &can_create_server($type);
$ok || &error($why);
}

# Calls usage if the current user can't create a server
sub can_create_server_usage
{
my ($type) = @_;
my ($ok, $why) = &can_create_server($type);
$ok || &usage($why);
}

# Calls error if the current user can't add a server
sub can_add_server_error
{
my ($type) = @_;
my ($ok, $why) = &can_add_server($type);
$ok || &error($why);
}

# Returns 1 if the current user can re-check and see licence info
sub can_licence
{
return !$access{'owner'};
}

# can_host_server(&server)
# Returns 1 if virtual systems can be created on some host by the current user
sub can_host_server
{
my ($vhost) = @_;
return 1 if (!$access{'hosts'});
my %can = map { $_, 1 } split(/\s+/, $access{'hosts'});
return $can{$vhost->{'id'}};
}

# can_select_host_server()
# Returns 1 if the current user is allowed to select hosts
sub can_select_host_server
{
return !$access{'hostmode'};
}

# can_select_host_location()
# Returns 1 if selection of a host by location group is allowed
sub can_select_host_location
{
return $access{'hostmode'} eq '' || $access{'hostmode'} eq 'location';
}

# can_image([&image])
# Returns 1 if the current user can use some image. If no image is given, checks
# if creation from the base OS is allowed (as on Vservers or Zones)
sub can_image
{
my ($image) = @_;
if ($access{'images'}) {
	my @imgids = split(/\s+/, $access{'images'});
	return &indexof($image ? $image->{'id'} : 'none', @imgids) >= 0;
	}
return 1;
}

# get_server_owners(&server)
# Returns a list of owner objects for some server
sub get_server_owners
{
my ($server) = @_;
my @rv;
foreach my $o (&list_system_owners()) {
	my @acc = split(/\s+/, $o->{'acl'}->{'servers'});
	push(@rv, $o) if (&indexof($server->{'id'}, @acc) >= 0);
	}
return @rv;
}

# Returns non-zero if switching to system owners is possible
sub supports_switch
{
return $main::session_id;
}

# get_owner_limits([username|&owner])
# Returns a hash ref of limits and counts for the current system owner. The
# keys are max_servers, servers, max_disk, disk, max_ram and ram
sub get_owner_limits
{
my ($name) = @_;
$name ||= $base_remote_user;
my $owner = ref($name) ? $name : &get_system_owner($name);
return undef if (!$owner);
my $rv = { 'list' => [ ],
	 };
foreach my $l (@plan_limit_types) {
	$rv->{$l} = 0;
	$rv->{'max_'.$l} = $owner->{'acl'}->{'max_'.$l};
	}
foreach my $s (&get_owner_servers($owner)) {
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

	# Add bandwidth usage
	$rv->{'bw'} += $s->{'bw_usage'};

	# Add IP usage
	$rv->{'ips'} += scalar(split(/\s+/, $s->{'ip_addresses'}));
	}

# Owner's backup usage is set by space.pl
$rv->{'space'} = $owner->{'acl'}->{'backup_size'};
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

# get_owner_servers(&owner)
# Returns the server hash refs for some owner
sub get_owner_servers
{
my ($owner) = @_;
my %owned = map { $_, 1 } split(/\s+/, $owner->{'acl'}->{'servers'});
return grep { $owned{$_->{'id'}} } &list_managed_servers();
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
	# Create default plan
	push(@rv, { 'id' => 1,
		    'default' => 1,
		    'desc' => $text{'plans_defplan'},
		    'max_servers' => 5,
		    'max_ram' => 1024*1024*1024,
		    'max_disk' => 10*1024*1024*1024,
		    'types' => join(' ', @virtual_server_management_types),
		    'actions' => join(' ', &list_safe_owner_actions()),
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
&lock_file("$owner_plans_dir/$plan->{'id'}");
&write_file("$owner_plans_dir/$plan->{'id'}", $plan);
&unlock_file("$owner_plans_dir/$plan->{'id'}");
}

# delete_plan(&delete)
# Delete an existing plan
sub delete_plan
{
my ($plan) = @_;
&unlink_logged("$owner_plans_dir/$plan->{'id'}");
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
foreach my $l (@plan_limit_types) {
	if (!$o->{'acl'}->{'custom_'.$l}) {
		$o->{'acl'}->{'max_'.$l} = $plan->{'max_'.$l};
		}
	}
$o->{'acl'}->{'types'} = $plan->{'types'};
if ($o->{'acl'}->{'actions_def'}) {
	$o->{'acl'}->{'actions'} = $plan->{'actions'};
	}
$o->{'acl'}->{'hosts'} = $plan->{'hosts'};
$o->{'acl'}->{'hostmode'} = $plan->{'hostmode'};
$o->{'acl'}->{'images'} = $plan->{'images'};
}

# owner_limits_desc(&owner, [only-over])
# Return an HTML string describing this owner's limits
sub owner_limits_desc
{
my ($owner, $over) = @_;
my $limits = &get_owner_limits($owner->{'name'});
my @rv;
foreach my $l (@plan_limit_types) {
	my $msg = $limits->{'max_'.$l};
	if ($msg) {
		if (&indexof($l, @nice_plan_limit_types) >= 0) {
			$msg = &nice_size($msg);
			}
		$msg = &text('limit_'.$l, $msg);
		if ($limits->{$l} > $limits->{'max_'.$l}) {
			$msg = "<font color=red>$msg</font>";
			}
		elsif ($over) {
			next;
			}
		push(@rv, $msg);
		}
	}
return join(', ', @rv) || $text{'owners_nolimits'};
}

# grant_to_system_owner(&owner, &server)
# Add some system to the list of those managed by some owner, and save him
sub grant_to_system_owner
{
my ($owner, $server) = @_;
$owner->{'acl'}->{'servers'} =
	join(' ', &unique(split(/\s+/, $owner->{'acl'}->{'servers'}),
		  	  $server->{'id'}));
&save_system_owner($owner, $owner);
}

1;

