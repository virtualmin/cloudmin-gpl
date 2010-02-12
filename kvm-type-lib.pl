# Functions for Kvm

sub type_kvm_desc
{
return $text{'kvm_typedesc'};
}

# type_kvm_parent(&server, [&all-servers])
# Returns the parent system that hosts this kvm
sub type_kvm_parent
{
my ($server, $servers) = @_;
if ($servers) {
	my ($vhost) = grep { $_->{'id'} == $server->{'kvm_on'} } @$servers;
	return $vhost;
	}
else {
	return &get_managed_server($server->{'kvm_on'});
	}
}

sub type_kvm_must_image
{
return 1;			# KVM instances always come from an image
}

sub type_kvm_can_manual_image
{
return 1;			# An image can be created from a CD or raw disk
}

sub type_kvm_is_virtual
{
return 1;
}

sub type_kvm_can_transfer
{
my ($server) = @_;
return $server->{'kvm_mount'} && !$server->{'nohost'} ||	# Via host
       $server->{'status'} eq 'nowebmin' ||	# Can transfer if SSH is up
       $server->{'status'} eq 'downwebmin' ||
       $server->{'status'} eq 'nowebminlogin' ||
       $server->{'status'} eq 'novirt' ||
       $server->{'status'} eq 'virt';
}

# Can change the password if totally down, or can SSH in
sub type_kvm_can_password
{
my ($server) = @_;
return $server->{'status'} ne 'nohost' &&
       $server->{'status'} ne 'nossh' &&
       $server->{'status'} ne 'nosshlogin';
}

# Can reset, if the host is up
sub type_kvm_can_reset
{
my ($server) = @_;
return $server->{'status'} ne 'nohost';
}

# Returns links for creating and adding kvms (if this system supports
# them, or remote systems do)
sub type_kvm_create_links
{
my @vhosts = grep { $_->{'kvm_host'} } &list_managed_servers();
my @rv;
if (@vhosts) {
	push(@rv, { 'create' => 0,
		    'desc' => $text{'kvm_addlink'} });
	my @images = &list_server_images('kvm');
	if (@images) {
		push(@rv, { 'create' => 1,
			    'desc' => $text{'kvm_createlink'} });
		}
	}
return @rv;
}

# Returns a link to the page list kvm-capable systems
sub type_kvm_global_links
{
return ( { 'link' => 'list_kvms.cgi',
	   'icon' => 'images/kvms.gif',
	   'title' => $text{'kvms_title'},
	   'cat' => 'hosts' } );
}

# can_host_kvm(&server)
# Returns 1 if some server is of a type that we can do KVM hosting on
sub can_host_kvm
{
my ($server) = @_;
return $server->{'manager'} eq 'this' || $server->{'manager'} eq 'real';
}

# type_kvm_server_actions(&server)
# Returns extra links for KVM instances
sub type_kvm_server_actions
{
my ($server) = @_;
my @rv;
if ($server->{'kvm_vnc_display'} &&
    $server->{'status'} ne 'down' && $server->{'status'} ne 'nohost' &&
    &can_action($server, "console")) {
	# KVM VNC console access link
	push(@rv, { 'id' => 'vnc',
		    'desc' => $text{'edit_vnc'},
		    'cat' => 'power',
		    'link' => "kvnc.cgi?id=$server->{'id'}" });
	}
return @rv;
}



# type_kvm_add_form()
# Returns inputs for adding an existing KVM instance. This is just a matter of
# selecting the host and the server.
sub type_kvm_add_form
{
my $rv;

# Hosting system
my @vhosts = grep { $_->{'kvm_host'} } &list_managed_servers();
$rv .= &ui_table_row($text{'add_kvmhost'},
		&ui_select("kvm_on", $vhosts[0]->{'id'},
			[ map { [ $_->{'id'}, $_->{'host'} ] } @vhosts ]));

if (@vhosts == 1) {
	# Can just show a drop-down of existing kvm instances, except those we
	# are already hosting)
	my $instances = &list_kvm_instances($vhosts[0]);
	my %already = map { $_->{'kvm_filesystem'}, $_ }
			     &list_managed_servers();
	$rv .= &ui_table_row($text{'add_kvmpid'},
	    &ui_select("kvm_pid", undef,
		[ map { [ $_->{'pid'}, $_->{'cmd'} ] }
		      grep { !$already{$_->{'filesystem'}} } @$instances] ));
	}
else {
	# Need to show kvm name field, with popup
	$rv .= &ui_table_row($text{'add_kvmpid'},
	     &ui_textbox("kvm_pid", undef, 20)." ".
	     &kvm_instance_chooser_button("kvm_pid", "kvm_on"));
	}

return $rv;
}

# type_kvm_add_parse(&server, &in)
# Parse inputs from type_kvm_add_form
sub type_kvm_add_parse
{
my ($server, $in) = @_;

# Save KVM host
$server->{'kvm_on'} = $in->{'kvm_on'};
my $vhost = &type_kvm_parent($server);

# Check and save KVM instance
my $instances = &list_kvm_instances($vhost);
$in->{'kvm_pid'} || &error($text{'add_ekvminstance'});
my ($got) = grep { $_->{'pid'} eq $in->{'kvm_pid'} } @$instances;
$got || &error(&text('add_ekvminstance2', $vhost->{'host'}));
$got->{'filesystem'} || &error($text{'add_ekvmfs'});
$server->{'kvm'} = $in->{'kvm_pid'};

# Make sure the filesystem is in usable raw format
my ($out, $ex, $err) = &execute_command_on_server($vhost, 
			"qemu-img info ".quotemeta($got->{'filesystem'}));
if ($ex || $err) {
	&error(&text('add_ekvmfile', $got->{'filesystem'}, $err || $out));
	}
elsif ($out !~ /file\s+format:\s+(\S+)/i || $1 ne "raw") {
	&error(&text('add_ekvmfile2', $got->{'filesystem'}, $1 || "unknown"));
	}

# Save root disk, RAM, disks and network
&set_kvm_attributes($server, $vhost, $got);
}

# set_kvm_attributes(&server, &vhost, &process)
# Update a KVM instance object's details from the args of a running process
sub set_kvm_attributes
{
my ($server, $vhost, $got) = @_;

# Save KVM root disk
$server->{'kvm_filesystem'} = $got->{'filesystem'};

# Save other disks
my @drives;
foreach my $dd ("a" .. "z") {
	my $dfile = $got->{'args'}->{"hd".$dd};
	if ($dfile) {
		my $idx = ord($dd) - 97;
		push(@drives, "file=$dfile,index=$idx,media=disk");
		}
	}
if ($got->{'args'}->{'cdrom'}) {
	push(@drives, "file=$got->{'args'}->{'cdrom'},index=2,media=cdrom");
	}
my @otherdrives = ref($got->{'args'}->{'drive'}) ?
			@{$got->{'args'}->{'drive'}} :
			( $got->{'args'}->{'drive'} );
push(@drives, @otherdrives);
$server->{'kvm_drives'} = join(" ", @drives);

# Save memory
$server->{'kvm_memory'} = $got->{'args'}->{'m'} || 128;

# Save TAP network interfaces
my @nets = ref($got->{'args'}->{'net'}) ? @{$got->{'args'}->{'net'}}
					: ( $got->{'args'}->{'net'} );
$server->{'kvm_net'} = join(" ", grep { /^tap/ } @nets);
}

# type_kvm_create_form()
# Returns HTML for KVM-specific inputs
sub type_kvm_create_form
{
my $rv;

# Check if any vhosts have more than one bridge
my @vhosts = grep { $_->{'kvm_host'} && &can_host_server($_) }
		     &list_managed_servers();
my $max_hostifaces = 0;
foreach my $vhost (@vhosts) {
	my @hostifaces = split(/\s+/, $vhost->{'kvm_iface'});
	if (scalar(@hostifaces) > $max_hostifaces) {
		$max_hostifaces = scalar(@hostifaces);
		}
	}

# KVM host system
my ($hostf, $hostjs);
if (@vhosts == 1 && $module_info{'onehost'} eq 'kvm') {
	# Can only be hosted locally
	$rv .= &ui_hidden("kvm_on", $vhosts[0]->{'id'});
	}
else {
	($hostf, $hostjs) = &show_host_server_field($text{'add_kvmhost'},
						   "kvm", "kvm", "host_change");
	$rv .= $hostf;
	}

# IP addresses
if (&can_action(undef, "ips")) {
	my $nm = "255.255.255.0";
	if ($max_hostifaces <= 1) {
		# No host system has more than one bridge
		$rv .= &ui_table_row($text{'create_kvmip'},
			&ui_radio("kvm_ip_def", 1,
			  [ [ 1, $text{'create_xenipauto'} ],
			    [ 0, &text('create_xenipman',
				       &ui_textbox("kvm_ip_0", undef, 20),
				       &ui_textbox("kvm_netmask_0", $nm, 15))
			    ] ]));

		# Default gateway
		$rv .= &ui_table_row($text{'create_xengw'},
			&ui_opt_textbox("kvm_gw_0", undef, 20,
					$text{'create_xengwdef'},
					$text{'create_xengwip'}));
		}
	else {
		# Some hosts have more than one .. need to make IP allocation
		# section dynamic
		my $itable;
		$itable .= "<style>\n";
		$itable .= ".opener_shown {display:inline}\n";
		$itable .= ".opener_hidden {display:none}\n";
		$itable .= "</style>\n";
		$itable .= &ui_hidden("kvm_max_hostifaces", $max_hostifaces);

		# Add a hidden section for each host, with a row for each
		# of its interfaces
		my @locs = &list_vhost_locations(\@vhosts);
		my $style = @locs ? "opener_hidden" : "opener_shown";
		foreach my $vhost (@vhosts) {
			my $vtable = &ui_columns_start([
				$text{'create_xenifacecol'},
				$text{'create_xenipcol'},
				$text{'create_xennetmaskcol'},
				$text{'create_xengwcol'}]);
			my @ifaces = split(/\s+/, $vhost->{'kvm_iface'});
			if (!@ifaces) {
				@ifaces = ( $text{'create_xenifacedef'} );
				}
			my $id = $vhost->{'id'};
			for(my $i=0; $i<@ifaces; $i++) {
				$vtable .= &ui_columns_row([
				  $ifaces[$i],
				  &ui_textbox("${id}_kvm_ip_$i", undef, 15),
				  &ui_textbox("${id}_kvm_netmask_$i", $nm, 15),
				  &ui_opt_textbox("${id}_kvm_gw_$i", undef, 15,
						  $text{'create_xengwdef'}),
				  ]);
				}
			$vtable .= &ui_columns_end();
			$itable .= "<div style=$style ".
				   "id=$vhost->{'id'}>".$vtable."</div>\n";
			}

		# Add a section for when a location group is chosen, if any.
		# This has a row for every possible bridge.
		if (&can_select_host_location() && @locs) {
			my $vtable = &ui_columns_start([
				$text{'create_xenifacecol'},
				$text{'create_xenipcol'},
				$text{'create_xennetmaskcol'},
				$text{'create_xengwcol'}]);
			for(my $i=0; $i<$max_hostifaces; $i++) {
				$vtable .= &ui_columns_row([
				  &text('create_xenbr', $i),
				  &ui_textbox("loc_kvm_ip_$i", undef, 15),
				  &ui_textbox("loc_kvm_netmask_$i", $nm, 15),
				  &ui_opt_textbox("loc_kvm_gw_$i", undef, 15,
						  $text{'create_xengwdef'}),
				  ]);
				}
			$vtable .= &ui_columns_end();
			$itable .= "<div style=opener_shown ".
				   "id=loc>".$vtable."</div>\n";
			}

		$rv .= &ui_table_row($text{'create_kvmip2'},
			&ui_radio("kvm_ip_def", 1,
				  [ [ 1, $text{'create_xenipauto'} ],
				    [ 0, $text{'create_xenipman2'}."<br>\n".
					 $itable ] ]));

		# Javascript for host change
		$rv .= "<script>\n";
		$rv .= "function host_change(id)\n";
		$rv .= "{\n";
		foreach my $vhost (@vhosts) {
			$rv .= "var divobj = ".
			       "document.getElementById('$vhost->{'id'}');\n";
			$rv .= "divobj.className = id == '$vhost->{'id'}' ? ".
			       "'opener_shown' : 'opener_hidden';\n";
			}
		$rv .= "var divobj = document.getElementById('loc');\n";
		$rv .= "if (divobj) {\n";
		$rv .= "    divobj.className = id == 'loc' ? 'opener_shown' : ".
		       "'opener_hidden';\n";
		$rv .= "    }\n";
		$rv .= "}\n";
		$rv .= $hostjs;
		$rv .= "</script>\n";
		}
	}

return $rv;
}

# type_kvm_limits_create_form()
# Returns HTML for KVM-specific inputs related to RAM and disk
sub type_kvm_limits_create_form
{
my $rv;

# Physical memory
my $limits = defined(&get_owner_limits) ? &get_owner_limits() : undef;
my $defmem = $config{'kvm_mem'}*1024*1024;
my $mem = $defmem;
if ($limits && $limits->{'max_ram'}) {
	$mem = $limits->{'max_ram'} - $limits->{'ram'};
	$mem = $defmem if ($mem > $defmem);
	$mem = 128*1024*1024 if ($ram < 128*1024*1024);
	}
$rv .= &ui_table_row($text{'create_xenmemory'},
	&ui_textbox("kvm_memory", int($mem/(1024*1024)), 8)." MB");

# Filesystem size
$rv .= &ui_table_row($text{'create_xendisksize'},
	&ui_opt_textbox("kvm_disk", undef, 8,$text{'create_xendiskdef'})." MB");

return $rv;
}

# type_kvm_create_parse(&server, &in)
# Parse inputs from type_kvm_create_form, and update the server object
sub type_kvm_create_parse
{
my ($server, $in) = @_;

# Validate memory parameters
$in{'kvm_memory'} =~ /^\d+$/ || &error($text{'create_exenmemory'});
$server->{'kvm_memory'} = $in{'kvm_memory'};

# Validate disk size
if (!$in{'kvm_disk_def'}) {
	$in{'kvm_disk'} =~ /^\d+$/ || &error($text{'create_exendisksize'});
	$server->{'kvm_disksize'} = $in{'kvm_disk'};
	$server->{'kvm_disktotal'} = $in{'kvm_disk'}*1024*1024;
	if ($img->{'rawsize'} &&
	    $img->{'rawsize'} > $in{'kvm_disk'}*1024*1024) {
		&error(&text('create_exendisksize2',
			     &nice_size($img->{'rawsize'})));
		}
	}
else {
	my $img = &get_server_image($server->{'image'});
	$server->{'kvm_disktotal'} = $img->{'rawsize'};
	}

# Select host system
my $vhost = &parse_host_server_field($server, 'kvm', 'kvm', $in,
				     $server->{'kvm_memory'}*1024*1024,
				     $server->{'kvm_disktotal'});
$server->{'kvm_on'} = $vhost->{'id'};

# Make sure the hostname doesn't contain a ., or clashes
$in->{'host'} =~ /\./ && &error($text{'create_ekvmhost'});

if (!$in->{'kvm_ip_def'} && &can_action(undef, "ips")) {
	# Validate IP addresses
	my @allhostifaces = split(/\s+/, $vhost->{'kvm_iface'});
	if (!@allhostifaces) {
		# No host interfaces set, so just assume default
		@allhostifaces = ( '*' );
		}

	# Work out prefix for inputs
	my $pfx;
	if ($in->{'kvm_max_hostifaces'} <= 1) {
		$pfx = '';	# None needed
		}
	elsif ($in->{'kvm_def'} == 1) {
		$pfx = 'loc_';
		}
	else {
		$pfx = $vhost->{'id'}.'_';
		}

	my (@ips, @cidrs, @gws, @hostifaces);
	for(my $i=0; defined($in->{$pfx."kvm_ip_$i"}); $i++) {
		next if (!$in->{$pfx."kvm_ip_$i"});
		&check_ipaddress($in->{$pfx."kvm_ip_$i"}) ||
			&error($text{'create_ekvmip'});
		push(@ips, $in{$pfx."kvm_ip_$i"});
		&check_ipaddress($in->{$pfx."kvm_netmask_$i"}) ||
			&error($text{'iface_enetmask'});
		push(@cidrs, &net::mask_to_prefix(
				$in->{$pfx."kvm_netmask_$i"}));
		if ($in{$pfx."kvm_gw_${i}_def"}) {
			push(@gws, "*");
			}
		else {
			&check_ipaddress($in{$pfx."kvm_gw_$i"}) ||
				 &error($text{'create_exengw'});
			push(@gws, $in{$pfx."kvm_gw_$i"});
			}
		push(@hostifaces, $allhostifaces[$i]);
		}
	@ips || &error($text{'create_exenips'});
	scalar(@ips) <= scalar(@allhostifaces) ||
		&error(&text('create_exenifaces2', $vhost->{'host'},
			     scalar(@allhostifaces), scalar(@ips)));
	$server->{'kvm_hostifaces'} = join(' ', @hostifaces);
	$server->{'kvm_ip'} = join(' ', @ips);
	$server->{'kvm_cidr'} = join(' ', @cidrs);
	$server->{'kvm_gw'} = join(' ', @gws);
	}
else {
	# Allocate the IP now, by looking for one that isn't pingable or
	# use by any system
	my $err = &allocate_kvm_ip_addresses($server, $vhost);
	&error($err) if ($err);
	}

# Append zone name
my @zones = &list_bind_zones();
my $zone;
if ($vhost->{'kvm_zone'}) {
	($zone) = grep { $_->{'name'} eq $vhost->{'kvm_zone'} } @zones;
	}
if ($zone) {
	$server->{'host'} .= ".".$vhost->{'kvm_zone'};
	}
}

# type_kvm_create_args()
# Returns an array of parameters to type_kvm_create_args_parse
sub type_kvm_create_args
{
return ( { 'name' => 'host', 'value' => 'host-system' },
	 { 'name' => 'location', 'value' => 'name' },
	 { 'name' => 'ip', 'value' => 'address[,address]', 'opt' => 1 },
	 { 'name' => 'cidr', 'value' => 'number[,number]', 'opt' => 1 },
	 { 'name' => 'netmask', 'value' => 'mask,[mask]', 'opt' => 1 },
	 { 'name' => 'gw', 'value' => 'address[,address|*]', 'opt' => 1 },
	 { 'name' => 'bridge', 'value' => 'name[,name]', 'opt' => 1 },
	 { 'name' => 'disksize', 'value' => 'megabytes', 'opt' => 1 },
	 { 'name' => 'memory', 'value' => 'megabytes', 'opt' => 1 },
	 { 'name' => 'lvm', 'value' => 'true|false', 'opt' => 1 },
       );
}

# type_kvm_create_args_parse(&args, &server)
# Update a server object with parsed command-line args
sub type_kvm_create_args_parse
{
my ($args, $server) = @_;

# Validate memory flags
if ($args->{'memory'}) {
	$args->{'memory'} =~ /^\d+$/ || return "Non-numeric memory allocation";
	$server->{'kvm_memory'} = $args->{'memory'};
	}
else {
	$server->{'kvm_memory'} = $config{'kvm_mem'};
	}

# Validate filesystem size flag
if ($args->{'disksize'}) {
	$args->{'disksize'} =~ /^\d+$/ ||
		return "Non-numeric disk size";
	$server->{'kvm_disksize'} = $args->{'disksize'};
	if ($img->{'rawsize'} &&
	    $img->{'rawsize'} > $args->{'disksize'}*1024*1024) {
		return "--kvm-disksize must be at least $img->{'rawsize'} ".
		       "bytes, as that is the size of the selected image";
		}
	}
else {
	my $img = &get_server_image($server->{'image'});
	$server->{'kvm_disktotal'} += $img->{'rawsize'};
	}

# Hosting server
my $vhost;
if ($args->{'host'}) {
	# Use a specific host
	($vhost) = grep { $_->{'host'} eq $args->{'host'} }
			      &list_managed_servers();
	$vhost || return "KVM host system $args->{'host'} does not exist";
	}
elsif ($args->{'location'}) {
	# Select a host from the location
	my ($loc) = grep { $_->{'id'} eq $args->{'location'} ||
			   $_->{'desc'} eq $args->{'location'} }
			 &list_locations();
	$loc || return "Location $args->{'location'} does not exist";
	$vhost = &find_host_from_location($server, $loc, 'kvm',
					  $server->{'kvm_memory'}*1024*1024,
                                          $server->{'kvm_disktotal'});
	$vhost || return "Failed to select host system from location";
	}
else {
	# Use default host
	($vhost) = grep { $_->{'kvm_default'} } &list_managed_servers();
	$vhost || return "Missing --kvm-host";
	}
$vhost->{'kvm_host'} ||
	return "System $args->{'host'} is not registered to host KVM instances";
my ($ok, $err) = &usable_host_system($vhost, "kvm",
                                     $server->{'kvm_memory'}*1024*1024,
                                     $server->{'kvm_disktotal'});
$ok || return "Host system $vhost->{'host'} cannot be used : $err";
$server->{'kvm_on'} = $vhost->{'id'};

# Xen instance name
$server->{'host'} =~ /\./ && return "KVM hostnames cannot contain .";

if ($args->{'ip'}) {
	# Make sure IPs are valid
	&can_action(undef, "ips") ||
		return "You are not allowed to specify IP addresses";
	my @ips = split(/[, ]+/, $args->{'ip'});
	foreach my $ip (@ips) {
		&check_ipaddress($ip) || return "Invalid KVM IP address $ip";
		}
	my @cidrs;
	if ($args->{'cidr'}) {
		@cidrs = split(/[, ]+/, $args->{'cidr'});
		foreach my $cidr (@cidrs) {
			$cidr =~ /^\d+$/ && $cidr > 0 && $cidr <= 32 ||
				return "Invalid KVM CIDR $cidr";
			}
		}
	elsif ($args->{'netmask'}) {
		foreach my $nm (split(/[, ]+/, $args->{'netmask'})) {
			&check_ipaddress($nm) ||
				return "Invalid KVM netmask $nm";
			push(@cidrs, &net::mask_to_prefix($nm));
			}
		}
	else {
		return "Missing --kvm-cidr or --kvm-netmask flags";
		}
	scalar(@ips) == scalar(@cidrs) ||
		return "The number of IPs must match the number of CIDRs";
	if ($args->{'bridge'}) {
		# Bridges set explicitly
		my @hostifaces = split(/[, ]+/, $args->{'bridge'});
		scalar(@ips) == scalar(@hostifaces) ||
		    return "The number of IPs must match the number of bridges";
		$server->{'kvm_hostifaces'} = join(' ', @hostifaces);
		}
	else {
		# Automatically determine from host system
		my @hostifaces = split(/\s+/, $vhost->{'kvm_iface'});
		if (!@hostifaces) {
			# No host interfaces set, so just assume default
			$server->{'kvm_hostifaces'} = '*';
			@ips == 1 ||
			    return "Host system $vhost->{'host'} does not ".
				   "have any bridges set, so only one IP ".
				   "address can be specified";
			}
		else {
			scalar(@ips) <= scalar(@hostifaces) ||
			    return "Host system $vhost->{'host'} only has ".
				   scalar(@hostifaces)." bridges set, but you ".
				   "specified ".scalar(@ips)." IP addresses";
			$server->{'kvm_hostifaces'} =
				join(' ', @hostifaces[0..$#ips]);
			}
		}
	$server->{'kvm_ip'} = join(' ', @ips);
	$server->{'kvm_cidr'} = join(' ', @cidrs);

	# Gateway IPs
	if ($args->{'gw'}) {
		# Set on command line
		my @gws = split(/[, ]+/, $args->{'gw'});
		foreach my $gw (@gws) {
			$gw eq '*' || &check_ipaddress($gw) ||
				return "Invalid gateway IP address $gw";
			}
		scalar(@ips) == scalar(@gws) ||
		  return "The number of IPs must match the number of gateways";
		$server->{'kvm_gw'} = join(' ', @gws);
		}
	else {
		# Assume all are using default
		$server->{'kvm_gw'} = join(' ', map { "*" } @ips);
		}
	}
else {
	# Allocate IP automatically
	my $err = &allocate_kvm_ip_addresses($server, $vhost);
	&error($err) if ($err);
	}

# Adjust hostname for DNS
my @zones = &list_bind_zones();
my $zone;
if ($vhost->{'kvm_zone'}) {
	($zone) = grep { $_->{'name'} eq $vhost->{'kvm_zone'} } @zones;
	}
if ($zone) {
	$server->{'host'} .= ".".$vhost->{'kvm_zone'};
	}

# Validate LVM flag
if ($args->{'lvm'} =~ /true|yes/i) {
	$vhost->{'kvm_vg'} ||
		return "Host system $vhost->{'host'} does not use LVM";
	}
elsif ($args->{'lvm'} =~ /false|no/i) {
	$server->{'kvm_nolvm'} = 1;
	}

return undef;
}

# type_kvm_create(&server, [serial, key], [reset])
# Create a new KVM instance, by unzipping the filesystem image in the background
sub type_kvm_create
{
my ($server, $serial, $key, $reset) = @_;
my $vhost = &type_kvm_parent($server);
my $img = &get_server_image($server->{'image'});

# Create base dir if needed
if (!-d $vhost->{'kvm_dir'}) {
	&make_dir($vhost->{'kvm_dir'}, 0755, 1);
	}

# Work out the config and image file locations
my ($fsfile, $swfile, $lvmsuffix);
if ($reset) {
	# Filesystem remains the same
	$fsfile = $server->{'kvm_filesystem'};
	}
elsif ($vhost->{'kvm_vg'} && !$server->{'kvm_nolvm'}) {
	# On LVM logical volumes
	$server->{'kvm_filesystem_vg'} = $vhost->{'kvm_vg'};
	$server->{'kvm_filesystem_lv'} = $server->{'host'}.'_img';
	$server->{'kvm_filesystem_lv'} =~ s/\./_/g;
	$fsfile = "/dev/".$server->{'kvm_filesystem_vg'}."/".
		  $server->{'kvm_filesystem_lv'};
	}
else {
	# On regular files
	$fsfile = "$vhost->{'kvm_dir'}/$server->{'host'}.img";
	}
$server->{'kvm_filesystem'} = $fsfile;

# Work out interface parameters, create networking config
my @ips = split(/\s+/, $server->{'kvm_ip'});
my @ifaces = split(/\s+/, $server->{'kvm_hostifaces'});
my @gws = split(/\s+/, $server->{'kvm_gw'});
$server->{'kvm_net'} = join(" ", map { "tap" } @ips);

# Set drive in config
$server->{'kvm_drives'} = "file=$fsfile,media=disk,index=0,if=ide";

# If on an LVM, create it first
$last_remote_error = undef;
if ($server->{'kvm_filesystem_vg'}) {
	&remote_foreign_require($vhost, "lvm", "lvm-lib.pl");
	my $lv = { 'name' => $server->{'kvm_filesystem_lv'},
		   'size' => int($img->{'rawsize'}/1024) ||
			     int($server->{'kvm_disksize'}/1024) || 1024*1024,
		   'perm' => 'rw',
		   'alloc' => 'n',
		   'vg' => $server->{'kvm_filesystem_vg'} };
	if ($reset) {
		# Delete the old LV
		my $err = &remote_foreign_call($vhost, "lvm",
				     "delete_logical_volume",
				     { 'device' => $fsfile });
		$err ||= $last_remote_error;
		return "LVM logical volume deletion failed : $err" if ($err);
		}
	my $err = &remote_foreign_call($vhost, "lvm",
					  "create_logical_volume", $lv);
	$err ||= $last_remote_error;
	return "LVM logical volume creation failed : $err" if ($err);
	}

# Put the image into place, in the background
my @imgfiles = split(/\s+/, $img->{'files'});
my $imgfile = "$server->{'imagetemp'}/$imgfiles[0]";
my $temp = "/tmp/$$.$server->{'host'}.gunzip";
$server->{'kvm_temp'} = $temp;
if (!$img->{'nocompress'}) {
	# Need to un-compress the image
	my $writer = $fsfile =~ /^\/dev\// ?
			"| dd of=".quotemeta($fsfile)." bs=32768" :
			"> ".quotemeta($fsfile);
	my ($out, $ex, $err) = &execute_command_on_server($vhost,
		"(gunzip -c ".quotemeta($imgfile)." ".$writer." &&".
		" echo SERVER-MANAGER-COMPLETE || echo SERVER-MANAGER-FAILED)".
		" >$temp 2>&1 </dev/null &");
	}
else {
	my $cmd;
	if ($fsfile =~ /^\/dev\//) {
		# DD directly into LVM
		$cmd = "dd if=$imgfile of=$fsfile bs=32768";
		}
	else {
		# Can just move or copy
		$cmd = $server->{'imagelocal'} ? "cp" : "mv";
		$cmd .= " ".quotemeta($imgfile);
		$cmd .= " ".quotemeta($fsfile);
		}
	$cmd = "($cmd && echo SERVER-MANAGER-COMPLETE || echo SERVER-MANAGER-FAILED) >$temp 2>&1 </dev/null &";
	my ($out, $ex, $err) = &execute_command_on_server($vhost, $cmd);
	}

return undef;
}

# type_kvm_create_done(&server)
# Checks if the filesystem gunzip is complete, and returns OK if so.
# Returns undef if still running, or an error message on failure.
sub type_kvm_create_done
{
my ($server) = @_;
my $vhost = &type_kvm_parent($server);

# Read the gzip output file
my $data = &get_file_data_from_server($vhost, $server->{'kvm_temp'});
if ($data =~ /SERVER-MANAGER-FAILED/) {
	$data =~ s/SERVER-MANAGER-FAILED\n//;
	&execute_command_on_server($vhost,
		"rm -f ".quotemeta($server->{'kvm_temp'}));
	return "Failed to extract filesystem : $data";
	}
elsif ($data =~ /SERVER-MANAGER-COMPLETE/) {
	&execute_command_on_server($vhost,
		"rm -f ".quotemeta($server->{'kvm_temp'}));
	return "OK";
	}
else {
	return undef;
	}
}

# type_kvm_create_post(&server, [serial, key], [reset])
# Called after creation is complete. Here we can mount and fix up config
# files in the filesytem, then start the instance.
sub type_kvm_create_post
{
my ($server, $serial, $key, $reset) = @_;
my $vhost = &type_kvm_parent($server);
my @ips = split(/\s+/, $server->{'kvm_ip'});
my @cidrs = split(/\s+/, $server->{'kvm_cidr'});
my @netmasks = map { &net::prefix_to_mask($_) } @cidrs;

# Gateways can either be set per IP address, or copy from host system.
# If none are set, assume the first IP uses the host system gateway.
my $defgw = &get_server_default_gateway($vhost);
my @gws = split(/\s+/, $server->{'kvm_gw'});
my @setgws = grep { $_ ne "*" } @gws;
if (!@setgws && $defgw) {
	@gws = ( $defgw );
	}

# Expand the filesystem image, if needed
my $fsfile = $server->{'kvm_filesystem'};
if ($server->{'kvm_disksize'}) {
	my $dksize = $server->{'kvm_disksize'}*1024*1024;
	&$first_print(&text('create_xenresize', &nice_size($dksize)));
	$server->{'status'} = 'down';
	my $disks = &type_kvm_list_disks($server, 1);
	my $disk;
	if (ref($disks)) {
		($disk) = grep { $_->{'real'} eq $server->{'kvm_filesystem'} }
			       @$disks;
		}
	if (!$disk || !$disk->{'fs'}) {
		&$second_print(&text('create_exenresize2'));
		}
	else {
		my $olddisk = { %$disk };
		$disk->{'size'} = $dksize;
		my $err = &type_kvm_modify_disk($server, $disk, $olddisk);
		if ($ex) {
			&$second_print(&text('create_exenresize', $out));
			}       
		else {
			&$second_print($text{'create_done'});
			}
		}
	}

# Mount the created filesystem
&$first_print($text{'create_xenmount'});
my $err = &mount_filesystem_if_needed($server);
if ($err) {
	&$second_print(&text('create_exenmount', $err));
	return;
	}
my $mp = $server->{'kvm_mount'};
&$second_print(&text('create_xenmounted', "<tt>$mp</tt>"));

# Set the root password, by directly editing /etc/shadow
if ($server->{'ssh_pass'}) {
	&$first_print($text{'create_xensetpass'});
	my $err = &set_shadow_root_password($server, $server->{'ssh_pass'});
        if ($err) {
                &$second_print(&text('create_exensetpass', $err));
                }       
        else {
                &$second_print($text{'create_done'});
                }
	}

# Create authorized keys file
if ($server->{'key'}) {
	&$first_print($text{'create_xensetkey'});
	my $err = &create_authorized_key($server);
	&$second_print($err ? &text('create_exensetkey', $err)
			    : $text{'create_done'});
	}
else {
	&clear_authorized_key($server);
	}

# Add extra SSH keys
if (&has_addnew_keys($server)) {
	&$first_print($text{'create_xenaddnewkeys'});
	my $err = &addnew_authorized_keys($server);
	&$second_print($err ? &text('create_exenaddnewkeys', $err)
			    : $text{'create_done'});
	}

# Fix other config files that refer to the hostname or IP
&$first_print($text{'create_xenfix'});
my $fullhost = $server->{'host'};
my $shorthost = $fullhost;
$shorthost =~ s/\..*$//;
my $err = &fix_hostname_config_files($server, $ips[0],
					$shorthost, $fullhost, $vhost,
					$mp, $vhost->{'kvm_resolv'});
if ($err) {
	&$second_print(&text('create_exenfix', $err));
	}       
else {
	&$second_print($text{'create_done'});
	}

# Setup networking config files to use the IP.
&$first_print($text{'create_xennet'});
my $err = &fix_network_config_files($server, $ips[0], $netmasks[0],
				    $gws[0], $vhost, $mp);
if ($err) {
	&$second_print(&text('create_exennet', $err));
	}       
else {
	&$second_print($text{'create_done'});
	}

# Add network configs for extra IPs
if (@ips > 1) {
	&$first_print($text{'create_xennet2'});
	my $err = &fix_additional_network_interface_files($server,
		[ @ips[1..$#ips] ], [ @netmasks[1..$#netmasks] ],
		[ @gws[1..$#gws] ], $vhost, $mp);
	if ($err) {
		&$second_print(&text('create_exennet2', $err));
		}       
	else {
		&$second_print($text{'create_done'});
		}
	}

# Fix Virtualmin licence files
if ($serial) {
	&$first_print($text{'create_xenlicence'});
	my $err = &fix_virtualmin_licence_files($server, $serial, $key);
	if ($err) {
		&$second_print(&text('create_exenlicence', $err));
		}       
	else {
		&$second_print($text{'create_done'});
		}
	}

# Configure SSH to allow logins by root
&$first_print($text{'create_zonesrootssh'});
my $err = &fix_ssh_root_login($server);
if ($err eq "OK") {
	&$second_print($text{'create_zonesrootsshok'});
	}
elsif ($err eq "NONE") {
	&$second_print($text{'create_zonesrootsshnone'});
	}
elsif ($err) {
	&$second_print($err);
	}
else {
	&$second_print($text{'create_done'});
	}

# Un-mount
&$first_print($text{'create_xenumount'});
&umount_filesystem_if_needed($server);
&$second_print($text{'create_done'});

# Compute total disk size
&type_kvm_compute_disksize($server);

# Register in DNS, if we can
if ($vhost->{'kvm_zone'} && !$reset) {
	my $dnsname = $server->{'host'}.".";
	if (&add_bind8_record($dnsname, $ips[0],
			      $vhost->{'kvm_zone'})) {
		$server->{'kvm_dns'} = $dnsname;
		}
	}

# Start up the instance
&$first_print($text{'create_kvmstartup'});
my ($ok, $err) = &type_kvm_startup($server);
my $started = 0;
if ($ok != 1) {
	&$second_print(&text('create_exenstartup', $err));
	}       
else {
	&$second_print($text{'create_done'});
	$started = 1;
	}

# Import Virtualmin keys
if ($serial && $started) {
	&$first_print($text{'create_xenvkeys'});
	my $err = &fix_virtualmin_after_boot($server);
	if ($err) {
		&$second_print(&text('create_exenvkeys', $err));
		}       
	else {
		&$second_print($text{'create_done'});
		}
	}

# Regenerate SSH host key
if ($started) {
	&$first_print($text{'create_xenhostkey'});
	my $err = &regenerate_ssh_host_keys($server);
	&$second_print($err ? &text('create_exensetkey', $err)
			    : $text{'create_done'});
	}

return undef;
}

# type_kvm_reboot(&server)
# SSH in and reboot if possible, or kill and restart
sub type_kvm_reboot
{
my ($server) = @_;
my $vhost = &type_kvm_parent($server);
if (&can_ssh_status($server)) {
	# Use reboot command
	return 'FALLBACK';
	}
# Just kill and restart
&type_xen_shutdown($server, 1);
return &type_xen_startup($server);
}

# type_kvm_shutdown(&server, [force])
# SSH in and shutdown, or kill
sub type_kvm_shutdown
{
my ($server, $force) = @_;
my $vhost = &type_kvm_parent($server);
my $proc = &get_server_kvm_instance($server);
if (&can_ssh_status($server) && !$force) {
	# Try poweroff command
	my ($out, $ex, $err) = &execute_command_on_server($server,
				  "poweroff -f >/dev/null 2>&1 </dev/null &");
	return $err if ($err);
	return $out if ($ex);

	# Wait 30 seconds for shutdown
	my $tries = 0;
	while($tries < 30) {
		my ($kout, $kex) = &execute_command_on_server(
					$vhost, "kill -0 $proc->{'pid'}");
		if ($kex) {
			return undef;
			}
		sleep(1);
		$tries++;
		}
	return "Failed to shut down after 30 seconds";
	}
$proc = &get_server_kvm_instance($server);
if ($proc) {
	# Just kill it
	my ($out, $ex, $err) = &execute_command_on_server($vhost,
					"kill $proc->{'pid'}");
	return $err ? $err : $ex ? $out : undef;
	}
return "No KVM process found!";
}

# type_kvm_startup(&server)
# Start the kvm or qemu-kvm process, and wait till it responds to ping and SSH
sub type_kvm_startup
{
my ($server) = @_;
my $vhost = &type_kvm_parent($server);
my $cmd = &get_kvm_start_command($server);
my ($pinged, $sshed);

# Create a console output file
$server->{'kvm_console'} ||= &get_kvm_console_file($server);

# Run qemu-kvm to start it up, in the background
my ($out, $ex, $err) = &execute_command_on_server($vhost,
			"$cmd >$server->{'kvm_console'} 2>&1 </dev/null &");
return (0, $err) if ($err);
return (0, $out) if ($ex);

# Wait 5 seconds for it to start
my $tries = 0;
my $found = 0;
while($tries++ < 5) {
	my $proc = &get_server_kvm_instance($server);
	if ($proc) {
		$server->{'kvm'} = $proc->{'pid'};
		$found++;
		last;
		}
	sleep(1);
	$tries++;
	}

# Read the output file
my $out = &get_file_data_from_server($vhost, $server->{'kvm_console'});
if (!$found) {
	return (0, $out);
	}

# Wait up to 60 seconds for ping
$pinged = &wait_for_ping($server);

# Wait for SSH to come up
if ($pinged) {
	$sshed = &wait_for_ssh($server);
	}

# Re-check which IPs are really active
if ($sshed) {
	&compute_ip_addresses($server);
	}

# Return an error if something went wrong
if (defined($pinged) && !$pinged) {
	return (2, &text('kvm_estartping', 60));
	}
if (defined($sshed) && !$sshed) {
	return (3, &text('kvm_estartssh', 60));
	}
return (1, undef);
}

# type_kvm_get_console_output(&server)
# Returns a status code and text displayed during the KVM boot (if status is 1),
# or an error message (if 0)
sub type_kvm_get_console_output
{
my ($server) = @_;
if (!$server->{'kvm_console'}) {
	return (0, "No console messages were captured at boot time");
	}
my $vhost = &type_kvm_parent($server);
my $out = &get_file_data_from_server($vhost, $server->{'kvm_console'});
return $out ? (1, $out) : (0, "No console messages were found");
}

# type_kvm_delete(&server)
# Delete a KVM instance
sub type_kvm_delete
{
my ($server) = @_;
my $vhost = &type_kvm_parent($server);

# Force shutdown if needed
my $proc = &get_server_kvm_instance($server);
if ($proc) {
	&type_kvm_shutdown($server, 1);
	$server->{'status'} = 'down';
	}

# Delete virtual disks
my $disks = &type_kvm_list_disks($server, 0);
if (ref($disks)) {
	foreach my $d (reverse(@$disks)) {
		my @st = &stat_file_on_server($vhost, $d->{'real'});
		next if (!@st);		# Already gone
		my $err = &type_kvm_delete_disk($server, $d);
		return $err if ($err);
		}
	}

# Delete boot-time entry
&type_kvm_set_atboot($server, 0);

# Delete console file
if ($server->{'kvm_console'}) {
	&delete_file_on_server($vhost, $server->{'kvm_console'});
	}

# Remove the DNS entry, if we created one
&delete_bind8_record($server->{'kvm_dns'}, $vhost->{'kvm_zone'},
		     &to_ipaddress($server->{'host'}));

return undef;
}

# get_kvm_start_command(&server)
# Returns the full command line to start a KVM instance
sub get_kvm_start_command
{
my ($server) = @_;
my $vhost = &type_kvm_parent($server);
my $inuse = &list_ports_in_use($vhost, "tcp");
my $cmd = &find_qemu_kvm_command($vhost);

# Name flag, if supported
my ($out, $ex, $err) = &execute_command_on_server($vhost, $cmd." --help");
if ($out =~ /-name/) {
	$cmd .= " -name ".quotemeta($server->{'host'});
	}

# Memory flag
$cmd .= " -m ".$server->{'kvm_memory'};

# Add disks
foreach my $d (split(/\s+/, $server->{'kvm_drives'})) {
	if ($d =~ /^file=(\S+),media=disk,index=(\d+),if=ide$/) {
		my $n = chr($2+97);
		$cmd .= " -hd".$n." ".$1;
		}
	else {
		$cmd .= " -drive $d";
		}
	}

# Boot from disk
$cmd .= " -boot c";

# Accept TCP connection for console
#if (ref($inuse)) {
#	my $cport = 4444;
#	while(1) {
#		last if (&indexof($cport, @$inuse) < 0);
#		$cport++;
#		}
#	$server->{'kvm_cport'} = $cport;
#	$cmd .= " -serial tcp:127.0.0.1:$cport,server,nowait";
#	}

# Connect serial console to stdout
$cmd .= " -serial stdio";

# TAP networking, if enabled
foreach my $net (split(/\s+/, $server->{'kvm_net'})) {
	$cmd .= " -net $net";
	if ($net =~ /vlan=(\d+)/) {
		$cmd .= " -net nic,vlan=$1";
		}
	else {
		$cmd .= " -net nic";
		}
	}

# VNC settings, on a free port
if (ref($inuse)) {
	push(@$inuse, map { $_->{'kvm_vnc_display'}+5900 }
			  grep { $_->{'kvm_vnc_display'} &&
				 $_->{'id'} ne $server->{'id'} }
			       &list_managed_servers());
	my $vport = 5901;
	while(1) {
		last if (&indexof($vport, @$inuse) < 0);
		$vport++;
		}
	$server->{'kvm_vnc_display'} = $vport-5900;
	$cmd .= " -vnc :".$server->{'kvm_vnc_display'};
	}
else {
	$cmd .= " -nographic";
	}

return $cmd;
}

# type_kvm_can_disks(&server)
# Returns 1, as we can manage disks for Xen instances. These are files or
# devices mapped to virtual disks in the instance.
sub type_kvm_can_disks
{
my ($server) = @_;
return $server->{'status'} ne 'nohost';
}

# type_kvm_list_disks(&server, include-mounts)
# Returns a list of hash refs, one per disk, with fields :
# real - Real file on host system, like /kvm/foo.dsk
# virt - Virtual device on instance, like /dev/sda
# device - Set to 1 if this is a real device, like /dev/md1
# size - Size in bytes, if a file
# vg - LVM volume group, if any
# lv - LVM logical volume
sub type_kvm_list_disks
{
my ($server, $mounts) = @_;
my $vhost = &type_kvm_parent($server);

# If LVM is in use, get LVs from the host system
my @lvs;
if ($server->{'kvm_filesystem_vg'}) {
	if ($main::list_logical_cache{$vhost->{'id'}}) {
		@lvs = @{$main::list_logical_cache{$vhost->{'id'}}};
		}
	else {
		&remote_foreign_require($vhost, "lvm", "lvm-lib.pl");
		@lvs = &remote_foreign_call($vhost, "lvm",
			"list_logical_volumes", $server->{'kvm_filesystem_vg'});
		$main::list_logical_cache{$vhost->{'id'}} = \@lvs;
		}
	}

# Parse disks from Cloudmin config
my $idx = -1;
my @rv;
foreach my $dstr (split(/\s+/, $server->{'kvm_drives'})) {
	$idx++;
	my %drive = map { split(/=/, $_, 2) } split(/,/, $dstr);
	next if (!$drive{'file'});
	if ($drive{'if'} eq 'scsi') {
		$dev = "sd".chr($drive{'index'}+97);
		}
	elsif ($drive{'if'} eq 'ide' || !$drive{'if'}) {
		$dev = "hd".chr($drive{'index'}+97);
		}
	else {
		# Only IDE and SCSI support, not floppies/etc
		next;
		}
	my $disk = { 'real' => $drive{'file'},
		     'virt' => "/dev/".$dev,
		     'virtdev' => $dev,
		     'drive_index' => $idx };
	$disk->{'device'} = $drive{'file'} =~ /^\/dev\// ? 1 : 0;
	if (!$disk->{'device'}) {
		my @st = &stat_file_on_server($vhost, $drive{'file'});
		$disk->{'size'} = $st[7];
		}
	if ($server->{'kvm_filesystem_vg'} &&
	    $disk->{'real'} =~ /^\/dev\/(\S+)\/(\S+)$/ &&
	    $1 eq $server->{'kvm_filesystem_vg'}) {
		# Server has root on LVM .. check if this is too
		$disk->{'vg'} = $1;
		$disk->{'lv'} = $2;
		my ($lv) = grep { $_->{'name'} eq $disk->{'lv'} } @lvs;
		if ($lv) {
			$disk->{'size'} = $lv->{'size'} * 1024;
			}
		}
	$disk->{'index'} = scalar(@rv);
	push(@rv, $disk);
	}

# If the caller asked for mounts, get them too
if ($mounts) {
	# Get fstab mounts
	my $fstab = &get_system_fstab($server);
	return $fstab if (!ref($fstab));
	foreach my $d (@rv) {
		my ($f) = grep { my $v = $d->{'virt'};
				 $_->[0] =~ /^\Q$v\E(\d*)$/ } @$fstab;
		if ($f) {
			$d->{'virt_mount'} = $f->[0];
			$d->{'mount'} = $f->[1];
			$d->{'fs'} = $f->[2];
			}
		}

	# Check if actually mounted
	if (&can_ssh_status($server)) {
		my %mounted;
		my ($out, $ex, $err) =
			&execute_command_on_server($server, "mount");
		foreach my $l (split(/\r?\n/, $out)) {
			my ($dev, $on, $mp) = split(/\s+/, $l);
			$mounted{$dev} = $mp;
			}
		foreach my $d (@rv) {
			$d->{'mounted'} = $mounted{$d->{'virt'}} ||
					  $mounted{$d->{'virt_mount'}};
			}
		}
	}

# If caller asked for disk usage, get it too if we can
if ($mounts == 2 && &can_ssh_status($server)) {
	my ($out, $ex, $err) = &execute_command_on_server(
		$server, "df -k -l || df -k");
	if (!$ex && !$err) {
		foreach my $l (split(/\r?\n/, $out)) {
			my ($fs, $size, $used, $free) = split(/\s+/, $l);
			my ($disk) = grep { $_->{'virt'} eq $fs ||
					    $_->{'virt_mount'} eq $fs } @rv;
			if ($disk) {
				$disk->{'df_size'} = $size*1024;
				$disk->{'df_used'} = $used*1024;
				$disk->{'df_free'} = $free*1024;
				}
			}
		}
	}

return \@rv;
}

# type_kvm_need_disk_reboot(&server, &disk)
# A reboot is always needed, to apply the new command line
sub type_kvm_need_disk_reboot
{
my ($server, $disk) = @_;
return $server->{'status'} eq 'down' ? 0 : 1;
}

# type_kvm_new_disk(&server, &disks, real?)
# Returns a structure for a new disk on some KVM system
sub type_kvm_new_disk
{
my ($server, $disks, $device) = @_;
my $rv = { };

# Find which device files are used
my %used;
foreach my $d (@$disks) {
	$used{$d->{'virt'}}++;
	}
$used{"/dev/hdc"}++;	# Typically for CD-ROM

# Pick a /dev/???? file that is free on the virtual system
my $n;
if ($disks->[0]->{'virt'} =~ /^(\/dev\/[sh]d)[a-z]$/) {
	# System uses whole disks! Pick a free partition on the next disk
	$prefix = $1;
	for($n='a'; $used{$prefix.$n}; $n=chr(ord($n)+1)) { }
	$prefix .= $n;
	$rv->{'virt'} = $prefix;
	}
else {
	# No idea .. just guess
	$rv->{'virt'} = "/dev/hdb";
	}
$rv->{'virt_mount'} = $rv->{'virt'}."1";

if (!$device) {
	my $vhost = &type_kvm_parent($server);
	if ($server->{'kvm_filesystem_vg'}) {
		# Create an LVM name
		$rv->{'vg'} = $server->{'kvm_filesystem_vg'};
		$rv->{'lv'} = $server->{'host'}."_".(scalar(@$disks)+1)."_img";
		$rv->{'real'} = "/dev/".$rv->{'vg'}."/".$rv->{'lv'};
		}
	else {
		# Pick an image file
		$rv->{'real'} = "$vhost->{'kvm_dir'}/$server->{'host'}.".
				(scalar(@$disks)+1).".img";
		}
	}
$rv->{'device'} = $device;
return $rv;
}

# type_kvm_create_disk(&server, &disk)
# Adds a new virtual disk to a KVM system's config.
# If this is a real file that doesn't exist yet, create it and optionally mkfs
# it. Also add to the /etc/fstab file, if requested.
sub type_kvm_create_disk
{
my ($server, $disk) = @_;
my $vhost = &type_kvm_parent($server);

my @st = &stat_file_on_server($vhost, $disk->{'real'});
if ($disk->{'device'} && !$disk->{'lv'}) {
	# Check if the device exists
	@st || return "Device $disk->{'real'} does not exist ".
		      "on $vhost->{'host'}";
	}
else {
	if ($disk->{'lv'}) {
		# Create the logical volume
		$last_remote_error = undef;
		&remote_foreign_require($vhost, "lvm", "lvm-lib.pl");
		my $lv = { 'name' => $disk->{'lv'},
			   'size' => int($disk->{'size'}/1024),
			   'perm' => 'rw',
			   'alloc' => 'n',
			   'vg' => $disk->{'vg'} };
		my $err = &remote_foreign_call($vhost, "lvm",
						  "create_logical_volume", $lv);
		$err ||= $last_remote_error;
		return "LVM logical volume creation failed : $err" if ($err);
		}
	elsif (!@st) {
		# Create empty file
		$disk->{'size'} || return "File $disk->{'real'} does not exist on $vhost->{'host'}, but no size to create it as was given";
		my $cmd = "dd if=/dev/zero of=".quotemeta($disk->{'real'}).
			     " bs=1024 count=".int($disk->{'size'}/1024);
		my ($out, $ex, $err) = &execute_command_on_server(
						$vhost, $cmd);
		$err = $out if ($ex);
		$err && return "Failed to create file $disk->{'real'} : $err";
		}

	# Create the disk label with parted
	my ($out, $ex, $err) = &execute_command_on_server($vhost, 
		"parted -s ".quotemeta($disk->{'real'})." mklabel msdos");
	if ($ex || $err) {
		return "Failed to create disk label : ".($err || $out);
		}

	# Create a partition that uses all space
	my $mbs = int($disk->{'size'}/1024/1024);
	my ($out, $ex, $err) = &execute_command_on_server($vhost,
                "parted -s ".quotemeta($disk->{'real'}).
		" mkpartfs primary ext2 1 ".$mbs);
	if ($ex || $err) {
		return "Failed to create partition : ".($err || $out);
		}

	# And make a filesystem on the new partition
	if (!@st && $disk->{'fs'}) {
		my $fs = $disk->{'fs'};
		$fs = "ext2" if ($fs eq "ext3");
		$fs = "linux-swap" if ($fs eq "swap");
		my ($out, $ex, $err) = &execute_command_on_server($vhost,
			"parted -s ".quotemeta($disk->{'real'})." mkfs 1 $fs");
		if ($ex || $err) {
			return "Failed to create ".uc($disk->{'fs'}).
			       " filesystem : ".($err || $out);
			}
		}
	}

# Add the disk to the KVM config
my @drives = split(/\s+/, $server->{'kvm_drives'});
my %drive = ( 'file' => $disk->{'real'},
	      'media' => 'disk' );
if ($disk->{'virt'} =~ /sd[a-z]+$/) {
	$drive{'if'} = 'scsi';
	}
else {
	$drive{'if'} = 'ide';
	}
if ($disk->{'virt'} =~ /([hs])d([a-z])$/) {
	$drive{'index'} = ord($2)-97;
	}
push(@drives, join(",", map { $_."=".$drive{$_} } keys %drive));
$server->{'kvm_drives'} = join(" ", @drives);
&save_managed_server($server);
&type_kvm_set_atboot($server, 2);

# Add to total disk size
if ($server->{'kvm_disktotal'} ne '' && (!$disk->{'device'} || $disk->{'lv'})) {
	$server->{'kvm_disktotal'} += $disk->{'size'};
	}

# Add to /etc/fstab, if a mount point was given
my $fserr;
if ($disk->{'mount'} && $server->{'status'} ne 'alive') {
	my $err = &mount_filesystem_if_needed($server);
	return "Failed to mount filesystem : $err" if ($err);
	$err = &make_dir_on_server($server, $disk->{'mount'}, 0755, 1);
	return "Failed to create mount point : $err" if ($err);
	my $fstab = &get_system_fstab($server);
	$fserr = "Failed to read fstab file : $fstab" if (!ref($fstab));
	if (!$fserr) {
		push(@$fstab, [ $disk->{'virt_mount'}, $disk->{'mount'},
				$disk->{'fs'}, 'defaults', 0, 0 ]);
		my $err = &put_system_fstab($server, $fstab);
		$fserr = "Failed to update fstab file : $err" if ($err);
		}
	&umount_filesystem_if_needed($server);
	}

return $fserr;
}

# type_kvm_delete_disk(&server, &disk)
# Removes a disk from the Xen configuration, the system's fstab file, and
# deletes the underlying config file. The disk object must come from a call
# to type_kvm_list_disks with the mount flag set to 1.
sub type_kvm_delete_disk
{
my ($server, $disk) = @_;
my $vhost = &type_kvm_parent($server);

# Actually un-mount if mounted
if (&can_ssh_status($server) && $disk->{'mounted'}) {
	my ($out, $ex, $err) = &execute_command_on_server($server,
		"umount ".$disk->{'virt'});
	if ($err || $ex) {
		return "Failed to un-mount $disk->{'virt'} : ".
		       ($err || $out);
		}
	}

# Remove from the KVM config
my @drives = split(/\s+/, $server->{'kvm_drives'});
splice(@drives, $disk->{'drive_index'}, 1);
$server->{'kvm_drives'} = join(" ", @drives);
&save_managed_server($server);
&type_kvm_set_atboot($server, 2);

# Remove from total disk size
if ($server->{'kvm_disktotal'} ne '' && (!$disk->{'device'} || $disk->{'lv'})) {
	$server->{'kvm_disktotal'} -= $disk->{'size'};
	}

# Remove from fstab
if ($server->{'status'} ne 'alive') {
	my $fstab = &get_system_fstab($server);
	return "Failed to read fstab file : $fstab" if (!ref($fstab));
	my @newfstab = grep { $_->[0] ne $disk->{'virt_mount'} } @$fstab;
	if (scalar(@newfstab) != scalar(@$fstab)) {
		my $err = &put_system_fstab($server, \@newfstab);
		$fserr = "Failed to update fstab file : $err" if ($err);
		}
	}

if (!$disk->{'device'} && $disk->{'real'} !~ /^\/dev\//) {
	# Delete the image file
	&delete_file_on_server($vhost, $disk->{'real'});
	}
elsif ($disk->{'lv'}) {
	# Delete mapper entries for LV, if any
	my $mapper = "$disk->{'vg'}-$disk->{'lv'}";
	my $files = &list_dir_on_server($vhost, "/dev/mapper");
	if (ref($files)) {
		my @delmaps;
		foreach my $f (@$files) {
			if ($f =~ /^\Q$mapper\Ep\d+$/) {
				push(@delmaps, $f);
				}
			}
		push(@delmaps, $mapper);
		foreach my $f (@delmaps) {
			&execute_command_on_server($vhost,
				"dmsetup remove /dev/mapper/$f");
			}
		}

	# Delete the logical volume
	&remote_foreign_require($vhost, "lvm", "lvm-lib.pl");
	&remote_foreign_call($vhost, "lvm", "delete_logical_volume",
			     { 'device' => $disk->{'real'} });
	}

return undef;
}

# type_kvm_modify_disk(&server, &disk, &old-disk)
# Modifies the virtual device and size of a disk. Returns undef if OK, or an
# error message on failure.
# The disk objects *must* have the mount and fs fields set, if mounted.
sub type_kvm_modify_disk
{
my ($server, $disk, $olddisk) = @_;
my $vhost = &type_kvm_parent($server);
my $moderr;
my $parts = &list_disk_image_partitions($vhost, $disk->{'real'});

# Validate disk resizing
if ($disk->{'size'} != $olddisk->{'size'}) {
	# Only supported for ext and swap
	$disk->{'fs'} =~ /^ext\d+$/ || $disk->{'fs'} eq 'swap' ||
 	  $disk->{'fs'} eq '' ||
	    return "The size of a disk with the ".uc($disk->{'fs'}).
		   " filesystem cannot be changed";

	# Only possible if the filesystem being resized is the last one
	ref($parts) || return "Failed to list partitions : $parts";
	$disk->{'virt_mount'} =~ /\/[hs]d[a-z]+(\d+)$/ ||
		return "Un-parsable mount device!";
	my $partnum = $1;
	if ($partnum != scalar(@$parts)) {
		return "Only the last partition on a disk image can be resized";
		}
	}

# If the system is up, un-mount the disk
my $mounted = 0;
if (&can_ssh_status($server) && $olddisk->{'mounted'}) {
	my ($out, $ex, $err) = &execute_command_on_server($server,
		"umount ".$olddisk->{'virt_mount'});
	if ($err || $ex) {
		return "Failed to un-mount $olddisk->{'virt_mount'} : ".
		       ($err || $out);
		}
	$mounted = 1;
	}

# Apply a size change, if we can
if ($disk->{'size'} != $olddisk->{'size'}) {
	# Build the commands to run
	my @cmds;
	my $part = $parts->[@$parts - 1];
	if ($disk->{'lv'} && $disk->{'size'} > $olddisk->{'size'}) {
		# Expand logical volume (before filesystem)
		push(@cmds, "lvextend -L".int($disk->{'size'}/1024)."k ".
			    quotemeta($disk->{'real'}));
		}
	elsif (!$disk->{'lv'} && $disk->{'size'} > $olddisk->{'size'}) {
		# Expand the disk image (before filesystem)
		push(@cmds, "dd if=/dev/zero bs=1024".
		    " count=".int(($disk->{'size'}-$olddisk->{'size'})/1024).
		    " >>".quotemeta($disk->{'real'}));
		}

	# Work out the new filesystem size, taking into the new total disk
	# size and any preceeding partitions.
	my $newmbs = int(($disk->{'size'} -
			  $part->{'parted_start_bytes'})/1024/1024);
	$newmbs = int($newmbs / 8) * 8;

	if ($disk->{'fs'} && $disk->{'size'} < $olddisk->{'size'}) {
		# Shrink the filesystem
		push(@cmds, "losetup -o $part->{'offset'} /dev/loop9 ".
			    quotemeta($disk->{'real'}));
		push(@cmds, "e2fsck -f -p /dev/loop9");
		push(@cmds, "resize2fs /dev/loop9 ".$newmbs."M");
		push(@cmds, "losetup -d /dev/loop9");
		}

	# Delete the last partition, then re-create it
	push(@cmds, "parted -s ".quotemeta($disk->{'real'})." rm ".
		    $part->{'part'});
	push(@cmds, "parted -s ".quotemeta($disk->{'real'})." mkpart ".
		    $part->{'parted_type'}." ".
		    $part->{'parted_start'}." ".
		    int($disk->{'size'}/1000000)."M");

	if ($disk->{'fs'} && $disk->{'size'} > $olddisk->{'size'}) {
		# Expand the filesystem
		push(@cmds, "losetup -o $part->{'offset'} /dev/loop9 ".
			    quotemeta($disk->{'real'}));
		push(@cmds, "e2fsck -f -p /dev/loop9");
		push(@cmds, "resize2fs /dev/loop9 ".$newmbs."M");
		push(@cmds, "losetup -d /dev/loop9");
		}

	if (!$disk->{'lv'} && $disk->{'size'} < $olddisk->{'size'}) {
		# Truncate the file (after resizing filesystem)
		push(@cmds, "dd if=".quotemeta($disk->{'real'}).
		    " of=".quotemeta($disk->{'real'}.".tmp")." bs=1024".
		    " count=".int($disk->{'size'}/1024));
		push(@cmds, "mv ".quotemeta($disk->{'real'}.".tmp").
		    " ".quotemeta($disk->{'real'}));
		}
	elsif ($disk->{'lv'} && $disk->{'size'} < $olddisk->{'size'}) {
		# Shrink logical volume (after resizing filesystem)
		push(@cmds, "lvreduce -f -L".int($disk->{'size'}/1024)."k ".
			    quotemeta($disk->{'real'}));
		}

	# Run them in turn
	foreach my $cmd (@cmds) {
		my ($out, $ex, $err) = &execute_command_on_server(
			$vhost, $cmd);
		if ($cmd =~ /fsck/ && $ex == 1) {
			# Safe to ignore filesystem fixes
			$ex = 0;
			}
		if ($err) {
			$moderr = $err;
			last;
			}
		elsif ($ex) {
			$moderr = "$cmd failed : $out";
			last;
			}
		}

	# Always remove loopback
	&execute_command_on_server($vhost, "losetup -d /dev/loop9");

	# Update total disk size
	if (!$moderr &&
	    $server->{'xen_disktotal'} ne '' &&
	    (!$disk->{'device'} || $disk->{'lv'})) {
		$server->{'xen_disktotal'} -= $olddisk->{'size'};
		$server->{'xen_disktotal'} += $disk->{'size'};
		}
	}

if ($disk->{'virt'} ne $olddisk->{'virt'}) {
	# Change the virtual device, both in the Xen config file and fstab
	if ($olddisk->{'virt_mount'} =~ /(\d+)$/) {
		$disk->{'virt_mount'} = $disk->{'virt'}.$1;
		}

	# Fix disk in config
	my @drives = split(/\s+/, $server->{'kvm_drives'});
	my %drive = map { split(/=/, $_, 2) }
			split(/,/, $drives[$disk->{'drive_index'}]);
	if ($disk->{'virt'} =~ /([hs])d([a-z])$/) {
		$drive{'index'} = ord($2)-97;
		}
	$drives[$disk->{'drive_index'}] =
		join(",", map { $_."=".$drive{$_} } keys %drive);
	$server->{'kvm_drives'} = join(" ", @drives);
	&save_managed_server($server);
	&type_kvm_set_atboot($server, 2);

	# Update fstab, if in there
	if ($server->{'status'} ne 'alive') {
		my $fstab = &get_system_fstab($server);
		if (!ref($fstab)) {
			$moderr = "Failed to read fstab file : $fstab";
			}
		else {
			my ($f) = grep { $_->[0] eq $olddisk->{'virt_mount'} }
				       @$fstab;
			if ($f) {
				$f->[0] = $disk->{'virt_mount'};
				my $err = &put_system_fstab($server, $fstab);
				$moderr = "Failed to update fstab file : $err"
					if ($err);
				}
			}
		}
	}

# If it was mounted before, mount it now
if ($mounted && $disk->{'mount'}) {
	my ($out, $ex, $err) = &execute_command_on_server($server,
		"mount ".$disk->{'virt_mount'}." ".$disk->{'mount'});
	if ($err || $ex) {
		return "Failed to mount $disk->{'virt'} : ".($err || $out);
		}
	}

return $moderr;
}

# type_kvm_list_disk_filesystems(&server)
# Returns supported filesystem types. Assumes Linux.
sub type_kvm_list_disk_filesystems
{
return ('ext2', 'reiserfs', 'swap');
}

# Returns 2, indicating that memory can be changed but needs a reboot
sub type_kvm_can_memory
{
return 2;
}

sub type_kvm_can_unlimited_memory
{
return 0;
}

# type_kvm_get_memory(&server)
# Returns the amount of RAM in bytes this server is granted, or undef if
# not available.
sub type_kvm_get_memory
{
my ($server) = @_;
my $proc = &get_server_kvm_instance($server);
if ($proc && $proc->{'args'}->{'m'}) {
	# Get from -m flag of running process
	return $proc->{'args'}->{'m'} * 1024 * 1024;
	}
return $server->{'kvm_memory'} * 1024 * 1024;
}

# type_kvm_save_memory(&server, ram)
# Updates the memory in the Cloudmin config, and in the boot-time script
sub type_kvm_save_memory
{
my ($server, $mem) = @_;
my $mbs = int($mem/(1024*1024));
$server->{'kvm_memory'} = $mbs;
&type_kvm_set_atboot($server, 2);
return undef;
}

# type_kvm_can_interfaces(&server)
# KVM interface management is via Webmin or via SSH, so it needs to be up.
# The return value of 2 means that interfaces can also be 'real'
sub type_kvm_can_interfaces
{
my ($server) = @_;
if (&can_ssh_status($server)) {
	# Can manage via Webmin or SSH
	return 2;
	}
elsif ($server->{'status'} eq 'down' &&
       (&redhat_server_type($server) || &debian_server_type($server))) {
	# Can manage via direct file manipulation
	return 2;
	}
else {
	# Cannot edit
	return 0;
	}
}

# Regular interface IP allocation works for KVM
sub type_kvm_can_allocate_address
{
return 1;
}

# type_kvm_list_interfaces(&server)
# Returns a list of network interfaces on the system, or an error message
sub type_kvm_list_interfaces
{
my ($server) = @_;
my $rv;
if ($server->{'status'} eq 'down') {
	# Get from network config files
	my $err = &type_kvm_mount_filesystem($server);
	return "Failed to mount filesystem : $err" if ($err);
	$rv = &list_boot_server_interfaces($server);
	&type_kvm_umount_filesystem($server);
	}
else {
	# Get active interfaces
	$rv = &list_active_server_interfaces($server);
	}
if (ref($rv)) {
	$rv = [ grep { $_->{'fullname'} =~ /^eth/ &&
			 $_->{'address'} } @$rv ];
	foreach my $iface (@$rv) {
		$iface->{'nodelete'} = 1 if ($iface->{'virtual'} eq '');
		}
	}
return $rv;
}

# type_kvm_list_parent_interfaces(&server)
# Just lists non-virtual interfaces
sub type_kvm_list_parent_interfaces
{
my ($server) = @_;
my $rv = &type_kvm_list_interfaces($server);
return [ grep { $_->{'virtual'} eq '' } @$rv ];
}

# type_kvm_create_interface(&server, &iface)
# Add and activate a virtual interface
sub type_kvm_create_interface
{
my ($server, $iface) = @_;

# Find a free interface number
my $vhost = &type_kvm_parent($server);
my $ifaces = &type_kvm_list_interfaces($server);
return $ifaces if (!ref($ifaces));
my $n = 0;
foreach my $oldiface (@$ifaces) {
	if ($oldiface->{'virtual'} >= $n &&
	    $oldiface->{'name'} eq $iface->{'name'}) {
		$n = $oldiface->{'virtual'} + 1;
		}
	}
$iface->{'virtual'} = $n;
$iface->{'fullname'} = $iface->{'name'}.":".$n;

# Allocate IP, if needed
if (!$iface->{'address'}) {
	my $cidr;
	my @kvm_iface = split(/\s+/, $vhost->{'kvm_iface'});
	my $idx = $iface->{'name'} =~ /^eth(\d+)/ ? $1 : 0;
	($iface->{'address'}, $cidr) = &allocate_ip_address(
	    $vhost->{'kvm_start'}, $vhost->{'kvm_end'}, $vhost->{'kvm_cidr'},
	    $vhost->{'kvm_gws'}, $vhost->{'kvm_ifaces'}, $kvm_iface[$idx]);
	$iface->{'address'} ||
		return &text('create_ekvmalloc', $vhost->{'host'},
			    &describe_ip_range($vhost->{'kvm_start'},
					       $vhost->{'kvm_end'},
					       $vhost->{'kvm_cidr'},
					       $vhost->{'kvm_ifaces'},
					       $kvm_iface[$idx]));
	$iface->{'netmask'} = &net::prefix_to_mask($cidr);
	}

# Compute broadcast and network
$iface->{'broadcast'} = &net::compute_broadcast($iface->{'address'},
						$iface->{'netmask'});
$iface->{'network'} = &net::compute_network($iface->{'address'},
					    $iface->{'netmask'});

# Activate now if possible
if (&can_ssh_status($server)) {
	my $err = &create_active_server_interface($server, $iface);
	return $err if ($err);
	}

# Activate at boot
my $err = &mount_filesystem_if_needed($server);
return "Failed to mount filesystem : $err" if ($err);
$err = &create_boot_server_interface($server, $iface);
&umount_filesystem_if_needed($server);
return $err if ($err);

&add_ip_address($server, $iface->{'address'});
return undef;
}

# type_kvm_delete_interface(&server, &iface)
# Delete and de-activate a virtual interface
sub type_kvm_delete_interface
{
my ($server, $iface) = @_;

# Delete boot interface
my $err = &mount_filesystem_if_needed($server);
return "Failed to mount filesystem : $err" if ($err);
$err = &delete_boot_server_interface($server, $iface);
&umount_filesystem_if_needed($server);
return $err if ($err);

# De-activate interface if possible
if (&can_ssh_status($server)) {
	my $err = &delete_active_server_interface($server, $iface);
	return $err if ($err);
	}

&delete_ip_address($server, $iface->{'address'});
return undef;
}

# type_kvm_modify_interface(&server, &iface, &oldiface)
# Changes the active and boot-time IPs for an interface
sub type_kvm_modify_interface
{
my ($server, $iface, $oldiface) = @_;

# Modify boot interface
my $err = &mount_filesystem_if_needed($server);
return "Failed to mount filesystem : $err" if ($err);
$err = &modify_boot_server_interface($server, $iface, $oldiface);
&umount_filesystem_if_needed($server);
return $err if ($err);

# Change active interface if possible
if (&can_ssh_status($server)) {
	my $err = &modify_active_server_interface($server, $iface, $oldiface);
	return $err if ($err);
	}

&delete_ip_address($server, $oldiface->{'address'});
&add_ip_address($server, $iface->{'address'});
return undef;
}

# type_kvm_compute_disksize(&server)
# Sets a server's kvm_disktotal field to the total size of virtual disks,
# and returns it.
sub type_kvm_compute_disksize
{
my ($server) = @_;
if ($server->{'status'} ne 'nohost') {
	my $disks = &type_kvm_list_disks($server, 0);
	if (ref($disks)) {
		$server->{'kvm_disktotal'} = 0;
		foreach my $d (@$disks) {
			$server->{'kvm_disktotal'} += $d->{'size'}
				if (!$d->{'device'} || $d->{'lv'});
			}
		}
	}
return $server->{'kvm_disktotal'};
}

# type_kvm_get_disk_size(&server)
# Returns the cached amount of disk space allocated to this KVM instance
sub type_kvm_get_disk_size
{
my ($server) = @_;
if (!$server->{'kvm_disktotal'}) {
	&type_kvm_compute_disksize($server);
	}
return $server->{'kvm_disktotal'};
}

# type_kvm_get_disk_space(&server)
# Returns the amount of disk space used on the host by this Xen instance, which
# is the same as the disk allocated
sub type_kvm_get_disk_space
{
my ($server) = @_;
return &type_kvm_get_disk_size($server);
}

# type_kvm_need_mount(&server)
# Returns 1 if a mount call is needed before reading files from this system
sub type_kvm_need_mount
{
my ($server) = @_;
return ($server->{'status'} eq 'down' ||
	$server->{'status'} eq 'create') && !$server->{'kvm_mount'};
}

# type_kvm_get_file(&server, remotefile, localfile)
# If the filesystem for this KVM instance is locally mounted, get the file
# directly from there
sub type_kvm_get_file
{
my ($server, $remotefile, $localfile) = @_;
if ($server->{'kvm_mount'}) {
	my $vhost = &type_kvm_parent($server);
	return &get_file_from_server($vhost, $server->{'kvm_mount'}.$remotefile,
					     $localfile);
	}
else {
	return 'FALLBACK';
	}
}

# type_kvm_put_file(&server, remotefile, localfile)
# If the filesystem for this KVM instance is locally mounted, write the file
# directly to there
sub type_kvm_put_file
{
my ($server, $localfile, $remotefile) = @_;
if ($server->{'kvm_mount'}) {
	my $vhost = &type_kvm_parent($server);
	return &put_file_to_server($vhost, $localfile,
				   $server->{'kvm_mount'}.$remotefile);
	}
else {
	return 'FALLBACK';
	}
}

# type_kvm_put_multiple_files(&server, &localfiles, remotedir)
# If the filesystem for this Xen instance is locally mounted, write the file
# directly to there
sub type_kvm_put_multiple_files
{
my ($server, $localfiles, $remotedir) = @_;
if ($server->{'kvm_mount'}) {
	my $vhost = &type_kvm_parent($server);
	return &put_multiple_files_to_server($vhost, $localfiles,
				   $server->{'kvm_mount'}.$remotedir);
	}
else {
	return 'FALLBACK';
	}
}

# type_kvm_delete_file(&server, remotefile, noquote)
# If the filesystem for this KVM instance is locally mounted, delete the file
# directly from there
sub type_kvm_delete_file
{
my ($server, $remotefile, $noquote) = @_;
if ($server->{'kvm_mount'}) {
	my $vhost = &type_kvm_parent($server);
	return &delete_file_on_server($vhost,
			      $server->{'kvm_mount'}.$remotefile, $noquote);
	}
else {
	return 'FALLBACK';
	}
}

# type_kvm_checksum_file(&server, remotefile, [data-size])
# If the filesystem for this KVM instance is locally mounted, checksum the file
# directly from there
sub type_kvm_checksum_file
{
my ($server, $file, $size) = @_;
if ($server->{'kvm_mount'}) {
	my $vhost = &type_kvm_parent($server);
	return &checksum_file_on_server($vhost,
			      $server->{'kvm_mount'}.$file, $size);
	}
else {
	return ( 'FALLBACK' );
	}
}

# type_kvm_stat_file(&server, remotefile, localfile)
# If the filesystem for this KVM instance is locally mounted, stat the file
# directly from there
sub type_kvm_stat_file
{
my ($server, $remotefile) = @_;
if ($server->{'kvm_mount'}) {
	my $vhost = &type_kvm_parent($server);
	return &stat_file_on_server($vhost, $server->{'kvm_mount'}.$remotefile);
	}
else {
	return 'FALLBACK';
	}
}

# type_kvm_make_dir(&server, dir, perms, recur)
# If the filesystem for this KVM instance is locally mounted, make the dir
# directly from there
sub type_kvm_make_dir
{
my ($server, $remotedir, $perms, $recur) = @_;
if ($server->{'kvm_mount'}) {
	my $vhost = &type_kvm_parent($server);
	return &make_dir_on_server($vhost, $server->{'kvm_mount'}.$remotedir,
				   $perms, $recur);
	}
else {
	return 'FALLBACK';
	}
}

# type_kvm_list_dir(&server, dir)
# If the filesystem for this KVM instance is locally mounted, list the dir
# directly from there
sub type_kvm_list_dir
{
my ($server, $remotedir) = @_;
if ($server->{'kvm_mount'}) {
	my $vhost = &type_kvm_parent($server);
	return &list_dir_on_server($vhost, $server->{'kvm_mount'}.$remotedir);
	}
else {
	return 'FALLBACK';
	}
}

# type_kvm_mount_filesystem(&server)
# Mounts a down KVM image's root disk image on /mnt/something, and sets
# kvm_mount in the server object
sub type_kvm_mount_filesystem
{
my ($server) = @_;
my $vhost = &type_kvm_parent($server);

# Create temp dir
my $mp = "/mnt/kvm-".$server->{'host'};
my $err = &make_dir_on_server($vhost, $mp, 0700, 1);
return "Failed to create mount point $mp : $err" if ($err);
my $fsfile = $server->{'kvm_filesystem'};
if (!$fsfile) {
	return &text('create_ekvmfsfile');
	}

# If we don't know which partition is the primary, try them in series
if (!$server->{'kvm_filesystem_offset'}) {
	my $parts = &list_disk_image_partitions($vhost, $fsfile);
	if (!ref($parts)) {
		return &text('create_ekvmfsfdisk', $fsfile, $parts);
		}

	# Find Linux partitions and their offsets
	my @offsets;
	foreach my $p (@$parts) {
		if ($p->{'type'} eq '83' && $p->{'offset'}) {
			push(@offsets, $p->{'offset'});
			}
		}
	@offsets || return &text('create_ekvmfslinux', $fsfile);

	# Try each offset
	foreach my $o (@offsets) {
		my ($out, $ex, $err) = &execute_command_on_server($vhost,
			"mount -o loop,offset=$o ".quotemeta($fsfile)." ".
					 quotemeta($mp));
		next if ($ex || $err);
		my @st = &stat_file_on_server($vhost, "$mp/etc");
		if (@st) {
			# Found it! Leave mounted
			$server->{'kvm_mount'} = $mp;
			$server->{'kvm_filesystem_offset'} = $o;
			return undef;
			}
		else {
			# Un-mount and try next one
			&execute_command_on_server($vhost,
				"umount ".quotemeta($mp));
			}
		}
	return &text('create_ekvmfsnone', $fsfile);
	}

# Mount with the correct offset
my $o = $server->{'kvm_filesystem_offset'};
my ($out, $ex, $err) = &execute_command_on_server($vhost,
	"mount -o loop,offset=$o ".quotemeta($fsfile)." ".
				   quotemeta($mp));
return "Failed to mount $fsfile on $mp : $out" if ($ex);
$server->{'kvm_mount'} = $mp;
return undef;
}

# type_kvm_umount_filesystem(&server)
# Removes the mount for a system's disk image
sub type_kvm_umount_filesystem
{
my ($server) = @_;
my $vhost = &type_kvm_parent($server);
my ($out, $ex, $err) = &execute_command_on_server($vhost,
	"umount ".quotemeta($server->{'kvm_mount'}));
delete($server->{'kvm_mount'});
return undef;
}

# type_kvm_depends(&parent, &vserver)
# Returns 1 if the KVM instance hosted by the given parent
sub type_kvm_depends
{
my ($parent, $server) = @_;
return $server->{'kvm_on'} eq $parent->{'id'};
}

# type_kvm_check_login(&server)
# Check if the KVM instance is up, and if we can SSH in. Returns a status
# code and error message
sub type_kvm_check_login
{
my ($server) = @_;
my $vhost = &type_kvm_parent($server);
if (!$vhost) {
	return (5, "KVM host does not exist!");
	}
if ($vhost->{'status'} eq 'down' ||
    $vhost->{'status'} eq 'nossh' ||
    $vhost->{'status'} eq 'nohost' ||
    $vhost->{'status'} eq 'nosshlogin') {
	return (5, "KVM host $vhost->{'host'} is down");
	}
my $proc = &get_server_kvm_instance($server);
if (!$proc) {
	return (6, "KVM instance is down");
	}

# Tell check_server_ssh_login that we need to SSH
return ( );
}

# type_kvm_post_refresh(&server, regenerate)
# Called after a refresh to compute total disk size, if needed
sub type_kvm_post_refresh
{
my ($server, $regen) = @_;
if ($server->{'kvm_disktotal'} eq '' || $regen) {
	&type_kvm_compute_disksize($server);
	}
if ($server->{'status'} ne 'down' && $server->{'status'} ne 'nohost') {
	my $proc = &get_server_kvm_instance($server);
	if ($proc) {
		$server->{'kvm'} = $proc->{'pid'};
		}
	}
}

# type_kvm_post_host_refresh(&server)
# Called after a KVM host system is refreshed, to maybe get LVM info
sub type_kvm_post_host_refresh
{
my ($server) = @_;

# If using LVM, see how much space is free on the VG
if ($server->{'kvm_vg'} &&
    ($server->{'status'} eq 'virt' || $server->{'status'} eq 'novirt')) {
	&remote_foreign_require($server, "lvm", "lvm-lib.pl");
	my ($vg) = grep { $_->{'name'} eq $server->{'kvm_vg'} }
		   &remote_foreign_call($server, "lvm", "list_volume_groups");
	if ($vg) {
		$server->{'kvm_vg_total'} =
			$vg->{'pe_total'}*$vg->{'pe_size'}*1024;
		$server->{'kvm_vg_used'} =
			$vg->{'pe_alloc'}*$vg->{'pe_size'}*1024;
		$server->{'kvm_vg_free'} = $server->{'kvm_vg_total'} -
					   $server->{'kvm_vg_used'};
		}
	}
elsif (!$server->{'kvm_vg'}) {
	delete($server->{'kvm_vg_total'});
	delete($server->{'kvm_vg_used'});
	delete($server->{'kvm_vg_free'});
	}
}

# type_kvm_edit_form(&server)
# Show information about some Xen system
sub type_kvm_edit_form
{
my ($server) = @_;
my $rv;

# Hosted on
my $vhost = &type_kvm_parent($server);
$rv .= &ui_table_row($text{'edit_kvmhost'},
	&can_action($vhost, "view") ?
	     "<a href='edit_serv.cgi?id=$vhost->{'id'}'>$vhost->{'host'}</a>" :
	     $vhost->{'host'});

# KVM process ID
my $proc = &get_server_kvm_instance($server);
if ($proc) {
	$rv .= &ui_table_row($text{'edit_kvmpid'}, $proc->{'pid'});
	}

return $rv;
}

# type_kvm_server_info(&server)
# Returns an array of information for list-systems.pl to display
sub type_kvm_server_info
{
my ($server) = @_;
my @rv;
my $vhost = &type_kvm_parent($server);
push(@rv, [ "Hosted on", $vhost->{'host'} ]);
my $proc = &get_server_kvm_instance($server);
if ($proc) {
	push(@rv, [ "KVM process ID", $proc->{'pid'} ]);
	}
if ($server->{'kvm_disktotal'}) {
	push(@rv, [ "KVM total disk size",
		    &nice_size($server->{'kvm_disktotal'}) ]);
	}
return @rv;
}

# type_kvm_server_host_info(&server)
# Returns an array of information for list-systems.pl to display, for a KVM
# host system
sub type_kvm_server_host_info
{
my ($server) = @_;
my @rv;      
if ($server->{'kvm_vg_total'}) {
	push(@rv, [ "LVM disk space",
		    &nice_size($server->{'kvm_vg_total'}) ]);
	push(@rv, [ "LVM disk space free",
		    &nice_size($server->{'kvm_vg_free'}) ]);
	}
return @rv;
}

# type_kvm_get_atboot(&server)
# Returns 1 if some some KVM instance is started at boot time, by looking
# for a line that starts it in /etc/init.d/cloudmin-kvm or /etc/rc.local
sub type_kvm_get_atboot
{
my ($server) = @_;
my $vhost = &type_kvm_parent($server);
my $bfile;
if (&stat_file_on_server($vhost, "/etc/init.d")) {
	# Use init script
	$bfile = "/etc/init.d/cloudmin-kvm";
	}
else {
	$bfile = "/etc/rc.local";
	}
my $data = &get_file_data_from_server($vhost, $bfile);
foreach my $l (split(/\r?\n/, $data)) {
	my $kvm = &parse_kvm_start_command($l);
	if ($kvm && $kvm->{'filesystem'} eq $server->{'kvm_filesystem'}) {
		return 1;
		}
	}
return 0;
}

# type_kvm_set_atboot(&server, 0=no, 1=yes, 2=update-if-there)
# Enable some KVM system at boot time, by adding a line to run it to
# /etc/init.d/cloudmin-kvm or /etc/rc.local
sub type_kvm_set_atboot
{
my ($server, $atboot) = @_;
my $vhost = &type_kvm_parent($server);
$server->{'kvm_console'} ||= &get_kvm_console_file($server);
my $cmd = &get_kvm_start_command($server).
	  " >$server->{'kvm_console'} 2>&1 </dev/null &";
my $temp = &transname();
if (&stat_file_on_server($vhost, "/etc/init.d")) {
	# Insert into init script
	my $bfile = "/etc/init.d/cloudmin-kvm";
	if (&stat_file_on_server($vhost, $bfile)) {
		# File already exists
		my $err = &get_file_from_server($vhost, $bfile, $temp);
		return "Failed to read $bfile : $err" if ($err);
		}
	else {
		# Use template init script
		&copy_source_dest("$module_root_directory/cloudmin-kvm-init",
				  $temp);
		}

	# Check if already in startup script
	my $lref = &read_file_lines($temp);
	my $lnum;
	for(my $i=0; $i<@$lref; $i++) {
		my $kvm = &parse_kvm_start_command($lref->[$i]);
		if ($kvm &&
		    $kvm->{'filesystem'} eq $server->{'kvm_filesystem'}) {
			$lnum = $i;
			last;
			}
		}

	if ($atboot == 1 && !defined($lnum)) {
		# Insert startup line into script
		for(my $i=0; $i<@$lref; $i++) {
			if ($lref->[$i] =~ /^(\s*);;/ ||
			    $lref->[$i] =~ /^(\s*)RETVAL=/) {
				# Found end of start section .. add it
				splice(@$lref, $i, 0, $1.$cmd);
				last;
				}
			}
		}
	elsif ($atboot == 0 && defined($lnum)) {
		# Delete line from script
		splice(@$lref, $lnum, 1);
		}
	elsif ($atboot == 2 && defined($lnum)) {
		# Update line in script
		$lref->[$lnum] =~ s/\S.*$//;
		$lref->[$lnum] .= $cmd;
		}
	&flush_file_lines($temp);
	$err = &put_file_to_server($vhost, $temp, $bfile);
	return "Failed to save $bfile : $err" if ($err);

	# Make sure it is started at boot
	my ($out, $ex, $err) = &execute_command_on_server($vhost,
	    "chkconfig cloudmin-kvm on || update-rc.d cloudmin-kvm defaults");
	return $err ? $err : $ex ? $out : undef;
	}
else {
	# Add to end of rc.local file
	my $bfile = "/etc/rc.local";
	my $err = &get_file_from_server($vhost, $bfile, $temp);
	return $err if ($err);

	# Check if already in rc.local file
	my $lref = &read_file_lines($temp);
	my $lnum;
	for(my $i=0; $i<@$lref; $i++) {
		my $kvm = &parse_kvm_start_command($lref->[$i]);
		if ($kvm &&
		    $kvm->{'filesystem'} eq $server->{'kvm_filesystem'}) {
			$lnum = $i;
			last;
			}
		}

	# Add or remove if needed
	if ($atboot == 1 && !defined($lnum)) {
		# Add at end
		push(@$lref, $cmd);
		}
	elsif ($atboot == 0 && defined($lnum)) {
		# Remove from script
		splice(@$lref, $lnum, 1);
		}
	elsif ($atboot == 2 && defined($lnum)) {
		# Update if there
		$lref->[$lnum] = $cmd;
		}
	&flush_file_lines($temp);
	$err = &put_file_to_server($vhost, $temp, $bfile);
	return $err;
	}
}

# type_kvm_create_image(&server, &image, tempdir, [nomunge])
# Convert a KVM system into an image file, which is really just the KVM disk.
# Outputs text, and returns 0 on failure.
sub type_kvm_create_image
{
my ($server, $image, $tempdir, $nomunge) = @_;
my $vhost = &type_kvm_parent($server);

# Mount the disk image
&$first_print($text{'mkimage_kvmmount'});
my $fsfile = $server->{'kvm_filesystem'};
my $err = &type_kvm_mount_filesystem($server);
if ($err) {
	&$second_print(&text('create_exenmount', $err));
	return 0;
	}
&$second_print(&text('create_xenmounted', "<tt>$server->{'kvm_mount'}</tt>"));

if ($nomunge != 1) {
	# Munge some or all files
	my ($mok, $munged) = &munge_all_files($server, 0, $nomunge == 2);
	return 0 if (!$mok);
	$server->{'munged'} = $munged;
	}

# Un-mount
&$first_print($text{'mkimage_kvmumount'});
&type_kvm_umount_filesystem($server);
&$second_print($text{'create_done'});

# Get the size of the raw disk
my $disks = &type_kvm_list_disks($server, 0);
my $rawsize;
if (ref($disks)) {
	my ($d) = grep { $_->{'real'} eq $fsfile } @$disks;
	if ($d) {
		$rawsize = $d->{'size'};
		}
	}
if (!$rawsize) {
	my @st = &stat_file_on_server($vhost, $fsfile);
	$rawsize = $st[7];
	}
$image->{'rawsize'} = $rawsize;

if (!$image->{'nocompress'}) {
	# Compress disk image to a temp file
	&$first_print($text{'mkimage_xengzip'});
	my $gzfile = $image->{'id'}.".ext3.gz";
	my ($out, $ex, $err) = &execute_command_on_server($vhost,
	    ($server->{'kvm_filesystem_lv'} ?
		"dd if=".quotemeta($fsfile)." bs=32768 | gzip -c" :
		"gzip -c ".quotemeta($fsfile)).
	    	  " >".quotemeta("$tempdir/$gzfile"));
	if ($ex) {
		&$second_print(&text('mkimage_ekvmgzip', "<pre>$out</pre>"));
		}
	else {
		&$second_print($text{'create_done'});
		$image->{'files'} = $gzfile;
		}
	}
else {
	# Just use the image file as-is
	&$first_print($text{'mkimage_xengzip2'});
	my $imgfile = $image->{'id'}.".ext3";
	my ($out, $ex, $err) = &execute_command_on_server($vhost,
		$server->{'kvm_filesystem_lv'} ?
			"dd if=".quotemeta($fsfile).
			  " of=".quotemeta("$tempdir/$imgfile")." bs=32768" :
			"ln -s ".quotemeta($fsfile)." ".
			  quotemeta("$tempdir/$imgfile"));
	if ($ex) {
		&$second_print(&text('mkimage_ekvmlink', "<pre>$out</pre>"));
		}
	else {
		&$second_print($text{'create_done'});
		$image->{'files'} = $imgfile;
		}
	}

return 1;
}

# type_kvm_cleanup_image(&server, &image, tempdir)
# Delete all temp files created on the host system for an image, and reverse
# any munge processes that were done to prepare the imaged system.
sub type_kvm_cleanup_image
{
my ($server, $image, $tempdir) = @_;
my $vhost = &type_kvm_parent($server);

# Remove compressed image
&$first_print($text{'mkimage_xendelete'});
my $gzfile = $image->{'id'}.".ext3.gz";
my ($out, $ex, $err) = &execute_command_on_server($vhost,
				"rm -f ".quotemeta("$tempdir/$gzfile"));
$err = $out if ($ex);
if ($err) {
	&$second_print(&text('mkimage_exendelete', $out));
	return 0;
	}
else {
	&$second_print($text{'create_done'});
	}

# Re-mount KVM filesystem
&$first_print($text{'mkimage_kvmmount'});
my $err = &type_kvm_mount_filesystem($server);
if ($err) {
	&$second_print(&text('create_ekvmmount', $err));
	return 0;
	}
&$second_print(&text('create_xenmounted', "<tt>$server->{'kvm_mount'}</tt>"));

# Undo all munged files
&unmunge_all_files($server, $server->{'munged'});
delete($server->{'munged'});

# Un-mount KVM filesystem
&$first_print($text{'mkimage_kvmumount'});
&type_kvm_umount_filesystem($server);
&$second_print($text{'create_done'});

return 1;
}

# check_kvm_host_software(&server)
# Checks if some system has the KVM software installed, and the kernel
# patch needed to use it.
sub check_kvm_host_software
{
my ($server) = @_;

# Check if linux
my ($out, $ex, $err) = &execute_command_on_server($server, "uname");
return $text{'kvm_elinux'} if ($out !~ /linux/i);

# Check commands
my $full = &find_qemu_kvm_command($server);
return &text('kvm_ewhich2', "<tt>qemu-kvm</tt>", "<tt>kvm</tt>") if (!$full);
&has_command_on_server($server, "qemu-img") ||
	return &text('kvm_ewhich', "<tt>qemu-img</tt>");
&has_command_on_server($server, "parted") ||
	return &text('kvm_ewhich', "<tt>parted</tt>");

if (!$config{'kvm_qemu'}) {
	# Check CPU
	my ($out, $ex, $err) = &execute_command_on_server($server,
		"cat /proc/cpuinfo");
	if ($out !~ /flags\s*:\s*.*(vmx|svm)/) {
		return $text{'kvm_ecpu'};
		}

	# Check kernel
	my ($out, $ex, $err) = &execute_command_on_server($server,
					"test -e /dev/kvm");
	return $text{'kvm_ekernel'} if ($ex);
	}

return undef;
}

# find_qemu_kvm_command(&vhost)
# Returns the command used for running qemu on some system
sub find_qemu_kvm_command
{
my ($vhost) = @_;
foreach my $c ("kvm", "qemu-kvm", "/usr/libexec/qemu-kvm") {
	my $path = &has_command_on_server($vhost, $c);
	return $path if ($path);
	}
return undef;
}

sub type_kvm_can_backup
{
return 1;
}

# type_kvm_backup_system(&server, dest, shutdown, owner-name)
# Backup a single KVM instance to the given destination, and return a backup
# status hash ref.
sub type_kvm_backup_system
{
my ($server, $deststr, $shutdown, $owner) = @_;
my $vhost = &get_parent_server($server);
my $dest = &parse_backup_destination($deststr);
my $destserver = &get_backup_dest_server($dest, $vhost);
if ($destserver && $destserver->{'id'} eq $vhost->{'id'}) {
	$dest->{'mode'} = 1;
	}

# Pick a temp file on the host system, if needed
my $tarfile;
if ($dest->{'mode'} == 1) {
	# Target is on host already
	$tarfile = $dest->{'path'};
	}
elsif (&can_transfer_directly($dest)) {
	# Transferring directly to dest host
	if (!$destserver) {
		return { 'ok' => 0, 'msg' => $text{'brun_edestserver'} };
		}
	$tarfile = undef;
	}
else {
	# Pick temp file for tar.gz
	$tarfile = &tempname_on_server($vhost, $server->{'host'}.'.tar.gz');
	if (!$tarfile) {
		return { 'ok' => 0,
			 'msg' => &text('brun_etemp', $vhost->{'host'}) };
		}
	}

# Get disk list
my $disks = &type_kvm_list_disks($server, 0);
if (!ref($disks)) {
	return { 'ok' => 0,
		 'msg' => &text('brun_edisks', $disks) };
	}
my @lvmdisks = grep { $_->{'lv'} } @$disks;
my @filedisks = grep { !$_->{'device'} } @$disks;

# Create temp dir for LVM images, if needed
my $tempdir;
if ($server->{'kvm_filesystem_lv'}) {
	&remote_foreign_require($vhost, "lvm", "lvm-lib.pl");
	$tempdir = &tempname_on_server($vhost);
	if (!$tempdir) {
		return { 'ok' => 0,
			 'msg' => &text('brun_etemp', $vhost->{'host'}) };
		}
	my $err = &make_dir_on_server($vhost, $tempdir, 0700, 1);
	if ($err) {
		return { 'ok' => 0, 'msg' => &text('brun_emktemp',
					$vhost->{'host'}, $err) };
		}
	}

# Check if LVM on source is clustered
my $clusterlvm;
if ($server->{'kvm_filesystem_lv'} && $server->{'status'} ne 'down' &&
    @lvmdisks) {
	my ($out, $ex, $err) = &execute_command_on_server($vhost,
				"vgdisplay ".$lvmdisks[0]->{'vg'});
	if ($out =~ /Clustered\s+yes/i) {
		$clusterlvm = 1;
		}
	}

# If on LVM and we are not shutting down, take an LVM snapshot of each disk
my @snaps;
if ($server->{'kvm_filesystem_lv'} && $server->{'status'} ne 'down' &&
    !$clusterlvm) {
	&$first_print(&text('brun_snapshot', $server->{'host'}));
	foreach my $d (@lvmdisks) {
		my $snaplv = { 'size' => int(($d->{'size'}/10)/1024),
			       'is_snap' => 1,
			       'snapof' => $d->{'lv'},
			       'name' => $d->{'lv'}.'_cloudmin_snap',
			       'vg' => $d->{'vg'},
			       'perm' => 'rw',
			       'alloc' => 'n', };
		$snaplv->{'device'} = '/dev/'.$snaplv->{'vg'}.'/'.
				      $snaplv->{'name'};
		$last_remote_error = undef;
		my $err = &remote_foreign_call($vhost, "lvm",
					  "create_logical_volume", $snaplv);
		$err ||= $last_remote_error;
		if ($err) {
			return { 'ok' => 0,
				 'msg' => &text('brun_esnap',
						$d->{'real'}, $err) };
			}
		push(@snaps, $snaplv);
		}
	}

if ($server->{'kvm_filesystem_lv'}) {
	# On LVM, copy each disk into temp files and then tar up
	my @lvmdevs;
	if (@snaps) {
		@lvmdevs = map { $_->{'device'} } @snaps;
		}
	else {
		@lvmdevs = map { $_->{'real'} } @lvmdisks;
		}

	# DD into temp dir
	&$first_print(&text('brun_dd', $server->{'host'}));
	foreach my $dev (@lvmdevs) {
		my $devfile = $dev;
		$devfile =~ s/^(.*)\///;
		$devfile =~ s/_cloudmin_snap$//;
		my ($out, $ex, $err) = &execute_command_on_server($vhost,
			"dd if=$dev of=$tempdir/$devfile bs=32768 2>&1");
		if ($ex || $err) {
			$ddfail = &text('brun_edd', $dev, $err || $out);
			last;
			}
		}

	# Tar up temp dir
	if (!$ddfail && $tarfile) {
		# To temp file
		&$first_print(&text('brun_tarring3', $server->{'host'}));
		my ($out, $ex, $err) = &execute_command_on_server($vhost,
			"cd ".quotemeta($tempdir)." && ".
			"tar cf - . | gzip -c >".quotemeta($tarfile));
		if ($ex || $err) {
			$err = $out if ($ex);
			$ddfail = &text('brun_etar',
					"<tt>".&html_escape($out)."</tt>");
			}
		}
	elsif (!$ddfail) {
		# Via direct SSH
		&$first_print(&text('brun_tarring6', $server->{'host'},
					$destserver->{'host'}));
		my $tarcmd = "cd ".quotemeta($tempdir)." && ".
			     "tar cf - . | gzip -c";
		my $err = &pipe_command_to_server($vhost, $destserver, $tarcmd,
                                                  $dest->{'path'});
		if ($err) {
			return { 'ok' => 0,
				 'msg' => &text('brun_etar',
					"<tt>".&html_escape($err)."</tt>") };
			}
		}

	# Remove temp dir of DD images
	&delete_file_on_server($vhost, $tempdir);

	# Close Webmin session, as it may have timed out
	&remote_finished();

	# Remove any snapshots we created
	if (@snaps) {
		&$first_print(&text('brun_unsnapshot', $server->{'host'}));
		&remote_foreign_require($vhost, "lvm", "lvm-lib.pl");
		foreach my $snaplv (@snaps) {
			&remote_foreign_call($vhost, "lvm",
					     "delete_logical_volume", $snaplv);
			}
		}

	if ($ddfail) {
		return { 'ok' => 0, 'msg' => $ddfail };
		}
	}
else {
	# Work out which disks are regular files, and get relative paths
	if (!@filedisks) {
		return { 'ok' => 0,
			 'msg' => &text('brun_efiledisks') };
		}
	my $dir = $filedisks[0]->{'real'};
	$dir =~ s/\/[^\/]+$//;
	my @paths;
	foreach my $d (@filedisks) {
		if ($d->{'real'} =~ /^\Q$dir\E\/(\S+)$/) {
			push(@paths, $1);
			}
		}

	if ($tarfile) {
		# Run tar and gzip on all of them, into temp file
		&$first_print(&text('brun_tarring2', $server->{'host'}, $dir));
		my ($out, $ex, $err) = &execute_command_on_server($vhost,
			"cd ".quotemeta($dir)." && ".
			"tar cf - ".join(" ", map { quotemeta($_) } @paths).
			" | gzip -c >".quotemeta($tarfile));
		if ($ex || $err) {
			$err = $out if ($ex);
			return { 'ok' => 0,
				 'msg' => &text('brun_etar',
					"<tt>".&html_escape($out)."</tt>") };
			}
		}
	else {
		# Run tar and gzip piped into SSH on the target system
		&$first_print(&text('brun_tarring5', $server->{'host'}, $dir,
						     $destserver->{'host'}));
		my $tarcmd = "cd ".quotemeta($dir)." && ".
                        "tar cf - ".join(" ", map { quotemeta($_) } @paths).
                        " | gzip -c";
		my $err = &pipe_command_to_server($vhost, $destserver, $tarcmd,
						  $dest->{'path'});
		if ($err) {
			return { 'ok' => 0,
				 'msg' => &text('brun_etar',
					"<tt>".&html_escape($err)."</tt>") };
			}
		}
	}

# Get the size
my @st;
if ($tarfile) {
	@st = &stat_file_on_server($vhost, $tarfile);
	if (!@st || !$st[7]) {
		return { 'ok' => 0,
			 'msg' => &text('brun_estat', $tarfile) };
		}
	}
else {
	@st = &stat_file_on_server($destserver, $dest->{'path'});
	if (!@st || !$st[7]) {
		return { 'ok' => 0,
			 'msg' => &text('brun_estat', $dest->{'path'}) };
		}
	}
my $size = $st[7];

# Transfer to the destination, if needed
if ($dest->{'mode'} != 1 && $tarfile) {
	# Check if size would exceed limits
	my $err = &check_backup_dest_size($server, $dest, $size, $owner);

	if (!$err) {
		# Send via SCP or FTP
		&$first_print(&text('brun_sending', $server->{'host'},
					    &nice_backup_destination($dest)));
		$err = &send_to_backup_dest($vhost, $tarfile, $dest);
		}

	# Delete from host
	&delete_file_on_server($vhost, $tarfile);

	if ($err) {
		return { 'ok' => 0,
			 'msg' => &text('brun_esend', $err) };
		}
	}

# Return status
return { 'ok' => 1,
	 'size' => $size };
}

# type_kvm_restore_system(&server, dest, shutdown)
# Restore single KVM instance from the given destination, and return a backup
# status hash ref.
sub type_kvm_restore_system
{
my ($server, $deststr) = @_;
my $vhost = &get_parent_server($server);
my $dest = &parse_backup_destination($deststr);
my $destserver = &get_backup_dest_server($dest, $vhost);
if ($destserver && $destserver->{'id'} eq $vhost->{'id'}) {
	$dest->{'mode'} = 1;
	}

# Pick a temp file on the host system, if needed
my $tarfile;
if ($dest->{'mode'} == 1) {
	# Source file is on host already
	$tarfile = $dest->{'path'};
	}
elsif (&can_transfer_directly($dest)) {
	# Transferring directly from source host
	$tarfile = undef;
	}
else {
	# Pick temp file for tar
	$tarfile = &tempname_on_server($vhost, $server->{'host'}.'.tar.gz');
	if (!$tarfile) {
		return { 'ok' => 0,
			 'msg' => &text('brun_etemp', $vhost->{'host'}) };
		}
	}

# Get disk list
my $disks = &type_kvm_list_disks($server, 0);
if (!ref($disks)) {
        return { 'ok' => 0,
                 'msg' => &text('brun_edisks', $disks) };
        }
my @lvmdisks = grep { $_->{'lv'} } @$disks;
my @filedisks = grep { !$_->{'device'} } @$disks;
if ($server->{'kvm_filesystem_lv'}) {
	if (!@lvmdisks) {
		return { 'ok' => 0,
			 'msg' => &text('brun_elvmdisks') };
		}
	}
else {
	if (!@filedisks) {
		return { 'ok' => 0,
			 'msg' => &text('brun_efiledisks') };
		}
	}

# Copy in the tar.gz backup file, if needed
if ($dest->{'mode'} != 1 && $tarfile) {
        &$first_print(&text('rrun_getting', $server->{'host'},
                                            &nice_backup_destination($dest)));
        my $err = &get_from_backup_dest($vhost, $tarfile, $dest);
        if ($err) {
                return { 'ok' => 0,
                         'msg' => &text('rrun_eget', $err) };
                }
        }

# Get size, either from temp tar file or source
my @st;
if ($tarfile) {
	@st = &stat_file_on_server($vhost, $tarfile);
	if (!@st || !$st[7]) {
		return { 'ok' => 0,
			 'msg' => &text('rrun_estat', $tarfile) };
		}
	}
else {
	@st = &stat_file_on_server($destserver, $dest->{'path'});
	if (!@st || !$st[7]) {
		return { 'ok' => 0,
			 'msg' => &text('rrun_estat', $dest->{'path'}) };
		}
	}
my $size = $st[7];

my $tarerr;
if ($server->{'kvm_filesystem_lv'}) {
	# Overwrite logical volumes with tar piped into DD
	if ($tarfile) {
		# From temp tar file
		&$first_print(&text('rrun_dd', $server->{'host'}));
		foreach my $d (@lvmdisks) {
			my $devfile = $d->{'real'};
			$devfile =~ s/^(.*)\///;
			my ($out, $ex, $err) = &execute_command_on_server(
				$vhost,
				"gunzip -c ".quotemeta($tarfile).
				" | tar Oxpf - $devfile ./$devfile".
				" | dd of=$d->{'real'} bs=32768 2>&1");
			if ($ex || $err) {
				$tarerr = &text('rrun_edd', $dev, $err || $out);
				last;
				}
			}
		}
	else {
		# From tar via SSH
		&$first_print(&text('rrun_dd2', $server->{'host'},
				    $destserver->{'host'}));
		foreach my $d (@lvmdisks) {
			my $devfile = $d->{'real'};
			$devfile =~ s/^(.*)\///;
			my $tarcmd = "gunzip -c ".
				     " | tar Oxpf - $devfile ./$devfile".
				     " | dd of=$d->{'real'} bs=32768";
			my $err = &pipe_command_from_server($destserver, $vhost,
						    $tarcmd, $dest->{'path'});
			if ($err) {
				$tarerr = &text('rrun_edd', $dev, $err);
				last;
				}
			}
		}
	}
else {
	# Extract tar file of disk images in the disk base directory
	my $dir = $filedisks[0]->{'real'};
        $dir =~ s/\/[^\/]+$//;
	if ($tarfile) {
		&$first_print(&text('rrun_untarring2',
				    $server->{'host'}, $dir));
		my ($out, $ex, $err) = &execute_command_on_server($vhost,
			"cd ".quotemeta($dir)." && ".
			"gunzip -c ".quotemeta($tarfile)." | tar xpf -");
		if ($ex || $err) {
			$err = $out if ($ex);
			$tarerr = &text('rrun_etar',
					"<tt>".&html_escape($out)."</tt>");
			}
		}
	else {
		# Fetch and extract tar file in one command
		&$first_print(&text('rrun_untarring5',
			    $server->{'host'}, $dir, $destserver->{'host'}));
		my $tarcmd = "cd ".quotemeta($dir)." && ".
			     "gunzip -c | tar xpf -";
		my $err = &pipe_command_from_server($destserver, $vhost,
						    $tarcmd, $dest->{'path'});
		if ($err) {
			$tarerr = &text('rrun_etar',
					"<tt>".&html_escape($err)."</tt>");
			}
		}
	}
&remote_finished();

# Remove the temp file if needed
if ($dest->{'mode'} != 1 && $tarfile) {
        &delete_file_on_server($vhost, $tarfile);
        }
if ($tempdir) {
	&delete_file_on_server($vhost, $tempdir);
	}

# Return status
if ($tarerr) {
        return { 'ok' => 0, 'msg' => $tarerr };
        }
else {
        return { 'ok' => 1, 'size' => $st[7] };
        }
}

# type_kvm_open_shell(&server)
# Runs SSH to connect to a remote system. Returns an error message
# (or undef if OK), and a file handle.
sub type_kvm_open_shell
{
my ($server) = @_;
my ($out, $ex, $err, $status, $fh, $fpid) =
	&execute_command_on_server($server, "/bin/sh", 0, 1);
return $err ? ($err, undef) : $ex ? ($out, undef) : (undef, $fh);
}

# type_kvm_get_dns_name(&server)
# Returns a system's DNS name and zone name
sub type_kvm_get_dns_name
{
my $vhost = &get_parent_server($server);
return ( $server->{'kvm_dns'}, $vhost->{'kvm_zone'} );
}

# type_kvm_can_move(&server, [&dest])
# Check if moving a KVM instance is allowed. Only possible if target is up
sub type_kvm_can_move
{
my ($server, $dest) = @_;
if ($server->{'status'} eq 'nohost') {
	return 0;	# Parent is down
	}
elsif (!$dest) {
	return 1;	# Assume OK
	}
elsif ($dest->{'status'} eq 'virt' ||
       $dest->{'status'} eq 'nowebmin' ||
       $dest->{'status'} eq 'novirt') {
	return 1;	# Dest is OK
	}
return 0;
}

# type_kvm_move_system(&server, &dest, [shutdown], [allocate-ip])
# Actually move a KVM instance to a new host, printing messages as it goes.
sub type_kvm_move_system
{
my ($server, $dest, $shutdown, $allocate) = @_;
my $vhost = &get_parent_server($server);
my (@delfiles, @dellvs);

# Check if need to allocate new IP
my $ip = &get_server_ip($server);
my @kvm_iface = split(/\s+/, $dest->{'kvm_iface'});
if ($allocate && $dest->{'kvm_start'} &&
    !&range_check_ip_address($ip, $dest->{'kvm_start'}, $dest->{'kvm_end'},
				  $dest->{'kvm_cidr'}, $dest->{'kvm_gws'},
				  $dest->{'kvm_ifaces'}, $kvm_iface[0])) {
	# Allocate the primary IP
	&$first_print($text{'smove_allocating'});
	my ($newip, $newcidr, $newgw) = &allocate_ip_address(
		$dest->{'kvm_start'}, $dest->{'kvm_end'},
	        $dest->{'kvm_cidr'}, $dest->{'kvm_gws'},
		$dest->{'kvm_ifaces'}, $kvm_iface[0]);
	$newip || return &text('create_ekvmalloc', $dest->{'host'},
			    &describe_ip_range($dest->{'kvm_start'},
					       $dest->{'kvm_end'}));
	&$second_print(&text('smove_allocated', $newip));

	# Apply the IP change now
	&$first_print(&text('smove_ipchanging', $ip, $newip));
	$ifaces = &type_kvm_list_interfaces($server);
	return $ifaces if (!ref($ifaces));
	my ($iface) = grep { $_->{'address'} eq $ip } @$ifaces;
	$iface || return $text{'smove_eifaceip'};
	my $oldiface = { %$iface };
	$iface->{'address'} = $newip;
	$iface->{'netmask'} = &net::prefix_to_mask($newcidr);
	&modify_primary_ip_address($server, $ip, $newip);
	my $err = &type_kvm_modify_interface($server, $iface, $oldiface);
	return $err if ($err);
	$server->{'ip'} = $newip;
	&delete_ip_address($server, $ip);
	&add_ip_address($server, $newip);
	&$second_print($text{'create_done'});

	# Change the default gateway if needed
	$newgw ||= &get_server_default_gateway($dest);
	$newgw = "" if ($newgw eq "*");
	my $defgw = &get_server_default_gateway($vhost);
	my @gws = split(/\s+/, $server->{'kvm_gw'});
	my $gw = $gws[0] eq "*" ? $defgw : $gws[0];
	if ($newgw ne $gw) {
		&$first_print(&text('smove_gwchanging',
				    $gw || $text{'smove_gwnone'},
				    $newgw || $text{'smove_gwnone'}));
		my $err = &modify_default_gateway($server, $newgw);
		return $err if ($err);
		if ($server->{'kvm_gw'}) {
			$gws[0] = $newgw;
			$server->{'kvm_gw'} = join(" ", @gws);
			}
		&$second_print($text{'create_done'});
		}
	}

my $was_up;
if ($server->{'status'} ne 'down') {
	# Shut down before moving
	&$first_print($text{'smove_shutting'});
	$err = &shutdown_server($server);
	if ($err) {
		return &text('smove_shutfailed', $err);
		}
	$s->{'status'} = 'down';	# Assume it worked
	$was_up = 1;
	&$second_print($text{'create_done'});
	}

# Copy across all disk images, directly if possible
my $count = 0;
my $sz = 0;
my $disks = &type_kvm_list_disks($server, 0);
&$first_print($text{'smove_disks'});
&$indent_print();
foreach my $d (@$disks) {
	&$first_print(&text('smove_onedisk', $d->{'real'}));
	$d->{'newreal'} = $d->{'real'};
	if ($d->{'device'} && !$d->{'lv'}) {
		# A real device, which shouldn't be touched
		&$second_print(&text('smove_devdisk'));
		next;
		}
	my @sst = &stat_file_on_server($vhost, $d->{'real'});
	my @dst = &stat_file_on_server($dest, $d->{'real'});
	if (@dst && $dst[7] == $sst[7]) {
		# Already there! Perhaps from shared LVM
		&$second_print($text{'smove_alrdisk'});
		next;
		}

	my $newreal;
	if ($d->{'lv'}) {
		# LVM logical volume .. transfer to LV of the same name
		$dest->{'kvm_vg'} ||
			return $text{'smove_errvg'};
		$newreal = "/dev/".$dest->{'kvm_vg'}."/".$d->{'lv'};

		# Create LV on target first
		$last_remote_error = undef;
		my $lv = { 'name' => $d->{'lv'},
			      'size' => int($d->{'size'}/1024),
			      'perm' => 'rw',
			      'alloc' => 'n',
			      'vg' => $dest->{'kvm_vg'} };
		&remote_foreign_require($dest, "lvm", "lvm-lib.pl");
		my $err = &remote_foreign_call($dest, "lvm",
					  "create_logical_volume", $lv);
		$err ||= $last_remote_error;
		$err && return &text('smove_errlv', $err);

		# Transfer over the data, using dd. The size for
		# checksum purposes is rounded down to 1MB to account
		# for differences in LVM block sizes
		my $err = &transfer_file_between_servers($vhost, $dest,
			$d->{'real'}, $newreal, 1, 1,
			int($d->{'size'}/(1024*1024))*1024*1024);
		if ($err) {
			return &text('smove_errdisk', $err);
			}
		push(@dellvs, $d->{'real'});
		}
	else {
		# Work out a new filename, and copy over the file
		$newreal = $d->{'real'};
		$newreal =~ s/^.*[\\\/]//;
		$newreal = "$dest->{'kvm_dir'}/$newreal";
		my $err = &transfer_file_between_servers($vhost, $dest,
			$d->{'real'}, $newreal, 0, 1);
		if ($err) {
			return &text('smove_errdisk', $err);
			}
		push(@delfiles, $d->{'real'});
		}

	$d->{'newreal'} = $newreal;
	&$second_print(&text('smove_donedisk',
			     &nice_size($d->{'size'})));
	$count++;
	$sz += $d->{'size'};
	}
&$outdent_print();
if ($count) {
	&$second_print(&text('smove_disksdone', $count,
			     &nice_size($sz)));
	}
else {
	&$second_print(&text('smove_disksnone'));
	}

# Fix disk paths
my @drives = split(/\s+/, $server->{'kvm_drives'});
foreach my $d (@$disks) {
	my %drive = map { split(/=/, $_, 2) }
                        split(/,/, $drives[$disk->{'drive_index'}]);
	$drive{'file'} = $d->{'real'};
	$drives[$disk->{'drive_index'}] =
		join(",", map { $_."=".$drive{$_} } keys %drive);
	if ($server->{'kvm_filesystem'} eq $d->{'real'}) {
		$server->{'kvm_filesystem'} = $d->{'newreal'};
		}
	}
$server->{'kvm_drives'} = join(" ", @drives);
$server->{'kvm_on'} = $dest->{'id'};

# Delete the original disk images
if (@delfiles) {
	&$first_print(&text('smove_delfiles', scalar(@delfiles)));
	push(@delfiles, $server->{'kvm_console'}) if ($server->{'kvm_console'});
	foreach my $f (@delfiles) {
		my $err = &delete_file_on_server($vhost, $f);
		if ($err) {
			&$second_print(&text('smove_delerr', $f, $err));
			}
		}
	foreach my $f (@dellvs) {
		&remote_foreign_call($vhost, "lvm", "delete_logical_volume",
				     { 'device' => $f });
		}
	&$second_print($text{'create_done'});
	}

# Fix LVM volume group
if ($server->{'kvm_filesystem_vg'}) {
	$server->{'kvm_filesystem_vg'} = $dest->{'kvm_vg'};
	}
if ($server->{'kvm_swapfile_vg'}) {
	$server->{'kvm_swapfile_vg'} = $dest->{'kvm_vg'};
	}

# Start on the new host, if it was up before
if ($was_up) {
	&$first_print($text{'smove_starting'});
	my ($ok, $err) = &startup_server($server);
	if (!$ok) {
		return &text('smove_startfailed', $err);
		}
	&$second_print($text{'create_done'});
	}

return undef;
}

# type_kvm_find_servers(&vhost, &template-server, running-only, [basedir])
# Searches a KVM host system for running instances, and adds them to Cloudmin's
# control. Returns an array of server objects found. May print stuff.
sub type_kvm_find_servers
{
my ($vhost, $tmplserver, $running, $dir) = @_;
my @rv;

# Find all the servers we currently know about, for dupe checking
my (%alreadyip, %alreadykvm);
foreach my $s (&list_managed_servers()) {
	foreach my $ip (&get_server_ip($s)) {
		$alreadyip{$ip} = $s;
		}
	if ($s->{'kvm_on'} eq $vhost->{'id'}) {
		$alreadykvm{$s->{'kvm'}} = $s;
		}
	}

# Find running KVM instances
&$first_print($text{'find_kvmprocs'});
my $instances = &list_kvm_instances($vhost);
if (!ref($instances)) {
	&$second_print(&text('find_ekvmprocs', $instances));
	}
elsif (!@$instances) {
	&$second_print($text{'find_nokvmprocs'});
	}
else {
	&$second_print(&text('find_gotkvmprocs', scalar(@$instances)));
	}

# Process each process
foreach my $proc (@$instances) {
	&$first_print(&text('find_kvmproc', "<tt>$proc->{'cmd'}</tt>"));

	# Check for a PID clash
	my $already = $alreadykvm{$proc->{'pid'}};
	if ($already) {
		&$second_print(&text('find_xenalready', $already->{'host'}));
		next;
		}

	# Make sure we have a filesystem
	if (!$proc->{'filesystem'}) {
		&$second_print($text{'find_kvmfs'});
		next;
		}
	my ($out, $ex, $err) = &execute_command_on_server($vhost, 
			"qemu-img info ".quotemeta($proc->{'filesystem'}));
	if ($out !~ /file\s+format:\s+(\S+)/i || $1 ne "raw") {
		&$second_print(&text('find_kvmfsraw',
				     "<tt>$proc->{'filesystem'}</tt>"));
		next;
		}

	# Validate the name flag
	my $host = $proc->{'args'}->{'name'};
	if (!$host) {
		&$second_print($text{'find_kvmname'});
		next;
		}

	# Create the server object
	my $revhost = gethostbyaddr(inet_aton($address), AF_INET);
	my $server = { %$tmplserver,
			  'id' => &server_id(),
			  'desc' => "Automatically added KVM instance $name",
			  'type' => 'unknown',
			  'manager' => 'kvm',
			  'kvm' => $proc->{'pid'},
			  'kvm_on' => $vhost->{'id'},
			  'host' => $host,
			};
	&set_kvm_attributes($server, $vhost, $proc);
	&complete_managed_server($server);

	# Get status one more time, and save the server object
	&save_managed_server($server);
	&check_server_status($server);
	&save_managed_server($server);
	&$second_print(&text('find_xendone', $server->{'host'},
			     &describe_status($server, 1, 1)));
	push(@rv, $server);
	}

return @rv;
}

# list_kvm_host_bridges(&vhost)
# Returns the list of names of bridges on some KVM host system. Tries brctl 
# show first, then ifconfig
sub list_kvm_host_bridges
{
my ($vhost) = @_;
my @rv;
my ($out, $ex, $err) = &execute_command_on_server($vhost, "brctl show");
if (!$ex && !$err) {
	foreach my $l (split(/\r?\n/, $out)) {
		if ($l !~ /^bridge\s+name/ && $l =~ /^(\S+)/) {
			push(@rv, $1);
			}
		}
	}
if (!@rv) {
	my $ifaces = &list_active_server_interfaces($vhost);
	if (ref($ifaces)) {
		@rv = map { $_->{'fullname'} }
			  grep { $_->{'fullname'} =~ /^br/ &&
				 $_->{'virtual'} eq '' } @$ifaces;
		}
	}
return @rv;
}

# list_kvm_instances(&vhost)
# Returns a list of running KVM processes as an array ref, or an error message
sub list_kvm_instances
{
my ($vhost) = @_;
my $procs = &list_processes_on_server($vhost);
return $procs if (!ref($procs));
my @rv;
foreach my $p (@$procs) {
	my $kvm = &parse_kvm_start_command($p->{'args'});
	if ($kvm) {
		$kvm->{'pid'} = $p->{'pid'};
		push(@rv, $kvm);
		}
	}
return \@rv;
}

# parse_kvm_start_command(command-line)
# Converts a KVM command line into a hash ref with details of the flags
sub parse_kvm_start_command
{
my ($line) = @_;
if ($line =~ /^\s*(\S+\/|)(qemu-kvm|kvm)\s+(.*)/) {
	# Found a possible KVM line .. parse the args
	my ($cmd, $args) = ($2, $3);
	my @w = &split_quoted_string($args);
	my $ah = { };
	my $kvm = { 'args' => $ah,
		    'binary' => $cmd,
		    'cmd' => $line };
	my $lastarg;
	while(@w) {
		my $a = shift(@w);
		if ($a =~ /^\-+(\S+)$/) {
			# Start of a new arg
			$lastarg = $1;
			if ($ah->{$lastarg}) {
				# Already seen .. convert to array
				$ah->{$lastarg} = [ $ah->{$lastarg} ];
				}
			if (ref($ah->{$lastarg})) {
				# Add to array
				push(@{$ah->{$lastarg}}, "");
				}
			else {
				# Start of a single value
				$ah->{$lastarg} = "";
				}
			}
		else {
			# Value for an arg
			if (ref($ah->{$lastarg})) {
				# Add to end of list
				my $v = $ah->{$lastarg};
				$v[@$v-1] .= " " if ($v[@$v-1]);
				$v[@$v-1] .= $a;
				}
			else {
				# Add to single value
				$ah->{$lastarg} .= " "
					if ($ah->{$lastarg});
				$ah->{$lastarg} .= $a;
				}
			}
		}

	# Work out main drive
	if ($ah->{'hda'}) {
		$kvm->{'filesystem'} = $ah->{'hda'};
		}
	elsif ($ah->{'drive'}) {
		# Lowest-index disk set with -drive flag
		my @d = ref($ah->{'drive'}) ? @{$ah->{'drive'}}
					    : ( $ah->{'drive'} );
		my $lowindex = 9999;
		foreach my $d (@d) {
			my %dinfo = map { split(/=/, $_) }
					split(/,/, $d);
			if ($dinfo{'file'} &&
			    $dinfo{'media'} ne 'cdrom' &&
			    $dinfo{'index'} < $lowindex) {
				$kvm->{'filesystem'} = $dinfo{'file'};
				$lowindex = $dinfo{'index'};
				}
			}
		}

	if ($kvm->{'filesystem'} && $kvm->{'filesystem'} !~ /^\//) {
		# Relative path used .. normalize
		my $cwd = &get_kvm_process_dir($vhost, $p->{'pid'});
		if ($cwd) {
			$kvm->{'filesystem'} =
				$cwd."/".$kvm->{'filesystem'};
			}
		}
	return $kvm;
	}
return undef;
}

# get_server_kvm_instance(&server)
# Returns details of the KVM process for some managed system
sub get_server_kvm_instance
{
my ($server) = @_;
my $vhost = &get_parent_server($server);
my $procs = &list_kvm_instances($vhost);
return undef if (!$procs);
my ($proc) = grep { $_->{'filesystem'} eq $server->{'kvm_filesystem'} } @$procs;
return $proc;
}

# get_kvm_process_dir(&vhost, pid)
# Find the curent directory of some kvm process, useful for resolving relative
# disk paths.
sub get_kvm_process_dir
{
my ($vhost, $pid) = @_;
my ($out, $ex, $err) = &execute_command_on_server($vhost,
				"readlink /proc/$pid/cwd");
if (!$ex && !$err) {
	$out =~ s/\r|\n//g;
	return $out;
	}
return undef;
}

# kvm_instance_chooser_button(instance-field, host-field)
# Returns HTML for a popup window for selecting a running KVM instance
sub kvm_instance_chooser_button
{
my ($ifield, $hfield) = @_;
return "<input type=button onClick='ifield = form.$ifield; chooser = window.open(\"kvm_chooser.cgi?host=\"+escape(form.$hfield.value), \"chooser\", \"toolbar=no,menubar=no,scrollbar=no,width=600,height=300\"); chooser.ifield = ifield; window.ifield = ifield' value=\"...\">\n";
}

# allocate_kvm_ip_addresses(&server, &vhost)
# Allocate one or more IP addresses for a KVM instance from the host's ranges.
# On success, returns undef and sets kvm_ip, kvm_cidr and kvm_iface to space-
# separated lists. On failure returns an error message.
sub allocate_kvm_ip_addresses
{
my ($server, $vhost) = @_;

# Work out interfaces on host system
my @hostifaces;
if ($vhost->{'kvm_iface'}) {
	@hostifaces = split(/\s+/, $vhost->{'kvm_iface'});
	}
else {
	@hostifaces = ( "*" );
	}

# For each, allocate an IP from a range
foreach my $iface (@hostifaces) {
	my ($ip, $cidr, $gw) = &allocate_ip_address(
		$vhost->{'kvm_start'}, $vhost->{'kvm_end'},
	        $vhost->{'kvm_cidr'}, $vhost->{'kvm_gws'},
		$vhost->{'kvm_ifaces'}, $iface);
	$ip || return &text('create_exenalloc', $vhost->{'host'},
			    &describe_ip_range($vhost->{'kvm_start'},
					       $vhost->{'kvm_end'},
					       $vhost->{'kvm_cidr'},
                                               $vhost->{'kvm_ifaces'},
                                               $iface));
	push(@ips, $ip);
	push(@cidrs, $cidr);
	push(@gws, $gw || "*");
	}
$server->{'kvm_ip'} = join(" ", @ips);
$server->{'kvm_cidr'} = join(" ", @cidrs);
$server->{'kvm_hostifaces'} = join(" ", @hostifaces);
$server->{'kvm_gw'} = join(" ", @gws);
return undef;
}

# get_kvm_console_file(&server)
# Returns the filename to use for a KVM system's console file
sub get_kvm_console_file
{
my ($server) = @_;
my $dir;
if ($server->{'kvm_filesystem_lv'}) {
	# On LVM, use config dir for console file
	my $vhost = &get_parent_server($server);
	$dir = $vhost->{'kvm_dir'};
	}
else {
	# Same dir as root disk
	$dir = $server->{'kvm_filesystem'};
	$dir =~ s/\/([^\/]+)$//;
	}
return $dir."/".$server->{'host'}.".console";
}

# type_kvm_image_formats()
# KVM doesn't support partition images, as it always works with raw disks
sub type_kvm_image_formats
{
return ( "disk" );
}

1;

