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

# KVM instances can have a hostname separate from the DNS name
sub type_kvm_can_custom_hostname
{
return 1;
}

# Can reset, if the host is up
sub type_kvm_can_reset
{
my ($server) = @_;
return $server->{'status'} ne 'nohost';
}

# Empty KVM instances can be created
sub type_kvm_can_create_empty
{
return 1;
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

# Make sure the filesystem is in usable raw format, by trying to list
# partitions first, and then testing with qemu-img
my $parts = &list_disk_image_partitions($vhost, $got->{'filesystem'});
if (!ref($parts) || !@$parts) {
	my ($out, $ex, $err) = &execute_command_on_server($vhost, 
				"qemu-img info ".quotemeta($got->{'filesystem'}));
	if ($ex || $err) {
		&error(&text('add_ekvmfile', $got->{'filesystem'},
					     $err || $out));
		}
	elsif ($out !~ /file\s+format:\s+(\S+)/i || $1 ne "raw") {
		&error(&text('add_ekvmfile2', $got->{'filesystem'},
					      $1 || "unknown"));
		}
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
	my $dfile = $got->{'args'}->{'hd'.$dd};
	if ($dfile) {
		my $idx = ord($dd) - 97;
		push(@drives, "file=$dfile,index=$idx,media=disk");
		}
	delete($got->{'args'}->{'hd'.$dd});
	}
if ($got->{'args'}->{'cdrom'}) {
	push(@drives, "file=$got->{'args'}->{'cdrom'},index=2,media=cdrom");
	}
delete($got->{'args'}->{'cdrom'});
my @otherdrives = ref($got->{'args'}->{'drive'}) ?
			@{$got->{'args'}->{'drive'}} :
			( $got->{'args'}->{'drive'} );
push(@drives, @otherdrives);
$server->{'kvm_drives'} = join(" ", @drives);
if ($drives[0] =~ /if=virtio/) {
	$server->{'kvm_virtio'} = 1;
	}
delete($got->{'args'}->{'drive'});

# Save memory
$server->{'kvm_memory'} = $got->{'args'}->{'m'} || 128;
delete($got->{'args'}->{'m'});

# Save TAP network interfaces
my @nets = ref($got->{'args'}->{'net'}) ? @{$got->{'args'}->{'net'}}
					: ( $got->{'args'}->{'net'} );
$server->{'kvm_net'} = join(" ", grep { /^tap/ } @nets);

# Extract MAC addresses from nic network configs
my (@macs, @models);
foreach my $n (grep { /^nic/ } @nets) {
	if ($n =~ /macaddr=([0-9a-f:]+)/i) {
		push(@macs, $1);
		}
	else {
		push(@macs, "*");
		}
	if ($n =~ /model=([^, ]+)/i) {
		push(@models, $1);
		}
	else {
		push(@models, "*");
		}
	}
$server->{'mac'} = join(" ", @macs);
$server->{'model'} = join(" ", @models);
delete($got->{'args'}->{'net'});

# Save boot mode
if ($got->{'args'}->{'boot'}) {
	$server->{'kvm_bootdevice'} = $got->{'args'}->{'boot'};
	}
delete($got->{'args'}->{'boot'});

# Save keymap
if ($got->{'args'}->{'k'}) {
	$server->{'kvm_keymap'} = $got->{'args'}->{'k'};
	}
delete($got->{'args'}->{'k'});

# Save SMP
if ($got->{'args'}->{'smp'}) {
	$server->{'kvm_smp'} = $got->{'args'}->{'smp'};
	}
delete($got->{'args'}->{'smp'});

# Delete args we don't need to save
delete($got->{'args'}->{'name'});
delete($got->{'args'}->{'serial'});
delete($got->{'args'}->{'vnc'});
delete($got->{'args'}->{'nographic'});

# Save other unknown args
my @args;
foreach my $a (keys %{$got->{'args'}}) {
	my $v = $got->{'args'}->{$a};
	my @v = ref($v) ? @$v : ( $v );
	foreach my $vv (@v) {
		push(@args, "-".$a." ".$vv);
		}
	}
$server->{'kvm_args'} = join(" ", @args);
}

# type_kvm_create_form([empty-flag])
# Returns HTML for KVM-specific inputs
sub type_kvm_create_form
{
my ($empty) = @_;
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
		my @locs = defined(&list_vhost_locations) ?
				&list_vhost_locations(\@vhosts) : ( );
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

# type_kvm_limits_create_form([empty-flag])
# Returns HTML for KVM-specific inputs related to RAM and disk
sub type_kvm_limits_create_form
{
my ($empty) = @_;
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
	&ui_bytesbox("kvm_memory", $mem, 8));

# Filesystem size
$rv .= &ui_table_row($text{'create_xendisksize'},
	$empty ? &ui_bytesbox("kvm_disk", 2048*1024*1024, 8) :
		 &vui_opt_bytesbox("kvm_disk", undef, 8,
				  $text{'create_xendiskdef'}));

return $rv;
}

# type_kvm_advanced_create_form([empty-mode])
# Returns HTML for Xen-specific inputs
sub type_kvm_advanced_create_form
{
my ($empty) = @_;
my $rv;

# LVM / local files option
my @lvmhosts = grep { $_->{'kvm_host'} && $_->{'kvm_vg'} }
		    &list_managed_servers();
if (@lvmhosts) {
	$rv .= &ui_table_row($text{'xen_onlvm'},
		&ui_radio("kvm_lvm", -1,
			  [ [ -1, $text{'xen_onlvmdef'} ],
			    [ 0, $text{'xen_onlvm0'} ],
			    [ 1, $text{'xen_onlvm1'} ] ]));
	}

# VirtIO option
$rv .= &ui_table_row($text{'create_kvmusevirtio'},
	&ui_radio("kvm_virtio", $config{'kvm_virtio'} ? 1 :
				$empty ? 0 : -1,
		  [ $empty ? ( ) : ( [ -1, $text{'create_kvmvirtiodef'} ] ),
		    [ 1, $text{'yes'} ],
		    [ 0, $text{'no'} ] ]));

# Network interface type
my $models = &type_kvm_list_models();
$rv .= &ui_table_row($text{'create_kvmmodel'},
	&ui_select("kvm_model", $config{'kvm_model'},
		   [ [ undef, $text{'default'} ],
		     @$models ]));

return $rv;
}

# type_kvm_create_parse(&server, &in, [empty-flag])
# Parse inputs from type_kvm_create_form, and update the server object
sub type_kvm_create_parse
{
my ($server, $in, $empty) = @_;
my $img = $empty ? undef : &get_server_image($server->{'image'});

# Validate memory parameters
$in{'kvm_memory'} =~ /^\d+$/ || &error($text{'create_exenmemory'});
$server->{'kvm_memory'} = ($in{'kvm_memory'} * $in{'kvm_memory_units'}) /
			  (1024*1024);

# Validate disk size
if (!$in{'kvm_disk_def'} || $empty) {
	$in{'kvm_disk'} =~ /^\d+$/ || &error($text{'create_exendisksize'});
	$server->{'kvm_disksize'} = ($in{'kvm_disk'} * $in{'kvm_disk_units'}) /
				    (1024*1024);
	$server->{'kvm_disktotal'} = $server->{'kvm_disksize'}*1024*1024;
	if (!$empty &&
	    $img->{'rawsize'} &&
	    $img->{'rawsize'} > $server->{'kvm_disksize'}*1024*1024) {
		&error(&text('create_exendisksize2',
			     &nice_size($img->{'rawsize'})));
		}
	}
else {
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
$server->{'ip_addresses'} = $server->{'kvm_ip'};

# LVM setting
if ($in{'kvm_lvm'} == -1 || !defined($in{'kvm_lvm'})) {
	# Use host system default
	}
elsif ($in{'kvm_lvm'} == 0) {
	# Force not on LVM
	$server->{'kvm_nolvm'} = 1;
	}
elsif ($in{'kvm_lvm'} == 1) {
	# Must be on LVM
	$vhost->{'kvm_vg'} || &error(&text('xen_eonlvm', $vhost->{'host'}));
	}

# VirtIO setting
if (!defined($in{'kvm_virtio'}) || $in{'kvm_virtio'} == -1) {
	# Use image or global default
	$server->{'kvm_virtio'} = $empty ? $config{'kvm_virtio'}
					 : $img->{'kvm_virtio'};
	}
else {
	# User selection
	$server->{'kvm_virtio'} = $in{'kvm_virtio'};
	}

# Interface model setting
if (!defined($in{'kvm_model'})) {
	# Configured default
	$server->{'kvm_model'} = $config{'kvm_model'};
	}
elsif ($in{'kvm_model'}) {
	# User selection
	my $models = &type_kvm_list_models();
	my ($m) = grep { $_->[0] eq $in{'kvm_model'} } @$models;
	$m || &error($text{'create_ekvmmodel'});
	$server->{'kvm_model'} = $in{'kvm_model'};
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

# type_kvm_create_args([empty])
# Returns an array of parameters to type_kvm_create_args_parse
sub type_kvm_create_args
{
my ($empty) = @_;
my @rv = ( { 'name' => 'host', 'value' => 'host-system' },
	   { 'name' => 'location', 'value' => 'name' },
	   { 'name' => 'ip', 'value' => 'address[,address]', 'opt' => 1 },
	   { 'name' => 'cidr', 'value' => 'number[,number]', 'opt' => 1 },
	   { 'name' => 'netmask', 'value' => 'mask,[mask]', 'opt' => 1 },
	   { 'name' => 'gw', 'value' => 'address[,address|*]', 'opt' => 1 },
	   { 'name' => 'bridge', 'value' => 'name[,name]', 'opt' => 1 },
	   { 'name' => 'disksize', 'value' => 'megabytes', 'opt' => !$empty },
	   { 'name' => 'memory', 'value' => 'megabytes', 'opt' => 1 },
	 );
if (&can_action(undef, "advanced")) {
	my $models = join('|', map { $_->[0] } @{&type_kvm_list_models()});
	push(@rv, { 'name' => 'lvm', 'value' => 'true|false', 'opt' => 1 },
		  { 'name' => 'virtio', 'value' => 'true|false', 'opt' => 1 },
		  { 'name' => 'model', 'value' => $models, 'opt' => 1 },
	    );
	}
return @rv;
}

# type_kvm_create_args_parse(&args, &server, [empty-flag])
# Update a server object with parsed command-line args
sub type_kvm_create_args_parse
{
my ($args, $server, $empty) = @_;
my $img = $empty ? undef : &get_server_image($server->{'image'});

# Validate memory flags
if ($args->{'memory'}) {
	$args->{'memory'} =~ /^\d+$/ || return "Non-numeric memory allocation";
	$server->{'kvm_memory'} = $args->{'memory'};
	}
else {
	$server->{'kvm_memory'} = $config{'kvm_mem'};
	}

# Validate filesystem size flag
if ($args->{'disksize'} || $empty) {
	$args->{'disksize'} || return "Missing disk size parameter";
	$args->{'disksize'} =~ /^\d+$/ ||
		return "Non-numeric disk size";
	$server->{'kvm_disksize'} = $args->{'disksize'};
	if (!$empty &&
            $img->{'rawsize'} &&
	    $img->{'rawsize'} > $args->{'disksize'}*1024*1024) {
		return "--kvm-disksize must be at least $img->{'rawsize'} ".
		       "bytes, as that is the size of the selected image";
		}
	}
else {
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
$server->{'ip_addresses'} = $server->{'kvm_ip'};

# Adjust hostname for DNS
my @zones = &list_bind_zones();
my $zone;
if ($vhost->{'kvm_zone'}) {
	($zone) = grep { $_->{'name'} eq $vhost->{'kvm_zone'} } @zones;
	}
if ($zone) {
	$server->{'host'} .= ".".$vhost->{'kvm_zone'};
	}

if (&can_action(undef, "advanced")) {
	# Validate LVM flag
	if ($args->{'lvm'} =~ /true|yes/i) {
		$vhost->{'kvm_vg'} ||
			return "Host system $vhost->{'host'} does not use LVM";
		}
	elsif ($args->{'lvm'} =~ /false|no/i) {
		$server->{'kvm_nolvm'} = 1;
		}

	# Validate virtio flag
	if ($args->{'virtio'} =~ /true|yes/i) {
		$server->{'kvm_virtio'} = 1;
		}
	elsif ($img && $img->{'kvm_virtio'}) {
		$server->{'kvm_virtio'} = 1;
		}

	# Validate model flag
	if ($args->{'model'}) {
		# Selection from arg
		my $models = &type_kvm_list_models();
		my ($m) = grep { $_->[0] eq $args->{'model'} } @$models;
		$m || return "Invalid network interface model";
		$server->{'kvm_model'} = $args->{'model'};
		}
	else {
		# Use configured default
		$server->{'kvm_model'} = $config{'kvm_model'};
		}
	}
else {
	# Use defaults
	$server->{'kvm_virtio'} = $empty ? $config{'kvm_virtio'}
					 : $img->{'kvm_virtio'};
	$server->{'kvm_model'} = $config{'kvm_model'};
	}

return undef;
}

# type_kvm_create(&server, [serial, key], [reset], [empty])
# Create a new KVM instance, by unzipping the filesystem image in the background
sub type_kvm_create
{
my ($server, $serial, $key, $reset, $empty) = @_;
my $vhost = &type_kvm_parent($server);
my $img = $server->{'image'} ? &get_server_image($server->{'image'}) : undef;

# Create base dir if needed
if (!-d $vhost->{'kvm_dir'}) {
	&make_dir($vhost->{'kvm_dir'}, 0755, 1);
	}

# Validate CD image on host
if ($empty && !$server->{'image'}) {
	&stat_file_on_server($vhost, $server->{'imagefile'}) ||
		return "CD image $server->{'imagefile'} on host system ".
		       "$vhost->{'host'} does not exist";
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
my @nets;
for(my $i=0; $i<@ips; $i++) {
	my $net = "tap,vlan=$i";
	if ($ifaces[$i] && $ifaces[$i] ne '*') {
		# Create bridge script
		my ($data, $script) = &generate_kvm_bridge_script(
				$server, { 'name' => 'eth'.$i }, $ifaces[$i]);
		my $err = &put_file_data_to_server($vhost, $data, $script);
		return "Failed to create script $script : $err" if ($err);
		&execute_command_on_server($vhost, "chmod +x $script");
		$net .= ",script=$script";
		}
	push(@nets, $net);
	}
$server->{'kvm_net'} = join(" ", @nets);

# Set all interfaces to use the same model
if ($server->{'kvm_model'}) {
	my @models = split(/\s+/, $server->{'kvm_model'});
	while(@models < @nets) {
		push(@models, $models[0]);
		}
	}

# Set drive in config, unless resetting in which case they stay the same
if (!$reset) {
	$server->{'kvm_drives'} = "file=$fsfile,media=disk,index=0,".
		  ($server->{'kvm_virtio'} ? "if=virtio,boot=on" : "if=ide");
	}

# Find existing LV if resetting
my (@lvs, $fslv);
if ($reset && $server->{'xen_filesystem_vg'}) {
	&remote_foreign_require($vhost, "lvm", "lvm-lib.pl");
	@lvs = &remote_foreign_call($vhost, "lvm",
		"list_logical_volumes", $server->{'kvm_filesystem_vg'});
	($fslv) = grep { $_->{'vg'} eq $server->{'kvm_filesystem_vg'} &&
			 $_->{'name'} eq $server->{'kvm_filesystem_lv'} } @lvs;
	}

# If on LVM, create an LV first
$last_remote_error = undef;
if ($server->{'kvm_filesystem_vg'}) {
	&remote_foreign_require($vhost, "lvm", "lvm-lib.pl");
	my $lv = { 'name' => $server->{'kvm_filesystem_lv'},
		   'size' =>
			($img && !$empty ? int($img->{'rawsize'}/1024) : 0) ||
			int($server->{'kvm_disksize'}/1024) ||
			1024*1024,
		   'perm' => 'rw',
		   'alloc' => 'n',
		   'vg' => $server->{'kvm_filesystem_vg'} };
	if (!($fslv && $fslv->{'size'} > $lv->{'size'} &&
		       $fslv->{'size'}-$lv->{'size'} < 100*1024)) {
		# Only delete and re-create if an old LV with close enough to
		# the same size doesn't exist
		if ($reset) {
			# Delete the old LV
			&delete_all_disk_image_partitions($vhost, $fsfile);
			my $err = &remote_foreign_call($vhost, "lvm",
					     "delete_logical_volume",
					     { 'device' => $fsfile });
			$err ||= $last_remote_error;
			return "LVM logical volume deletion failed : $err"
				if ($err);
			}
		my $err = &remote_foreign_call($vhost, "lvm",
					       "create_logical_volume", $lv);
		$err ||= $last_remote_error;
		return "LVM logical volume creation failed : $err" if ($err);
		}
	}

# Create empty disk file and partition
if ($empty) {
	my $dksize = $server->{'kvm_disksize'}*1024*1024;
	if (!$server->{'kvm_filesystem_vg'}) {
		my $cmd = &dd_command("/dev/zero", $fsfile, $dksize);
		my ($out, $ex, $err) = &execute_command_on_server(
						$vhost, $cmd);
		$err = $out if ($ex);
		$err && return "Failed to create file $disk->{'real'} : $err";
		}
	my $err = &create_disk_image_partition($vhost, $fsfile,
					       1, $dksize, 1);
	return $err if ($err);
	}

# Add CD to list of disks
my $imgdestfile;
if ($empty && $server->{'image'}) {
	# CD will be copied to a new file
	$imgdestfile = "$vhost->{'kvm_dir'}/$server->{'host'}.cd";
	$server->{'kvm_drives'} .=
		" file=$imgdestfile,media=cdrom,index=2";
	$server->{'kvm_bootdevice'} = 'd';
	$server->{'kvm_cdimage'} = $imgdestfile;
	}
elsif ($empty && !$server->{'image'}) {
	# CD is in an existing file
	$server->{'kvm_drives'} .=
		" file=$server->{'imagefile'},media=cdrom,index=1,if=ide";
	$server->{'kvm_bootdevice'} = 'd';
	}
else {
	$imgdestfile = $fsfile;
	$server->{'kvm_bootdevice'} = 'c';
	}

# Put the image into place, in the background
if ($imgdestfile) {
	my @imgfiles = split(/\s+/, $img->{'files'});
	my $imgfile = "$server->{'imagetemp'}/$imgfiles[0]";
	my $temp = "/tmp/$$.$server->{'host'}.gunzip";
	$server->{'kvm_temp'} = $temp;
	if (!$img->{'nocompress'}) {
		# Need to un-compress the image
		my $writer = $imgdestfile =~ /^\/dev\// ?
			"| ".&dd_command(undef, $imgdestfile) :
			"> ".quotemeta($imgdestfile);
		my ($out, $ex, $err) = &execute_command_on_server($vhost,
			"(gunzip -c ".quotemeta($imgfile)." ".$writer." &&".
			" echo SERVER-MANAGER-COMPLETE ||".
			" echo SERVER-MANAGER-FAILED)".
			" >$temp 2>&1 </dev/null &");
		}
	else {
		my $cmd;
		if ($imgdestfile =~ /^\/dev\//) {
			# DD directly into LVM
			$cmd = &dd_command($imgfile, $imgdestfile);
			}
		else {
			# Can just move or copy
			$cmd = $server->{'imagelocal'} ? "cp" : "mv";
			$cmd .= " ".quotemeta($imgfile);
			$cmd .= " ".quotemeta($imgdestfile);
			}
		$cmd = "($cmd && echo SERVER-MANAGER-COMPLETE || ".
		       "echo SERVER-MANAGER-FAILED) >$temp 2>&1 </dev/null &";
		my ($out, $ex, $err) = &execute_command_on_server($vhost, $cmd);
		}
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
if (!$server->{'kvm_temp'}) {
	# No image creation was needed (as we are using a CD already on
	# the host)
	return "OK";
	}

# Read the gzip output file
my $data = &get_file_data_from_server($vhost, $server->{'kvm_temp'});
if ($data =~ /SERVER-MANAGER-FAILED/) {
	$data =~ s/SERVER-MANAGER-FAILED\n//;
	&execute_command_on_server($vhost,
		"rm -f ".quotemeta($server->{'kvm_temp'}));
	delete($server->{'kvm_temp'});
	return "Failed to extract filesystem : $data";
	}
elsif ($data =~ /SERVER-MANAGER-COMPLETE/) {
	&execute_command_on_server($vhost,
		"rm -f ".quotemeta($server->{'kvm_temp'}));
	delete($server->{'kvm_temp'});
	return "OK";
	}
else {
	return undef;
	}
}

# type_kvm_create_post(&server, [serial, key], [reset], [empty])
# Called after creation is complete. Here we can mount and fix up config
# files in the filesytem, then start the instance.
sub type_kvm_create_post
{
my ($server, $serial, $key, $reset, $empty) = @_;
my $vhost = &type_kvm_parent($server);
my @ips = split(/\s+/, $server->{'kvm_ip'});
my @cidrs = split(/\s+/, $server->{'kvm_cidr'});
my @netmasks = map { &net::prefix_to_mask($_) } @cidrs;
$server->{'status'} = 'down';

# Gateways can either be set per IP address, or copy from host system.
# If none are set, assume the first IP uses the host system gateway.
my $defgw = &get_server_default_gateway($vhost);
my @gws = split(/\s+/, $server->{'kvm_gw'});
my @setgws = grep { $_ ne "*" } @gws;
if (!@setgws && $defgw) {
	@gws = ( $defgw );
	}

# Generate MAC addresses
my @macs;
for(my $i=0; $i<@ips; $i++) {
	push(@macs, &generate_mac_address($server, $i));
	}
$server->{'mac'} = join(" ", @macs);

# Fix root disk device to match virtio mode
my $wantdev = $server->{'kvm_virtio'} ? "/dev/vda" : "/dev/hda";
my $hasbootfs = 0;
if (!$empty && $server->{'kvm_virtio'} != $img->{'kvm_virtio'}) {
	&$first_print($text{'create_kvmvirtio'});
	&mount_filesystem_if_needed($server);
	my $fstab = &get_system_fstab($server);
	if (!ref($fstab)) {
		&$second_print(&text('create_ekvmvirtio', $fstab));
		}
	else {
		my $changed = 0;
		foreach my $f (@$fstab) {
			if ($f->[0] =~ /^\/dev\/[hsv]da/ &&
			    $f->[0] !~ /^\Q$wantdev\E/ &&
			    $f->[0] =~ /(\d+)$/) {
				my $part = $1;
				$f->[0] = $wantdev.$part;
				$changed++;
				}
			if ($f->[1] eq "/boot") {
				# If /boot is mounted separate, the path to
				# grub.conf below changes
				$hasbootfs = 1;
				}
			}
		my $err = $changed ? &put_system_fstab($server, $fstab) : undef;
		if ($err) {
			&$second_print(&text('create_ekvmvirtio', $err));
			}
		else {
			&$second_print($text{'create_done'});
			}
		}
	&umount_filesystem_if_needed($server);
	}

# Fix grub config to match virtio mode
if (!$empty && $server->{'kvm_virtio'} != $img->{'kvm_virtio'}) {
	&$first_print($text{'create_kvmgrub'});
	my $grubdir = $hasbootfs ? "/grub" : "/boot/grub";
	&mount_filesystem_if_needed($server, $grubdir);
	my $grubconf;
	my $data;
	foreach my $g ("$grubdir/menu.lst", "$grubdir/grub.conf") {
		$data = &get_file_data_from_server($server, $g);
		if ($data) {
			$grubconf = $g;
			last;
			}
		}
	if (!$data) {
		&$second_print(&text('create_ekvmgrubget'));
		}
	else {
		$data =~ s/ root=(\S+)(\d+)/ root=$wantdev$2/g;
		my $err = &put_file_data_to_server($server, $data, $grubconf);
		if ($err) {
			&$second_print(&text('create_ekvmgrub', $err));
			}
		else {
			&$second_print($text{'create_done'});
			}
		}
	&umount_filesystem_if_needed($server);
	}

if (!$empty) {
	# Clean up /etc/fstab to remove non-existant devices
	&$first_print($text{'create_xencleanfstab'});
	my $err = &cleanup_server_fstab($server);
	if ($err) {
		&$second_print(&text('create_exencleanfstab', $err));
		}       
	else {
		&$second_print($text{'create_done'});
		}
	}

my $mp;
if (!$empty) {
	# Expand the filesystem image, if needed
	my $fsfile = $server->{'kvm_filesystem'};
	if ($server->{'kvm_disksize'}) {
		my $dksize = $server->{'kvm_disksize'}*1024*1024;
		&$first_print(&text('create_xenresize', &nice_size($dksize)));
		my $disks = &type_kvm_list_disks($server, 1);
		my $disk;
		if (ref($disks)) {
			($disk) = grep { $_->{'real'} eq
					 $server->{'kvm_filesystem'} } @$disks;
			}
		if (!$disk || !$disk->{'fs'}) {
			&$second_print(&text('create_exenresize2'));
			}
		else {
			my $olddisk = { %$disk };
			$disk->{'size'} = $dksize;
			my $err = &type_kvm_modify_disk($server, $disk,
							$olddisk);
			if ($err) {
				&$second_print(&text('create_exenresize',$err));
				}       
			else {
				&$second_print($text{'create_done'});
				}
			}
		}

	# Mount the created filesystem
	&$first_print($text{'create_xenmount'});
	my $err = &mount_filesystem_if_needed($server);
	$mp = $server->{'kvm_mount'};
	if ($err || !$mp) {
		&$second_print(&text('create_exenmount', $err));
		$mp = undef;
		}
	else {
		&$second_print(&text('create_xenmounted', "<tt>$mp</tt>"));
		}
	}

if (!$empty && $mp) {
	# Set the root password, by directly editing /etc/shadow
	if ($server->{'ssh_pass'}) {
		&$first_print($text{'create_xensetpass'});
		my $err = &set_shadow_root_password($server,
						    $server->{'ssh_pass'});
		if ($err) {
			&$second_print(&text('create_exensetpass', $err));
			}       
		else {
			&$second_print($text{'create_done'});
			}
		}
	else {
		# Using key, so clear password
		&set_shadow_root_password($server, undef);
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
	my $fullhost = $server->{'unix_hostname'} || $server->{'host'};
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
	}

# Add DHCP entries
if ($config{'dhcp_add'} && !$reset) {
	my @fakeifaces;
	for(my $i=0; $i<@ips; $i++) {
		push(@fakeifaces,
		     { 'name' => 'eth'.$i,
		       'fullname' => 'eth'.$i,
		       'address' => $ips[$i],
		       'ether' => $macs[$i] eq '*' ?  '' : $macs[$i] });
		}
	&add_all_iface_dhcpd($server, \@fakeifaces);
	}

if ($mp) {
	# Un-mount
	&$first_print($text{'create_xenumount'});
	&umount_filesystem_if_needed($server);
	&$second_print($text{'create_done'});
	}

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
my ($ok, $err) = &type_kvm_startup($server, $empty);
my $started = 0;
if ($ok != 1) {
	&$second_print(&text('create_exenstartup', $err));
	}       
else {
	&$second_print($text{'create_done'});
	$started = 1;
	}

# Import Virtualmin keys
if ($serial && $started && !$empty) {
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
if ($started && !$empty) {
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
&type_kvm_shutdown($server, 1);
return &type_kvm_startup($server);
}

# type_kvm_shutdown(&server, [force])
# SSH in and shutdown, or kill
sub type_kvm_shutdown
{
my ($server, $force) = @_;
my $vhost = &type_kvm_parent($server);
if (&can_ssh_status($server)) {
	# Sync filesystems first, to avoid corruption
	&execute_command_on_server($server, "sync ; sync ; sync");
	}
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

# type_kvm_startup(&server, [no-ping])
# Start the kvm or qemu-kvm process, and wait till it responds to ping and SSH
sub type_kvm_startup
{
my ($server, $noping) = @_;
my $vhost = &type_kvm_parent($server);
my $cmd = &get_kvm_start_command($server);
my ($pinged, $sshed);

# Create a console output file and monitor input file
$server->{'kvm_console'} ||= &get_kvm_console_file($server);
my $err = &create_kvm_monitor_file($server);
return (0, "Failed to create monitor input file : $err") if ($err);

# Run qemu-kvm to start it up, in the background
my ($out, $ex, $err) = &execute_command_on_server($vhost,
	"/usr/bin/pty.pl --sleep 2 $cmd >$server->{'kvm_console'} 2>&1 ".
	"<$server->{'kvm_monitor'} &");
return (0, $err) if ($err);
return (0, $out || "Unknown error") if ($ex);

# Wait 20 seconds for it to start
my $tries = 0;
my $found = 0;
while($tries++ < 20) {
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
	return (0, $out || "No console output generated");
	}

# Wait up to 60 seconds for ping
if (!$noping) {
	$pinged = &wait_for_ping($server);
	}

# Wait for SSH to come up
if ($pinged && !$server->{'no_sshlogin'}) {
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

# type_kvm_can_get_console_output(&server)
sub type_kvm_can_get_console_output
{
my ($server) = @_;
return $server->{'kvm_console'} ? 1 : 0;
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

# type_kvm_delete(&server, [keep-disks])
# Delete a KVM instance
sub type_kvm_delete
{
my ($server, $keep) = @_;
my $vhost = &type_kvm_parent($server);

# Force shutdown if needed
my $proc = &get_server_kvm_instance($server);
if ($proc) {
	&type_kvm_shutdown($server, 1);
	$server->{'status'} = 'down';
	}

# Delete virtual disks
if (!$keep) {
	my $disks = &type_kvm_list_disks($server, 0);
	if (ref($disks)) {
		foreach my $d (reverse(@$disks)) {
			my @st = &stat_file_on_server($vhost, $d->{'real'});
			next if (!@st);			# Already gone
			next if ($d->{'media'} eq 'cdrom' &&
				 $d->{'real'} ne $server->{'kvm_cdimage'} &&
				 !$d->{'device'});	# CD image in file
			next if ($d->{'device'} &&	# Attached real device
				 !$d->{'lv'});
			my $err = &type_kvm_delete_disk($server, $d, 0, 1);
			return $err if ($err);
			}
		}
	}

# Delete boot-time entry
&type_kvm_set_atboot($server, 0);

# Delete console and monitor input files
if ($server->{'kvm_console'}) {
	&delete_file_on_server($vhost, $server->{'kvm_console'});
	}
if ($server->{'kvm_monitor'}) {
	&delete_file_on_server($vhost, $server->{'kvm_monitor'});
	}

# Remove the DNS entry, if we created one
&delete_bind8_record($server->{'kvm_dns'}, $vhost->{'kvm_zone'},
		     &to_ipaddress($server->{'host'}));

# Remove DHCP entries
&delete_all_iface_dhcpd($server);

# Delete bridge scripts
my @nets = split(/\s+/, $server->{'kvm_net'});
foreach my $net (@nets) {
	if ($net =~ /script=([^,]+)/) {
		my $script = $1;
                if ($script =~ /^\Q$vhost->{'kvm_dir'}\/\E/) {
                        &delete_file_on_server($vhost, $script);
                        }
		}
	}

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

# Boot device
$cmd .= " -boot ".($server->{'kvm_bootdevice'} || 'c');

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

# Connect monitor to stdout
$cmd .= " -monitor stdio";

# TAP networking, if enabled
my @macs = split(/\s+/, $server->{'mac'});
my @models = split(/\s+/, $server->{'kvm_model'});
my $i = 0;
foreach my $net (split(/\s+/, $server->{'kvm_net'})) {
	$cmd .= " -net $net";
	if ($net =~ /vlan=(\d+)/) {
		$cmd .= " -net nic,vlan=$1";
		}
	else {
		$cmd .= " -net nic";
		}
	if ($macs[$i] && $macs[$i] ne '*') {
		$cmd .= ",macaddr=".$macs[$i];
		}
	if ($models[$i] && $models[$i] ne '*') {
		$cmd .= ",model=".$models[$i];
		}
	$i++;
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
	$cmd .= " -vnc :".$server->{'kvm_vnc_display'}.",password";
	}
else {
	$cmd .= " -nographic";
	}

# Add keymap flag
if ($server->{'kvm_keymap'}) {
	$cmd .= " -k ".$server->{'kvm_keymap'};
	}

# Add SMP flag
if ($server->{'kvm_smp'}) {
	$cmd .= " -smp ".$server->{'kvm_smp'};
	}

# Add other imported flags
if ($server->{'kvm_args'}) {
	$cmd .= " ".$server->{'kvm_args'};
	}

return $cmd;
}

# generate_kvm_bridge_script(&server, &iface, bridge)
# Returns the contents of and path to a script to connect the right bridge
# for a virtual interface
sub generate_kvm_bridge_script
{
my ($server, $iface, $bridge) = @_;
my $vhost = &type_kvm_parent($server);
my $data = "#!/bin/sh\n".
	   "brctl addif $bridge \$1\n".
	   "ifconfig \$1 up\n";
return ($data,
	$vhost->{'kvm_dir'}."/".$server->{'host'}."-".$iface->{'name'}.".sh");
}

# type_kvm_can_disks(&server)
# Returns 1, as we can manage disks for Xen instances. These are files or
# devices mapped to virtual disks in the instance.
sub type_kvm_can_disks
{
my ($server) = @_;
return $server->{'status'} ne 'nohost' ? 1 : 0;
}

# type_kvm_can_safely_resize_disk(&server, &disk)
# Returns undef if some disk can be safely resized, or an error message if not
sub type_kvm_can_safely_resize_disk
{
my ($server, $disk) = @_;
if (!$disk->{'fs'}) {
	return $text{'disk_eresizefs'};
	}
elsif ($disk->{'fs'} !~ /^ext\d+$/ && $disk->{'fs'} ne 'swap') {
	return $text{'disk_eresizefstype'};
	}
else {
	return undef;
	}
}

# type_kvm_list_disks(&server, include-mounts)
# Returns a list of hash refs, one per disk, with fields :
# real - Real file on host system, like /kvm/foo.dsk
# virt - Virtual device on instance, like /dev/sda
# device - Set to 1 if this is a real device, like /dev/md1
# size - Size in bytes, if a file
# media - disk or cdrom
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
	elsif ($drive{'if'} eq 'virtio') {
		$dev = "vd".chr($drive{'index'}+97);
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
		     'drive_index' => $idx,
		     'media' => $drive{'media'} || 'disk',
		     'format' => 'disk' };
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
			$disk->{'lv_snap_of'} = $lv->{'snap_of'};
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
	my %label_to_part;
	my $got_label_to_part = 0;
	foreach my $d (@rv) {
		my ($f) = grep { &same_xen_virt($d->{'virt'}, $_->[0], 1) }
			       @$fstab;
		if (!$f) {
			# Check if a partition has an ext label
			if (!$got_label_to_part) {
				%label_to_part = &get_label_map($server);
				$got_label_to_part = 1;
				}
			my $label;
			foreach my $l (keys %label_to_part) {
				my $p = $label_to_part{$l};
				if (&same_xen_virt($p, $d->{'virt'}, 1)) {
					$label = $l;
					last;
					}
				}
			if ($label) {
				($f) = grep { $_->[0] eq 'LABEL='.$label }
					    @$fstab;
				if ($f) {
					$f->[0] = $label_to_part{$label};
					$d->{'virt_label'} = $label;
					}
				}
			}
		if ($f) {
			$d->{'virt_mount'} = $f->[0];
			$d->{'virt_onsystem'} = $f->[0];
			$d->{'virt_onsystem'} =~ s/\d+$//;
			$d->{'mount'} = $f->[1];
			$d->{'fs'} = $f->[2];
			if ($f->[0] =~ /(\d+)$/) {
				$d->{'virt_part'} = $1;
				}
			if ($d->{'fs'} eq 'swap') {
				$d->{'swap'} = 1;
				}
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
if ($disks->[0]->{'virt'} =~ /^(\/dev\/[shx]d)[a-z]$/) {
	# Pick a free partition on the next disk
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
$rv->{'virt_part'} = 1;

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
$rv->{'format'} = 'disk';
$rv->{'device'} = $device;
$rv->{'media'} = 'disk';
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
		my $cmd = &dd_command("/dev/zero", $disk->{'real'},
				      $disk->{'size'});
		my ($out, $ex, $err) = &execute_command_on_server(
						$vhost, $cmd);
		$err = $out if ($ex);
		$err && return "Failed to create file $disk->{'real'} : $err";
		}

	# Create the partiton
	if (!@st) {
		my $err = &create_disk_image_partition($vhost, $disk->{'real'},
						       1, $disk->{'size'}, 1);
		return $err if ($err);
		}

	# And make a filesystem on the new partition
	if (!@st && $disk->{'fs'}) {
		my $err = &create_disk_image_filesystem($vhost, $disk->{'real'},
							$disk->{'fs'}, 1);
		return "Failed to create ".uc($disk->{'fs'}).
		       " filesystem : $err" if ($err);
		}
	}

# Add the disk to the KVM config
my @drives = split(/\s+/, $server->{'kvm_drives'});
my %drive = ( 'file' => $disk->{'real'},
	      'media' => $disk->{'media'} || 'disk' );
if ($disk->{'virt'} =~ /sd[a-z]+$/) {
	$drive{'if'} = 'scsi';
	}
elsif ($disk->{'virt'} =~ /vd[a-z]+$/) {
	$drive{'if'} = 'virtio';
	}
else {
	$drive{'if'} = 'ide';
	}
if ($disk->{'virt'} =~ /([hsv])d([a-z])$/) {
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

# If mounting a CD, there are no partitions
if ($disk->{'media'} eq 'cdrom') {
	$disk->{'virt_mount'} = $disk->{'virt'};
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
		my $fs = $disk->{'fs'} ? $disk->{'fs'} :
			  $disk->{'media'} eq 'cdrom' ? 'iso9660' : 'ext2';
		push(@$fstab, [ $disk->{'virt_mount'}, $disk->{'mount'},
				$fs, 'defaults', 0, 0 ]);
		my $err = &put_system_fstab($server, $fstab);
		$fserr = "Failed to update fstab file : $err" if ($err);
		}
	&umount_filesystem_if_needed($server);
	}

return $fserr;
}

# type_kvm_delete_disk(&server, &disk, [detach-only], [leave-fstab])
# Removes a disk from the Xen configuration, the system's fstab file, and
# deletes the underlying config file. The disk object must come from a call
# to type_kvm_list_disks with the mount flag set to 1.
sub type_kvm_delete_disk
{
my ($server, $disk, $detach, $nofstab) = @_;
my $vhost = &type_kvm_parent($server);

# Actually un-mount if mounted
if (&can_ssh_status($server) && $disk->{'mounted'}) {
	my ($out, $ex, $err) = &execute_command_on_server($server,
		"umount ".$disk->{'mounted'});
	if ($err || $ex) {
		return "Failed to un-mount $disk->{'virt_mount'} : ".
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
if (($server->{'status'} eq 'down' || &can_ssh_status($server)) &&
    $disk->{'virt_mount'} && $disk->{'virt_mount'} ne '/' && !$nofstab) {
	my $fstab = &get_system_fstab($server);
	return "Failed to read fstab file : $fstab" if (!ref($fstab));
	my @newfstab = grep { $_->[0] ne $disk->{'virt_mount'} } @$fstab;
	if (scalar(@newfstab) != scalar(@$fstab)) {
		my $err = &put_system_fstab($server, \@newfstab);
		$fserr = "Failed to update fstab file : $err" if ($err);
		}
	}

if (!$detach) {
	&delete_all_disk_image_partitions($vhost, $disk->{'real'});
	if (!$disk->{'device'} && $disk->{'real'} !~ /^\/dev\//) {
		# Delete the image file
		&delete_file_on_server($vhost, $disk->{'real'});
		}
	elsif ($disk->{'lv'}) {
		# Delete mapper entries for LV, if any
		my $mapper = "$disk->{'vg'}-$disk->{'lv'}";
		&delete_mapper_entries($vhost, $mapper);

		# Delete the logical volume
		&remote_foreign_require($vhost, "lvm", "lvm-lib.pl");
		&remote_foreign_call($vhost, "lvm", "delete_logical_volume",
				     { 'device' => $disk->{'real'} });
		}
	if ($disk->{'lv'} && $disk->{'lv_snap_of'}) {
		# LV is a snapshot .. does any existing system use it?
		my $srcreal = &find_snapshot_source_logical_volume(
				$server, $disk->{'vg'}, $disk->{'lv_snap_of'});
		if ($srcreal) {
			# Source of snapshot is un-used, likely because it was
			# deleted before this clone. Delete the LV.
			&delete_all_disk_image_partitions($vhost, $srcreal);
			my $mapper = "$disk->{'vg'}-$disk->{'lv_snap_of'}";
			&delete_mapper_entries($vhost, $mapper);
			&remote_foreign_call($vhost, "lvm",
					     "delete_logical_volume",
					     { 'device' => $srcreal });
			}
		}
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
my $part = ref($parts) ? $parts->[@$parts - 1] : undef;

# Work out if we can resize the filesystem
my $resizefs;
if ($disk->{'size'} != $olddisk->{'size'}) {
	if ($disk->{'fs'} =~ /^ext\d+$/ || $disk->{'fs'} eq 'swap') {
		$part || return "No partitions were found on the disk image!";
		$disk->{'virt_part'} == scalar(@$parts) ||
			return "Only the last partition on a disk image can ".
			       "be resized";
		$resizefs = 1;
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
	my $loop = &get_loop_device($vhost);

	if ($disk->{'lv'} && $disk->{'size'} > $olddisk->{'size'}) {
		# Expand logical volume (before filesystem)
		push(@cmds, "lvextend -L".int($disk->{'size'}/1024)."k ".
			    quotemeta($disk->{'real'}));
		}
	elsif (!$disk->{'lv'} && $disk->{'size'} > $olddisk->{'size'}) {
		# Expand the disk image (before filesystem)
		push(@cmds, &dd_command("/dev/zero", undef,
					$disk->{'size'}-$olddisk->{'size'}).
			    " >>".quotemeta($disk->{'real'}));
		}

	# Work out the new filesystem size, taking into the new total disk
	# size and any preceeding partitions.
	my $newmbs;
	if ($resizefs) {
		$newmbs = int(($disk->{'size'} -
			       $part->{'start_bytes'})/1024/1024);
		$newmbs = int($newmbs / 8) * 8;
		}

	if ($disk->{'size'} < $olddisk->{'size'} && $resizefs) {
		# Shrink the filesystem
		push(@cmds, "losetup -o $part->{'offset'} $loop ".
			    quotemeta($disk->{'real'}));
		push(@cmds, "e2fsck -f -p $loop");
		push(@cmds, "resize2fs $loop ".$newmbs."M");
		push(@cmds, "losetup -d $loop");
		}

	# Delete the last partition, then re-create it
	if ($part) {
		push(@cmds, "parted -s ".quotemeta($disk->{'real'})." rm ".
			    $part->{'part'});
		push(@cmds, "parted -s ".quotemeta($disk->{'real'})." mkpart ".
			    $part->{'parted_type'}." ".
			    $part->{'parted_start'}." ".
			    int($disk->{'size'}/1000000)."M");
		}

	if ($disk->{'size'} > $olddisk->{'size'} && $resizefs) {
		# Expand the filesystem
		push(@cmds, "losetup -o $part->{'offset'} $loop ".
			    quotemeta($disk->{'real'}));
		push(@cmds, "e2fsck -f -p $loop");
		push(@cmds, "resize2fs $loop ".$newmbs."M");
		push(@cmds, "losetup -d $loop");
		}

	if (!$disk->{'lv'} && $disk->{'size'} < $olddisk->{'size'}) {
		# Truncate the file (after resizing filesystem)
		push(@cmds, &dd_command($disk->{'real'},
				        $disk->{'real'}.".tmp",
				        $disk->{'size'}));
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
		if ($cmd =~ /fsck/ && ($ex == 1 || $ex == 256)) {
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
	&execute_command_on_server($vhost, "losetup -d $loop");

	# Update total disk size
	if (!$moderr &&
	    $server->{'xen_disktotal'} ne '' &&
	    (!$disk->{'device'} || $disk->{'lv'})) {
		$server->{'xen_disktotal'} -= $olddisk->{'size'};
		$server->{'xen_disktotal'} += $disk->{'size'};
		}
	}

if ($disk->{'virt'} ne $olddisk->{'virt'} ||
    $disk->{'media'} ne $olddisk->{'media'}) {
	# Change the virtual device, both in the KVM config file and fstab
	if ($olddisk->{'virt_mount'} =~ /(\d+)$/) {
		$disk->{'virt_mount'} = $disk->{'virt'}.$1;
		}

	# Fix disk in config
	my @drives = split(/\s+/, $server->{'kvm_drives'});
	my %drive = map { split(/=/, $_, 2) }
			split(/,/, $drives[$disk->{'drive_index'}]);
	if ($disk->{'virt'} =~ /([hsv])d([a-z])$/) {
		$drive{'index'} = ord($2)-97;
		}
	if ($disk->{'media'}) {
		$drive{'media'} = $disk->{'media'};
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

# type_kvm_can_fsck(&server, &disk)
# Returns 1 if some disk can have it's filesystem checked. Only true when
# the system is down or the disk is not mounted.
sub type_kvm_can_fsck
{
my ($server, $disk) = @_;
return ($server->{'status'} eq 'down' || !$disk->{'mounted'}) &&
       $disk->{'fs'} && $disk->{'fs'} ne 'swap' &&
       $disk->{'media'} ne 'cdrom';
}

# type_kvm_fsck_disk(&server, &disk, [only-if-unclean])
# Run fsck on a disk to validate and repair the filesystem. Returns 1 if 
# all was OK to start with, 2 if fixes were made and 0 on failure, plus the
# output from fsck
sub type_kvm_fsck_disk
{
my ($server, $disk, $noforce) = @_;
my $flag = $noforce ? "" : "-f";
my $vhost = &get_parent_server($server);
my $parts = &list_disk_image_partitions($vhost, $disk->{'real'});
ref($parts) || return (0, "Failed to list partitions : $parts");
my $part = $parts->[@$parts - 1];
my $loop = &get_loop_device($vhost);
my ($out, $ex, $err) = &execute_command_on_server($vhost,
	"losetup -o $part->{'offset'} $loop ".quotemeta($disk->{'real'}));
if ($ex || $err) {
	return (0, "losetup failed : ".($err || $out));
	}
my ($out, $ex, $err) = &execute_command_on_server($vhost,
	"fsck -y $flag $loop");
&execute_command_on_server($vhost,
	"losetup -d $loop");
if ($ex > 2 || $err) {
	return (0, $out);
	}
elsif ($ex) {
	return (2, $out);
	}
else {
	return (1, $out);
	}
}

# type_kvm_list_disk_medias(&server)
# Returns a list of possible media types for disks on some system. Each is a
# hash ref with id and desc field
sub type_kvm_list_disk_medias
{
my ($server) = @_;
return [ { 'id' => 'disk', 'desc' => 'Hard disk' },
	 { 'id' => 'cdrom', 'desc' => 'CD or DVD drive' } ];
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

# type_kvm_can_smp(&server)
# Returns 2, indicating the number of virtual CPUs can be changed with a reboot
sub type_kvm_can_smp
{
return 2;
}

# type_kvm_get_smp(&server)
# Returns the number of virtual CPUs 
sub type_kvm_get_smp
{
my ($server) = @_;
return $server->{'kvm_smp'} || 1;
}

# type_kvm_save_smp(&server, cpus)
# Sets the number of virtual CPUs
sub type_kvm_save_smp
{
my ($server, $smp) = @_;
$smp > 0 || return "KVM virtual CPUs must be at least 1";
$smp < 256 || return "KVM virtual CPUs must be less than 256";
$server->{'kvm_smp'} = $smp;
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

# type_kvm_can_mac_address(&server, [&iface])
# Returns 1 if the MAC address for an interface can be edited
sub type_kvm_can_mac_address
{
my ($server, $iface) = @_;
return $iface && $iface->{'virtual'} eq '';
}

# Regular interface IP allocation works for KVM
sub type_kvm_can_allocate_address
{
return 1;
}

# type_kvm_can_gateway(&server)
# Returns 1 indicating that KVM instances can have their default gateway 
# read and set.
sub type_kvm_can_gateway
{
my ($server) = @_;
return $server->{'status'} eq 'virt' || $server->{'status'} eq 'novirt' ||
       &redhat_server_type($server) || &debian_server_type($server);
}

# type_kvm_list_interfaces(&server)
# Returns a list of network interfaces on the system, or an error message
sub type_kvm_list_interfaces
{
my ($server) = @_;
my $rv;
if ($server->{'status'} eq 'down') {
	# Get from network config files
	my $err = &mount_filesystem_if_needed($server);
	return "Failed to mount filesystem : $err" if ($err);
	$rv = &list_boot_server_interfaces($server);
	&umount_filesystem_if_needed($server);
	}
else {
	# Get active and boot interfaces
	$rv = &list_active_server_interfaces($server);
	$bootrv = &list_boot_server_interfaces($server);
	if (ref($rv) && ref($bootrv)) {
		my %got = map { $_->{'fullname'}, $_ } @$rv;
		push(@$rv, grep { !$got{$_->{'fullname'}} &&
				  &check_ipaddress($_->{'address'}) }
				@$bootrv);
		}
	}

# Set nodelete flag on first real interface, filter out interfaces
# with no IP or non-ethernet
if (ref($rv)) {
	$rv = [ grep { $_->{'fullname'} =~ /^eth/ &&
		       $_->{'up'} &&
		       $_->{'address'} } @$rv ];
	foreach my $iface (@$rv) {
		if ($iface->{'fullname'} eq 'eth0') {
			$iface->{'nodelete'} = 1
			}
		}
	}

# Set MAC, bridges and model field on real interfaces
my @macs = split(/\s+/, $server->{'mac'});
my @bridges = split(/\s+/, $server->{'kvm_hostifaces'});
my @models = split(/\s+/, $server->{'kvm_model'});
for(my $i=0; $i<@macs; $i++) {
	my $mac = $macs[$i];
	my $b = $bridges[$i];
	my $m = $models[$i];
	my ($iface) = grep { $_->{'fullname'} eq "eth".$i } @$rv;
	if ($iface) {
		$iface->{'ether'} = $mac eq '*' || $mac eq '' ? undef : $mac;
		$iface->{'bridge'} = $b eq '*' || $b eq '' ? undef : $b;
		$iface->{'model'} = $m eq '*' || $m eq '' ? undef : $m;
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

# type_kvm_create_interface(&server, &iface, [non-virtual], [bridge])
# Add and activate a virtual interface
sub type_kvm_create_interface
{
my ($server, $iface, $nonvirt, $bridge) = @_;

# Find a free interface number, if needed
my $vhost = &type_kvm_parent($server);
if ($nonvirt) {
	$iface->{'name'} =~ /^eth(\d+)$/ ||
		return "Only Ethernet intefaces can be created";
	my @nets = split(/\s+/, $server->{'kvm_net'});
	$1 == scalar(@nets) ||
		return "A new real interface must be named eth".scalar(@nets);
	$iface->{'fullname'} = $iface->{'name'};
	}
else {
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
	}

# Allocate IP, if needed
my @kvm_iface = split(/\s+/, $vhost->{'kvm_iface'});
my $idx = $iface->{'name'} =~ /^eth(\d+)/ ? $1 : 0;
$bridge ||= $kvm_iface[$idx];
if (!$iface->{'address'}) {
	my $cidr;
	($iface->{'address'}, $cidr) = &allocate_ip_address(
	    $vhost->{'kvm_start'}, $vhost->{'kvm_end'}, $vhost->{'kvm_cidr'},
	    $vhost->{'kvm_gws'}, $vhost->{'kvm_ifaces'}, $bridge);
	$iface->{'address'} ||
		return &text('create_ekvmalloc', $vhost->{'host'},
			    &describe_ip_range($vhost->{'kvm_start'},
					       $vhost->{'kvm_end'},
					       $vhost->{'kvm_cidr'},
					       $vhost->{'kvm_ifaces'},
					       $bridge));
	$iface->{'netmask'} = &net::prefix_to_mask($cidr);
	}

# Compute broadcast and network
$iface->{'up'} = 1;
$iface->{'broadcast'} = &net::compute_broadcast($iface->{'address'},
						$iface->{'netmask'});
$iface->{'network'} = &net::compute_network($iface->{'address'},
					    $iface->{'netmask'});

# Activate now if possible
if (&can_ssh_status($server) && !$nonvirt) {
	my $err = &create_active_server_interface($server, $iface);
	return $err if ($err);
	}

# Activate at boot
my $err = &mount_filesystem_if_needed($server);
return "Failed to mount filesystem : $err" if ($err);
$err = &create_boot_server_interface($server, $iface);
&umount_filesystem_if_needed($server);
return $err if ($err);

# Add to list of interfaces to activate at start time
if ($nonvirt) {
	my @macs = split(/\s+/, $server->{'mac'});
	my @models = split(/\s+/, $server->{'kvm_model'});
	while(scalar(@models) < scalar(@macs)) {
		push(@models, "*");
		}
	my @nets = split(/\s+/, $server->{'kvm_net'});
	my @ifaces = split(/\s+/, $server->{'kvm_hostifaces'});
	my $num = scalar(@nets);
	push(@macs, &generate_mac_address($server, $num));
	push(@models, $iface->{'model'} || "*");
	push(@nets, "tap,vlan=".$num);
	push(@ifaces, $bridge || '*');
	if ($bridge) {
		# Create script to attach correct bridge
		my ($data, $script) = &generate_kvm_bridge_script(
					$server, $iface, $bridge);
		my $err = &put_file_data_to_server($vhost, $data, $script);
		return "Failed to create script $script : $err" if ($err);
		&execute_command_on_server($vhost, "chmod +x $script");
		$nets[$#nets] .= ",script=$script";
		}
	$server->{'mac'} = join(" ", @macs);
	$server->{'kvm_model'} = join(" ", @models);
	$server->{'kvm_net'} = join(" ", @nets);
	$server->{'kvm_hostifaces'} = join(" ", @ifaces);
	$iface->{'reboot'} = 1;
	}

&add_ip_address($server, $iface->{'address'});
return undef;
}

# type_kvm_delete_interface(&server, &iface)
# Delete and de-activate a virtual interface
sub type_kvm_delete_interface
{
my ($server, $iface) = @_;
my $vhost = &type_kvm_parent($server);

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

# Remove from KVM config
my $idx = $iface->{'name'} =~ /^eth(\d+)/ ? $1 : undef;
if ($iface->{'virtual'} eq '' && defined($idx)) {
	my @macs = split(/\s+/, $server->{'mac'});
	my @models = split(/\s+/, $server->{'kvm_model'});
	while(scalar(@models) < scalar(@macs)) {
		push(@models, "*");
		}
	my @nets = split(/\s+/, $server->{'kvm_net'});
	my @ifaces = split(/\s+/, $server->{'kvm_hostifaces'});
	if ($nets[$idx] =~ /script=([^,]+)/) {
		# Has a custom script .. delete if under kvm dir
		my $script = $1;
		if ($script =~ /^\Q$vhost->{'kvm_dir'}\/\E/) {
			&delete_file_on_server($vhost, $script);
			}
		}
	splice(@macs, $idx, 1);
	splice(@models, $idx, 1);
	splice(@nets, $idx, 1);
	splice(@ifaces, $idx, 1);
	$server->{'mac'} = join(" ", @macs);
	$server->{'kvm_model'} = join(" ", @models);
	$server->{'kvm_net'} = join(" ", @nets);
	$server->{'kvm_hostifaces'} = join(" ", @ifaces);
	$iface->{'reboot'} = 1;
	}

&delete_ip_address($server, $iface->{'address'});
return undef;
}

# type_kvm_modify_interface(&server, &iface, &oldiface)
# Changes the active and boot-time IPs for an interface
sub type_kvm_modify_interface
{
my ($server, $iface, $oldiface) = @_;
my %oldserver = %$server;

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

# Change MAC and model address if non-virtual
if ($iface->{'virtual'} eq '') {
	my @macs = split(/\s+/, $server->{'mac'});
	my @models = split(/\s+/, $server->{'kvm_model'});
	while(scalar(@models) < scalar(@macs)) {
		push(@models, "*");
		}
	my $idx = $iface->{'name'} =~ /^eth(\d+)/ ? $1 : 0;
	$macs[$idx] = $iface->{'ether'} || '*';
	$models[$idx] = $iface->{'model'} || '*';
	$server->{'mac'} = join(" ", @macs);
	$server->{'kvm_model'} = join(" ", @models);
	}

return undef;
}

# type_kvm_list_models([&server])
# Returns a list of supported emulated network interface card models
# for some virtual system.
sub type_kvm_list_models
{
my ($server) = @_;
return [ [ "rtl8139", "Realtek 8139" ],
	 [ "i82551", "Intel 82551" ],
	 [ "i82557b", "Intel 82557b" ],
	 [ "i82559er", "Intel 82559er" ],
         [ "ne2k_pci", "NE2000 on PCI" ],
	 [ "ne2k_isa", "NE2000 on ISA" ],
	 [ "e1000", "Intel Gigabit Ethernet" ],
         [ "virtio", "VirtIO" ],
	 [ "pcnet", "PC-Net" ],
	 [ "lance", "Lance" ],
	 [ "mcf_fec", "MCF FEC" ] ];
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

# type_kvm_mount_filesystem(&server, [wantfile], [mount-point])
# Mounts a down KVM image's root disk image on /mnt/something, and sets
# kvm_mount in the server object
sub type_kvm_mount_filesystem
{
my ($server, $wantfile, $mp) = @_;
my $vhost = &type_kvm_parent($server);

# Create temp dir
$mp ||= "/mnt/kvm-".$server->{'host'};
my $err = &make_dir_on_server($vhost, $mp, 0700, 1);
return "Failed to create mount point $mp : $err" if ($err);
my $fsfile = $server->{'kvm_filesystem'};
if (!$fsfile) {
	return &text('create_ekvmfsfile');
	}

# If we don't know which partition is the primary, try them in series
if (!$server->{'kvm_filesystem_offset'} || $wantfile) {
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
		my @st = &stat_file_on_server($vhost,
					      $mp.($wantfile || "/etc"));
		if (@st) {
			# Found it! Leave mounted
			$server->{'kvm_mount'} = $mp;
			if (!$wantfile) {
				$server->{'kvm_filesystem_offset'} = $o;
				}
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
my $procs = &list_kvm_instances($vhost);
if (!ref($procs)) {
	# Host may be down .. ping to see
	my $vping = &ping_server_host($vhost->{'ip'});
	if ($vping) {
		return (1, "Could not fetch KVM instances : $procs");
		}
	else {
		return (5, "Could not fetch KVM instances, host is probably ".
			   "down : $procs");
		}
	}
my ($proc) = grep { $_->{'filesystem'} eq $server->{'kvm_filesystem'} } @$procs;
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

# Cache label->partition map, for use when the system is down
if (&can_ssh_status($server) && (!defined($server->{'label_map'}) || $regen)) {
	&generate_label_map($server);
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

# Additional command line args
if ($server->{'kvm_args'}) {
	$rv .= &ui_table_row($text{'edit_kvmargs'},
		"<tt>".&html_escape($server->{'kvm_args'})."</tt>");
	}

# Disk mode
$rv .= &ui_table_row($text{'edit_kvmdriver'},
	$server->{'kvm_virtio'} ? "VirtIO" : "IDE");

# Console keymap
$rv .= &ui_table_row($text{'edit_kvmkeymap'},
	&ui_select('kvm_keymap', $server->{'kvm_keymap'},
		   [ [ '', "&lt;$text{'default'}&gt;" ],
		     sort { $a->[1] cmp $b->[1] }
			  &list_kvm_keymaps($server) ]));

return $rv;
}

# type_kvm_edit_parse(&server, &in)
# Update a server based on inputs from type_kvm_edit_form
sub type_kvm_edit_parse
{
my ($server, $in) = @_;
if ($in->{'kvm_keymap'} eq '') {
	delete($server->{'kvm_keymap'});
	}
else {
	my @keymaps = &list_kvm_keymaps($server);
	my ($k) = grep { $_->[0] eq $in->{'kvm_keymap'} } @keymaps;
	$k || &error($text{'edit_ekvmkeymap'});
	$server->{'kvm_keymap'} = $k->[0];
	&type_kvm_set_atboot($server, 2);
	}
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
if ($server->{'kvm_args'}) {
	push(@rv, [ "KVM command line args", $server->{'kvm_args'} ]);
	}
push(@rv, [ "KVM disk driver", $server->{'kvm_virtio'} ? "VirtIO" : "IDE" ]);
if ($server->{'kvm_keymap'}) {
	push(@rv, [ "KVM console keyboard type", $server->{'kvm_keymap'} ]);
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
if (&can_ssh_status($server)) {
	my @bridges = &list_host_bridges($server);
	if (@bridges) {
		push(@rv, [ "KVM network bridges", join(" ", @bridges) ]);
		}
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
	$l =~ s/^\s*\/\S+\/pty.pl(\s+\-\-(\S+)\s+(\S+))*\s+//;
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
&create_kvm_monitor_file($server);
my $cmd = "/usr/bin/pty.pl --sleep 2 ".&get_kvm_start_command($server).
	  " >$server->{'kvm_console'} 2>&1 <$server->{'kvm_monitor'} &";
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
		my $line = $lref->[$i];
		$line =~ s/^\s*\/\S+\/pty.pl(\s+\-\-(\S+)\s+(\S+))*\s+//;
		my $kvm = &parse_kvm_start_command($line);
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
	}
else {
	&$second_print(&text('create_xenmounted',
			     "<tt>$server->{'kvm_mount'}</tt>"));

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
	}

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
$image->{'format'} = 'disk';
$image->{'kvm_virtio'} = $server->{'kvm_virtio'};

if (!$image->{'nocompress'}) {
	# Compress disk image to a temp file
	&$first_print($text{'mkimage_xengzip'});
	my $gzfile = $image->{'id'}.".ext3.gz";
	my ($out, $ex, $err) = &execute_command_on_server($vhost,
	    ($server->{'kvm_filesystem_lv'} ?
		&dd_command($fsfile, undef)." | gzip -c" :
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
			&dd_command($fsfile, "$tempdir/$imgfile") :
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
	}
else {
	&$second_print(&text('create_xenmounted',
			     "<tt>$server->{'kvm_mount'}</tt>"));

	# Undo all munged files
	&unmunge_all_files($server, $server->{'munged'});
	delete($server->{'munged'});

	# Un-mount KVM filesystem
	&$first_print($text{'mkimage_kvmumount'});
	&type_kvm_umount_filesystem($server);
	&$second_print($text{'create_done'});
	}

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

# Make sure /dev/loop1 exists
my @st = &stat_file_on_server($server, "/dev/loop1");
@st || return &text('kvm_eloop', "<tt>/dev/loop1</tt>");

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
	my $mkerr = &create_backup_dest_dir($vhost, $tarfile);
	return { 'ok' => 0,
		 'msg' => &text('brun_emkdir', $mkerr) } if ($mkerr);
	}
elsif (&can_transfer_directly($dest)) {
	# Transferring directly to dest host
	if (!$destserver) {
		return { 'ok' => 0, 'msg' => $text{'brun_edestserver'} };
		}
	my $mkerr = &create_backup_dest_dir($destserver, $dest->{'path'});
	return { 'ok' => 0,
		 'msg' => &text('brun_emkdir', $mkerr) } if ($mkerr);
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
		&delete_all_disk_image_partitions($vhost, $snaplv);
		&remote_foreign_call($vhost, "lvm",
				     "delete_logical_volume", $snaplv);
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
		my $ddcmd = &dd_command($dev, "$tempdir/$devfile")." 2>&1";
		$ddcmd = &niced_backup_command($vhost, $ddcmd);
		my ($out, $ex, $err) = &execute_command_on_server(
					$vhost, $ddcmd);
		if ($ex || $err) {
			$ddfail = &text('brun_edd', $dev, $err || $out);
			last;
			}
		}

	# Tar up temp dir
	if (!$ddfail && $tarfile) {
		# To temp file
		&$first_print(&text('brun_tarring3', $server->{'host'}));
		my $tarcmd = "cd ".quotemeta($tempdir)." && ".
			     "tar cf - . | gzip -c >".quotemeta($tarfile);
		$tarcmd = &niced_backup_command($vhost, $tarcmd);
		my ($out, $ex, $err) = &execute_command_on_server(
					$vhost, $tarcmd);
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
		$tarcmd = &niced_backup_command($vhost, $tarcmd);
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
			&delete_all_disk_image_partitions($vhost, $snaplv);
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
		my $tarcmd = "cd ".quotemeta($dir)." && ".
			    "tar cf - ".join(" ", map { quotemeta($_) } @paths).
			    " | gzip -c >".quotemeta($tarfile);
		$tarcmd = &niced_backup_command($vhost, $tarcmd);
		my ($out, $ex, $err) = &execute_command_on_server(
					$vhost, $tarcmd);
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
		$tarcmd = &niced_backup_command($vhost, $tarcmd);
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
			my $tarcmd = "gunzip -c ".quotemeta($tarfile).
				     " | tar Oxpf - $devfile ./$devfile".
				     " | ".&dd_command(undef, $d->{'real'}).
				     "2>&1";
			$tarcmd = &niced_backup_command($vhost, $tarcmd);
			my ($out, $ex, $err) = &execute_command_on_server(
						$vhost, $tarcmd);
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
				     " | ".&dd_command(undef, $d->{'real'});
			$tarcmd = &niced_backup_command($vhost, $tarcmd);
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
		my $tarcmd = "cd ".quotemeta($dir)." && ".
			     "gunzip -c ".quotemeta($tarfile)." | tar xpf -";
		$tarcmd = &niced_backup_command($vhost, $tarcmd);
		my ($out, $ex, $err) = &execute_command_on_server(
					$vhost, $tarcmd);
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
		$tarcmd = &niced_backup_command($vhost, $tarcmd);
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
# Returns 2 indicating than manual moves are supported too, or 3 indicating
# that only manual moves are possible.
sub type_kvm_can_move
{
my ($server, $dest) = @_;
if (!$dest ||
    $dest->{'status'} eq 'virt' ||
    $dest->{'status'} eq 'nowebmin' ||
    $dest->{'status'} eq 'novirt') {
	# Dest is OK
	if ($server->{'status'} eq 'nohost') {
		# Parent is down, only manual moves possible
		return 3;
		}
	else {
		return 2;
		}
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
	&check_server_status($server, 0, 1);
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
		&remote_finished();
		$last_remote_error = undef;
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

# Fix monitoring and console paths
if ($dest->{'kvm_dir'} ne $vhost->{'kvm_dir'}) {
	$server->{'kvm_monitor'} =~
		s/\Q$vhost->{'kvm_dir'}\E/$dest->{'kvm_dir'}/;
	$server->{'kvm_console'} =~
		s/\Q$vhost->{'kvm_dir'}\E/$dest->{'kvm_dir'}/;
	}

# Copy across bridge scripts
my @nets = split(/\s+/, $server->{'kvm_net'});
foreach my $net (@nets) {
	if ($net =~ /script=([^,]+)/) {
		my $script = $1;
		my $newscript = $script;
		$newscript =~ s/^.*[\\\/]//;
		$newscript = "$dest->{'kvm_dir'}/$newscript";
		my @st = &stat_file_on_server($dest, $newscript);
		if ($script =~ /^\Q$vhost->{'kvm_dir'}\/\E/ && !@st) {
			my $err = &transfer_file_between_servers($vhost, $dest,
					$script, $newscript, 0, 1);
			if ($err) {
				return &text('smove_ebridge', $script, $err);
				}
			&delete_file_on_server($vhost, $script);
			if ($script ne $newscript) {
				$net =~ s/script=\Q$script\E/script=$newscript/;
				}
			}
		}
	}
$server->{'kvm_net'} = join(" ", @nets);

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
	if (@dellvs) {
		&remote_finished();
		&remote_foreign_require($vhost, "lvm", "lvm-lib.pl");
		}
	foreach my $f (@dellvs) {
		&delete_all_disk_image_partitions($vhost, $f);
		&remote_foreign_call($vhost, "lvm", "delete_logical_volume",
				     { 'device' => $f });
		my ($vg, $lv) = &split_lvm_device($f);
		my $srcf = &find_snapshot_source_logical_volume(
				\%oldserver, $vg, $lv);
		if ($srcf) {
			# Delete snapshot source if no longer in use
			&delete_all_disk_image_partitions($vhost, $srcf);
			&delete_mapper_entries($vhost, "$vg-$lv");
			&remote_foreign_call($vhost, "lvm",
					     "delete_logical_volume",
					     { 'device' => $srcf });
			}
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

# type_kvm_manual_move_system(&server, &dest)
# Update the configs to reflect a system move already done
sub type_kvm_manual_move_system
{
my ($server, $dest) = @_;
my $vhost = &get_parent_server($server);
$server->{'kvm_on'} = $dest->{'id'};

# Check if disks exist on target
&$first_print($text{'smove_checkdisks'});
my $disks = &type_kvm_list_disks($server, 0);
return $disks if (!ref($disks));
foreach my $d (@$disks) {
	my @dst = &stat_file_on_server($dest, $d->{'real'});
	if (!@dst) {
		return &text('smove_echeckdisk', $d->{'real'});
		}
	}
&$second_print($text{'smove_checkdisksok'});

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

	# Make sure we have a disk image we can use
	if (!$proc->{'filesystem'}) {
		&$second_print($text{'find_kvmfs'});
		next;
		}
	my $parts = &list_disk_image_partitions($vhost, $got->{'filesystem'});
	if (!ref($parts) || !@$parts) {
		my ($out, $ex, $err) = &execute_command_on_server($vhost, 
			"qemu-img info ".quotemeta($proc->{'filesystem'}));
		if ($out !~ /file\s+format:\s+(\S+)/i || $1 ne "raw") {
			&$second_print(&text('find_kvmfsraw',
					     "<tt>$proc->{'filesystem'}</tt>"));
			next;
			}
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
	if ($server->{'type'} eq 'unknown' || !$server->{'type'}) {
		my $guess = &guess_os_type($server);
		if ($guess) {
			$server->{'type'} = $guess;
			&check_server_status($server, 0, 1);
			}
		}
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

# list_kvm_keymaps([&server])
# Returns a list of array refs, each containing a keymap code and description
sub list_kvm_keymaps
{
return (
	[ "ar", "Arabic" ],
	[ "de-ch", "German (Switzerland)" ],
        [ "es", "Spanish" ],
	[ "fo", "Faeroese" ],
        [ "fr-ca", "French (Canada)" ],
	[ "hu", "Hungarian" ],
	[ "ja", "Japanese" ],
	[ "mk", "FYRO Macedonian" ],
	[ "no", "Norwegian" ],
	[ "pt-br", "Portuguese (Brazil)" ],
	[ "sv", "Swedish" ],
	[ "da", "Danish" ],
	[ "en-gb", "English (United Kingdom)" ],
	[ "et", "Estonian" ],
	[ "fr", "French" ],
	[ "fr-ch", "French (Switzerland)" ],
	[ "is", "Icelandic" ],
	[ "lt", "Lithuanian" ],
	[ "nl", "Dutch" ],
	[ "pl", "Polish" ],
	[ "ru", "Russian" ],
	[ "th", "Thai" ],
	[ "de", "German" ],
	[ "en-us", "English (United States)" ],
	[ "fi", "Finnish" ],
	[ "fr-be", "French (Belgium)" ],
	[ "hr", "Croatian" ],
	[ "it", "Italian" ],
	[ "lv", "Latvian" ],
	[ "nl-be", "Dutch (Belgium)" ],
	[ "pt", "Portuguese" ],
	[ "sl", "Slovenian" ],
	[ "tr", "Turkish" ],
	);
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
			if ($ah->{$lastarg} && !ref($ah->{$lastarg})) {
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
				$v->[@$v-1] .= " " if ($v->[@$v-1]);
				$v->[@$v-1] .= $a;
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
return undef if (!ref($procs));
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

# type_kvm_available_ip_addresses(&server)
# Returns a list of hash refs for IPs available on some system
sub type_kvm_available_ip_addresses
{
my ($server) = @_;
my $vhost = &get_parent_server($server);
return &available_ip_addresses($vhost->{'kvm_start'},
			       $vhost->{'kvm_end'},
			       $vhost->{'kvm_cidr'},
			       $vhost->{'kvm_gws'});
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
return ( "disk", "qcow2", "qcow", "vmdk", "cd" );
}

# type_kvm_can_clone(&server)
# Any KVM instance can be cloned, if the host system is up.
# Returns 2 if on LVM, which allows cloning without shutdown
sub type_kvm_can_clone
{
my ($server) = @_;
return $server->{'status'} eq 'nohost' ? 0 :
       $server->{'kvm_filesystem_vg'} ? 2 : 1;
}

# type_kvm_check_clone(&oldserver, &newserver, new-hostname, &ips, snapshot)
# Checks if cloning of some system will work, before shutting it down. Returns
# undef on success or an error message on failure.
sub type_kvm_check_clone
{
my ($oldserver, $newserver, $newhost, $ips, $snapshot) = @_;
my $vhost = &type_kvm_parent($newserver);

# Make sure hostname is sensible
if ($vhost->{'kvm_zone'}) {
	return $text{'clone_ehost2'} if ($newhost =~ /\./);
	}

# Check for IPs if needed
if (!$vhost->{'kvm_start'}) {
	$ips && scalar(@$ips) || return &text('clone_eips', $vhost->{'host'});
	}
if ($ips) {
	my @oldips = split(/\s+/, $oldserver->{'kvm_ip'});
	scalar(@oldips) == scalar(@$ips) ||
		return &text('clone_eips2', scalar(@oldips), scalar(@$ips));
	}

# Make sure all disks are on LVM if snapshotting
if ($snapshot) {
	my $disks = &type_kvm_list_disks($newserver, 0);
	foreach my $d (@$disks) {
		next if ($d->{'device'} && !$d->{'lv'});
		$d->{'lv'} || return &text('clone_elvm', $d->{'real'});
		}
	}

return undef;
}

# type_kvm_clone_system(&oldserver, &newserver, new-hostname, &ips, snapshot)
# Creates a clone of some KVM instance, updating the newserver hash.
# Returns an error message and a flag indicating if the failure was total or
# only partial.
sub type_kvm_clone_system
{
my ($oldserver, $newserver, $newhost, $ips, $snapshot) = @_;
my $vhost = &type_kvm_parent($newserver);

# Generate the new full hostname
if ($vhost->{'kvm_zone'}) {
	$newserver->{'host'} = $newhost.".".$vhost->{'kvm_zone'};
	}
else {
	$newserver->{'host'} = $newhost;
	}
my $clash = &get_managed_server_by("host", $newserver->{'host'});
if ($clash) {
	return (&text('clone_eclash', $newserver->{'host'}), 1);
	}

# Allocate new IP addresses
if ($ips) {
	# Use supplied list, keep old netmasks and gateways
	$newserver->{'kvm_ip'} = join(" ", @$ips);
	}
else {
	# Allocate new IPs
	&$first_print($text{'clone_allocating'});
	my $err = &allocate_kvm_ip_addresses($newserver, $vhost);
	return ($err, 1) if ($err);
	}
my @ips = split(/\s+/, $newserver->{'kvm_ip'});
my @cidrs = split(/\s+/, $newserver->{'kvm_cidr'});
my @netmasks = map { &net::prefix_to_mask($_) } @cidrs;
my $defgw = &get_server_default_gateway($vhost);
my @gws = split(/\s+/, $newserver->{'kvm_gw'});
my @setgws = grep { $_ ne "*" } @gws;
if (!@setgws && $defgw) {
	@gws = ( $defgw );
	}
$newserver->{'ip_addresses'} = join(" ", @ips);
&complete_managed_server($newserver);
if (!$ips) {
	&$second_print(&text('clone_allocated', join(" ", @ips)));
	}
delete($newserver->{'kvm_console'});

# Copy each of the disks and update the kvm_drives setting
&$first_print(&text('clone_copydisks'));
my $disks = &type_kvm_list_disks($newserver, 1);
if (!ref($disks)) {
	$disks = &type_kvm_list_disks($newserver, 0);
	}
if (!ref($disks)) {
	return (&text('clone_ecopydisks', $disks), 1);
	}
&$indent_print();
my @disklist;
my $oldkvm = $oldserver->{'host'};
my $oldkvm_us = $oldkvm;
$oldkvm_us =~ s/\./_/g;
my $newkvm = $newserver->{'host'};
my $newkvm_us = $newkvm;
$newkvm_us =~ s/\./_/g;
my @olddrives = split(/\s+/, $newserver->{'kvm_drives'});
my @drives;
my $i = 0;
foreach my $d (@$disks) {
	&$first_print(&text('clone_copydisk', $d->{'real'}));
	if ($d->{'device'} && !$d->{'lv'}) {
		# A real device, which shouldn't be touched
		push(@drives, $olddrives[$i]);
		&$second_print(&text('smove_devdisk'));
		$i++;
		next;
		}
	my $err;
	my $snapped = 0;
	if ($d->{'lv'}) {
		# Pick a new LV name
		my $newlv = $d->{'lv'};
		if ($newlv =~ /\Q$oldkvm\E/) {
			$newlv =~ s/\Q$oldkvm\E/$newkvm/;
			}
		elsif ($newlv =~ /\Q$oldkvm_us\E/) {
			$newlv =~ s/\Q$oldkvm_us\E/$newkvm_us/;
			}
		else {
			$newlv .= "-".$newkvm_us;
			}
		$d->{'newreal'} = "/dev/".$d->{'vg'}."/".$newlv;

		# Create the new LV
		$last_remote_error = undef;
		my $lv = { 'name' => $newlv,
			   'size' => int($d->{'size'}/1024),
			   'perm' => 'rw',
			   'alloc' => 'n',
			   'vg' => $d->{'vg'} };
		if ($snapshot) {
			$lv->{'is_snap'} = 1;
			$lv->{'snapof'} = $d->{'lv'};
			$snapped = 1;
			}
		&remote_finished();
		&remote_foreign_require($vhost, "lvm", "lvm-lib.pl");
		$err = &remote_foreign_call($vhost, "lvm",
					  "create_logical_volume", $lv);
		$err ||= $last_remote_error;

		if (!$err && !$snapshot) {
			# Copy the data using dd
			$err = &transfer_file_between_servers(
			    $vhost, $vhost,
			    $d->{'real'}, $d->{'newreal'}, 1, 1,
			    int($d->{'size'}/(1024*1024))*1024*1024);
			}
		elsif (!$err && !$d->{'swap'} && $snapshot &&
		       &type_kvm_can_fsck($server, $d)) {
			# Fsck the disk after snapshotting
			my $newd = { %$d };
			$newd->{'real'} = $d->{'newreal'};
			$newd->{'lv'} = $newlv;
			my ($ok, $out) = &type_kvm_fsck_disk($server, $newd, 0);
			}
		}
	else {
		# Pick a new filename
		$d->{'newreal'} = $d->{'real'};
		if ($d->{'newreal'} =~ /\Q$oldkvm\E/) {
			$d->{'newreal'} =~ s/\Q$oldkvm\E/$newkvm/;
			}
		else {
			$d->{'newreal'} .= "-".$newkvm;
			}
		# Copy the file
		$err = &transfer_file_between_servers($vhost, $vhost,
                                $d->{'real'}, $d->{'newreal'}, 0, 1);
		}

	if ($err) {
		# Failed .. but may be skippable
		&$second_print(&text('clone_ecopydisk', $err));
		if ($newserver->{'kvm_filesystem'} eq $d->{'real'}) {
			return (&text('clone_ecopydiskfatal', $err), 1);
			}
		}
	else {
		# Fix drive paths
		my $drive = $olddrives[$i];
		$drive =~ s/\Q$d->{'real'}\E/$d->{'newreal'}/;
		push(@drives, $drive);
		if ($newserver->{'kvm_filesystem'} eq $d->{'real'}) {
			$newserver->{'kvm_filesystem'} = $d->{'newreal'};
			}
		if ($newserver->{'kvm_swapfile'} eq $d->{'real'}) {
			$newserver->{'kvm_swapfile'} = $d->{'newreal'};
			}
		&$second_print(&text($snapped ? 'clone_snapdiskdone'
					      : 'clone_copydiskdone',
				     $d->{'newreal'}));
		$i++;
		}
	}
&$outdent_print();
$newserver->{'kvm_drives'} = join(" ", @drives);
&$second_print($text{'create_done'});

# Register in DNS
if ($vhost->{'kvm_zone'}) {
	my $dnsname = $newhost.".".$vhost->{'kvm_zone'}.".";
	if (&add_bind8_record($dnsname, $ips[0],
			      $vhost->{'kvm_zone'})) {
		$newserver->{'kvm_dns'} = $dnsname;
		}
	else {
		delete($newserver->{'kvm_dns'});
		}
	}

# Mount the filesystem
&$first_print($text{'create_xenmount'});
my $err = &mount_filesystem_if_needed($newserver);
my $mp = $newserver->{'kvm_mount'};
if ($err || !$mp) {
	$err ||= "No mount point found!";
	&$second_print(&text('create_ekvmmount', $err));
	return ($err, 0);
	}
&$second_print(&text('create_xenmounted', "<tt>$mp</tt>"));

# Delete any virtual network interfaces if possible
if (&type_kvm_can_interfaces($newserver)) {
	my $ifaces = &type_kvm_list_interfaces($newserver);
	if (ref($ifaces)) {
		foreach my $i (@$ifaces) {
			if ($i->{'virtual'} ne '' ||
			    $i->{'fullname'} =~ /^eth(\d+)$/ &&
			    $1 >= scalar(@ips)) {
				&type_kvm_delete_interface($newserver, $i);
				}
			}
		}
	}

# Generate new MAC addresses
my @oldmacs = split(/\s+/, $newserver->{'mac'});
my @macs;
for(my $i=0; $i<@oldmacs; $i++) {
	push(@macs, &generate_mac_address($newserver, $i));
	}
$newserver->{'mac'} = join(" ", @macs);

# Fix other config files that refer to the hostname or IP
&$first_print($text{'create_xenfix'});
my $fullhost = $vhost->{'kvm_zone'} ? 
		$newhost.".".$vhost->{'kvm_zone'} : $newhost;
my $err = &fix_hostname_config_files($newserver, $ips[0],
					$newserver->{'host'}, $fullhost, $vhost,
					$mp, $vhost->{'kvm_resolv'});
if ($err) {
	&$second_print(&text('create_ekvmfix', $err));
	}       
else {
	&$second_print($text{'create_done'});
	}

# Setup networking config files to use the IP.
&$first_print($text{'create_xennet'});
my $err = &fix_network_config_files($newserver, $ips[0], $netmasks[0],
				    $gws[0], $vhost, $mp);
if ($err) {
	&$second_print(&text('create_ekvmnet', $err));
	}       
else {
	&$second_print($text{'create_done'});
	}

# Add network configs for extra IPs
if (@ips > 1) {
	&$first_print($text{'create_xennet2'});
	my $err = &fix_additional_network_interface_files($newserver,
		[ @ips[1..$#ips] ], [ @netmasks[1..$#netmasks] ],
		[ @gws[1..$#gws] ], $vhost, $mp);
	if ($err) {
		&$second_print(&text('create_ekvmnet2', $err));
		}       
	else {
		&$second_print($text{'create_done'});
		}
	}

# Un-mount
&$first_print($text{'create_xenumount'});
&umount_filesystem_if_needed($newserver);
&$second_print($text{'create_done'});

# Add DHCP entries
if ($config{'dhcp_add'}) {
	# Get MAC addresses
	my $fakeifaces = &type_kvm_list_interfaces($newserver, 1);
	if (ref($fakeifaces)) {
		&add_all_iface_dhcpd($newserver, $fakeifaces);
		}
	}

# Copy network bridge scripts
my @nets = split(/\s+/, $newserver->{'kvm_net'});
foreach my $net (@nets) {
	if ($net =~ /script=([^,]+)/) {
		my $script = $1;
		my $newscript = $script;
		$newscript =~ s/\Q$oldkvm\E/$newkvm/g;
		my $err = &transfer_file_between_servers($vhost, $vhost,
				$script, $newscript);
		if ($err) {
			&$second_print(&text('smove_ebridge', $script, $err));
			}
		if ($script ne $newscript) {
			$net =~ s/script=\Q$script\E/script=$newscript/;
			}
		}
	}
$newserver->{'kvm_net'} = join(" ", @nets);

# Fix up other config entries using the old name
foreach my $f ('kvm_filesystem_lv', 'kvm_swapfile_lv',
	       'kvm_console', 'kvm_monitor', 'login_user', 'data_files') {
	$newserver->{$f} =~ s/\Q$oldkvm_us\E/$newkvm_us/g;
	$newserver->{$f} =~ s/\Q$oldkvm\E/$newkvm/g;
	}

return (undef, 0);
}

# type_kvm_can_failover([&server, [&new-dest]])
# Return 1 if this virtual system can be failed over to a new host
sub type_kvm_can_failover
{
my ($server, $newvhost) = @_;
if (!$server) {
	# Failovers are supported for KVM, in theory
	return 1;
	}
if ($server && $newvhost) {
	# Make sure disks exist on target
	return 0 if (!$server->{'data_files'});
	foreach my $f (split(/\s+/, $server->{'data_files'})) {
		my @st = &stat_file_on_server($newvhost, $f);
		return 0 if (@st <= 1);
		}
	return 1;
	}
return 1;
}

# type_kvm_get_data_files(&server)
# Returns a list of files/directories that this virtual system uses for
# storage. Used when failing over to verify that storage is shared.
sub type_kvm_get_data_files
{
my ($server) = @_;
my $disks = &type_kvm_list_disks($server, 0);
return ( ) if (!ref($disks));
return map { $_->{'real'} } @$disks;
}

# type_kvm_failover_system(&server, &dest)
# Has nothing to do really, as KVM has no config files to copy.
sub type_kvm_failover_system
{
my ($server, $dest) = @_;
my $vhost = &get_parent_server($server);
$server->{'kvm_on'} = $dest->{'id'};
return undef;
}

# type_kvm_list_boot_devices(&server)
# Returns an array ref of available boot devices for some system, or an error
# message. Each entry is a hash ref with keys :
# id - Unique ID for this mode
# desc - Human-readable description
sub type_kvm_list_boot_devices
{
my ($server) = @_;
return [ { 'id' => 'a',
	   'desc' => 'Floppy disk' },
	 { 'id' => 'c',
	   'desc' => 'Hard disk' },
	 { 'id' => 'd',
	   'desc' => 'CD or DVD drive' },
	 { 'id' => 'n',
	   'desc' => 'Network' } ];
}

# type_kvm_get_boot_device(&server)
# Returns a status code (1 or 0) and either the boot dev ID or an error message
sub type_kvm_get_boot_device
{
my ($server) = @_;
return (1, $server->{'kvm_bootdevice'} || 'c');
}

# type_kvm_set_boot_device(&server, mode)
# Sets the boot device based on some ID. Returns undef on success, or an error
# message on failure.
sub type_kvm_set_boot_device
{
my ($server, $mode) = @_;
$server->{'kvm_bootdevice'} = $mode;
return undef;
}

# create_kvm_monitor_file(&server)
# Create a file on the host system for KVM monitor input, and uploads pty.pl
sub create_kvm_monitor_file
{
my ($server) = @_;
my $vhost = &type_kvm_parent($server);

# Work out monitor input location
if (!$server->{'kvm_monitor'}) {
	my $mon = $server->{'kvm_console'} || &get_kvm_console_file($server);
	if ($mon !~ s/\.console$/\.monitor/) {
		$mon .= ".monitor";
		}
	$server->{'kvm_monitor'} = $mon;
	}
my @mlines;

# Copy pty.pl
my $perr = &put_file_to_server($vhost,
		"$module_root_directory/pty.pl", "/usr/bin/pty.pl");
return $perr if ($perr);

$server->{'kvm_vnc_passwd'} ||= $server->{'ssh_pass'} ||
			        &generate_random_password();
push(@mlines, "change vnc password");
push(@mlines, $server->{'kvm_vnc_passwd'});

# Write out monitor input
return &put_file_data_to_server($vhost, join("", map { $_."\n" } @mlines),
			 	$server->{'kvm_monitor'});
}

1;

