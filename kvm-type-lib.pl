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
	push(@rv, { 'create' => 1,
		    'desc' => $text{'kvm_createlink'} });
	}
return @rv;
}

# Returns a link to the page list kvm-capable systems
sub type_kvm_global_links
{
if ($module_info{'onehost'} eq 'kvm') {
	# Page for just this KVM host
        return ( { 'link' => 'edit_kvm.cgi?id=0',
                   'icon' => 'images/kvms.gif',
                   'title' => $text{'kvm_editone'},
                   'cat' => 'hosts' } );
	}
else {
	# List of KVM hosts
	return ( { 'link' => 'list_kvms.cgi',
		   'icon' => 'images/kvms.gif',
		   'title' => $text{'kvms_title'},
		   'cat' => 'hosts' } );
	}
}

# can_host_kvm(&server)
# Returns 1 if some server is of a type that we can do KVM hosting on
sub can_host_kvm
{
my ($server) = @_;
return $server->{'manager'} eq 'this' || $server->{'manager'} eq 'real' ||
       ($server->{'manager'} eq 'kvm' && $config{'kvm_on_kvm'});
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
if ($got->{'filesystem'} =~ /^\/dev\/([^\/]+)\/([^\/]+)$/) {
	# On LVM
	$server->{'kvm_filesystem_vg'} = $1;
	$server->{'kvm_filesystem_lv'} = $2;
	}
elsif ($got->{'filesystem'} =~ /^\/dev\/disk\/by-path\/ip-(\S+):(\d+)-iscsi-(\S+):(\S+)-lun-(\d+)$/) {
	# On an ISCSI server
	my ($ip, $port, $name, $target, $lun) = ($1, $2, $3, $4, $5);
	my $iscsiserver = &get_managed_server_by("ip", $ip);
	if ($iscsiserver) {
		$server->{'kvm_filesystem_iscsi'} = $iscsiserver->{'id'};
		}
	$server->{'kvm_filesystem_name'} = $name;
	$server->{'kvm_filesystem_target'} = $target;
	$server->{'kvm_filesystem_ip'} = $ip;
	$server->{'kvm_filesystem_port'} = $port;
	}

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
$server->{'kvm_model'} = join(" ", @models);
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
	my @s = split(/,/, $got->{'args'}->{'smp'});
	$server->{'kvm_smp'} = $s[0];
	foreach my $s (@s) {
		if ($s =~ /cores=(\d+)/) {
			$server->{'kvm_smp_cores'} = $1;
			}
		elsif ($s =~ /sockets=(\d+)/) {
			$server->{'kvm_smp_cores'} = $s[0] / $1;
			}
		}
	}
delete($got->{'args'}->{'smp'});

# Save VGA mode
if (defined($got->{'args'}->{'std-vga'}) ||
    $got->{'args'}->{'vga'} eq 'std') {
	$server->{'kvm_vga'} = 1;
	}
delete($got->{'args'}->{'std-vga'});

# Save monitor port, if any
if ($got->{'args'}->{'monitor'} =~ /tcp:(localhost|127.0.0.1):(\d+),server/) {
	$server->{'kvm_monitor_port'} = $2;
	}

# Delete args we don't need to save
delete($got->{'args'}->{'name'});
delete($got->{'args'}->{'serial'});
delete($got->{'args'}->{'vnc'});
delete($got->{'args'}->{'nographic'});
delete($got->{'args'}->{'monitor'});
delete($got->{'args'}->{'S'});
delete($got->{'args'}->{'usbdevice'});

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
	my @hostifaces = grep { &can_use_bridge($_) }
			      split(/\s+/, $vhost->{'kvm_iface'});
	if (scalar(@hostifaces) > $max_hostifaces) {
		$max_hostifaces = scalar(@hostifaces);
		}
	}
my @v6vhosts = grep { $_->{'kvm_pool6'} } @vhosts;

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
		my @allifaces;
		my $sfx = $empty ? "empty" : "";
		foreach my $vhost (@vhosts) {
			my $vtable = &ui_columns_start([
				$text{'create_xenifacecol'},
				$text{'create_xenipcol'},
				$text{'create_xennetmaskcol'},
				$text{'create_xengwcol'}]);
			my @ifaces = grep { &can_use_bridge($_) }
					split(/\s+/, $vhost->{'kvm_iface'});
			push(@allifaces, @ifaces);
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
				   "id=$sfx$vhost->{'id'}>".$vtable."</div>\n";
			}
		@allifaces = &unique(@allifaces);

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
				   "id=${sfx}loc>".$vtable."</div>\n";
			}

		# Build bridge selector
		my $bsel;
		if (@allifaces > 1) {
			$bsel = $text{'create_xenipbridges'};
			foreach my $b (@allifaces) {
				$bsel .= " ".&ui_checkbox("kvm_bridge",
							  $b, $b, 1);
				}
			}

		$rv .= &ui_table_row($text{'create_kvmip2'},
			&ui_radio("kvm_ip_def", 1,
			  [ [ 1, $text{'create_xenipauto'}."<br>" ],
			    $bsel ? ( [ 2, $bsel."<br>" ] ) : ( ),
			    [ 0, $text{'create_xenipman2'}."<br>\n".
				 $itable ] ]));

		# Javascript for host change
		$rv .= "<script>\n";
		$rv .= "function host_change(id)\n";
		$rv .= "{\n";
		foreach my $vhost (@vhosts) {
			$rv .= "var divobj = ".
		           "document.getElementById('$sfx$vhost->{'id'}');\n";
			$rv .= "divobj.className = id == '$vhost->{'id'}' ? ".
			   "'opener_shown' : 'opener_hidden';\n";
			}
		$rv .= "var divobj = document.getElementById('${sfx}loc');\n";
		$rv .= "if (divobj) {\n";
		$rv .= "    divobj.className = id == '${sfx}loc' ? 'opener_shown' : ".
		       "'opener_hidden';\n";
		$rv .= "    }\n";
		$rv .= "}\n";
		$rv .= $hostjs;
		$rv .= "</script>\n";
		}
	}

if (&can_action(undef, "ips") && @v6vhosts && !$empty) {
	# IPv6 address
	$rv .= &ui_table_row($text{'create_kvmip6'},
		&ui_radio_table("kvm_ip6_mode", $config{'alloc_ipv6'} || 0,
				[ [ 0, $text{'create_kvmip6no'} ],
				  [ 1, $text{'create_kvmip6alloc'} ],
				  [ 2, $text{'create_kvmip6manual'},
				       &ui_textbox("kvm_ip6", undef, 30)." ".
				       $text{'create_kvmip6netmask'}." ".
				       &ui_textbox("kvm_netmask6", 64, $short_timeout) ] ],
				1));

	# Default IPv6 gateway
	$rv .= &ui_table_row($text{'create_xengw6'},
		&ui_opt_textbox("kvm_gw6", undef, 20,
				$text{'create_xengwdef'},
				$text{'create_xengwip6'}));
	}

# Warn the user if we have no DNS zone
if (@vhosts == 1 && $module_info{'onehost'} eq 'kvm' &&
    !$vhosts[0]->{'kvm_zone'}) {
        $rv .= &ui_table_row(" ",
                "<font color=#ff000>".
                &text('create_kvmdnswarn', "edit_kvm.cgi?id=0", "../bind8/").
                "</font>");
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

# Swap space
if (!$empty && &can_action(undef, 'swap')) {
	$rv .= &ui_table_row($text{'create_xenswapsize'},
		&vui_opt_bytesbox("kvm_swap",
				  $config{'kvm_swap'}*1024*1024 || undef, 8,
				  $text{'create_xennoswap'}));
	}

# CPU allocation
my $cpu;
if ($limits && $limits->{'max_cpu'}) {
	$cpu = $limits->{'max_cpu'} - $limits->{'cpu'};
	$cpu = 100 if ($cpu > 100);
	$cpu = 1 if ($cpu < 1);
	}
$rv .= &ui_table_row($text{'create_xencpu'},
	&ui_opt_textbox("kvm_cpu", $cpu, 4, $text{'domains_unlimited'})."%");

# Virtual CPUs
$rv .= &ui_table_row($text{'create_kvmvcpus'},
	&ui_textbox("kvm_smp", 1, 4)." ".$text{'create_kvmvcores'}." ".
	&ui_textbox("kvm_smp_cores", 1, 4));

# IO class
if (&can_action(undef, "ioclass")) {
	$rv .= &ui_table_row($text{'edit_lioclass'},
		&ui_select("kvm_ioclass", &get_default_ioclass('kvm'),
			[ [ 0, $text{'edit_lioclass0'} ],
			  1 .. 6,
			  [ 7, $text{'edit_lioclass7'} ] ]));
	}

return $rv;
}

# type_kvm_advanced_create_form([empty-mode])
# Returns HTML for KVM-specific inputs
sub type_kvm_advanced_create_form
{
my ($empty) = @_;
my $rv;

# Storage location
my @vhosts = grep { $_->{'kvm_host'} } &list_managed_servers();
my @storages;
my %done;
foreach my $vhost (@vhosts) {
	my $storages = &type_kvm_list_storages($vhost, 1);
	push(@storages, grep { !$done{$_->{'id'}}++ } @$storages);
	}
$rv .= &ui_table_row($text{'xen_onlvm'},
	&ui_select("kvm_storage", "",
		   [ [ "", "&lt;$text{'xen_onlvmdef'}&gt;" ],
		     map { [ $_->{'id'}, $_->{'desc'} ] } @storages ]));

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

# Network interface MAC address
$rv .= &ui_table_row($text{'create_xenmac'},
	&ui_opt_textbox("kvm_mac", undef, 30, $text{'create_xenmacauto'},
			$text{'create_xenmacether'}));

# High-res graphics?
$rv .= &ui_table_row($text{'create_kvmvga'},
	&ui_yesno_radio("kvm_vga", 0));

# Additional command-line args
$rv .= &ui_table_row($text{'edit_kvmargs'},
	&ui_textbox("kvm_args", $server->{'kvm_args'}, 40));

# Firewall spoofed IPs?
$rv .= &ui_table_row($text{'create_kvmfirewall'},
	&ui_yesno_radio("kvm_firewall", $config{'kvm_firewall'}));

# Start after creation?
$rv .= &ui_table_row($text{'create_xenstart'},
	&ui_yesno_radio("kvm_start", 1));

return $rv;
}

# type_kvm_create_parse(&server, &in, [empty-flag], [&limits-from-plan])
# Parse inputs from type_kvm_create_form, and update the server object
sub type_kvm_create_parse
{
my ($server, $in, $empty, $plan) = @_;
my $img = $empty ? undef : &get_server_image($server->{'image'});

# Validate memory parameters
if ($plan && $plan->{'max_ram'}) {
	$server->{'kvm_memory'} = $plan->{'max_ram'} / (1024*1024);
	}
else {
	$in{'kvm_memory'} =~ /^\d+$/ || &error($text{'create_exenmemory'});
	$server->{'kvm_memory'} = ($in{'kvm_memory'}*$in{'kvm_memory_units'}) /
				  (1024*1024);
	}
$server->{'kvm_memory'} >= 32 ||
	&error(&text('create_exenmemory2', '32M'));

# Validate swap file
$server->{'kvm_disktotal'} = 0;
if ($plan && $plan->{'max_disk'}) {
	# If disk limit comes from plan, it all goes towards actual disk
	}
elsif (!$in{'kvm_swap_def'} && !$empty && &can_action(undef, 'swap')) {
	$in{'kvm_swap'} =~ /^\d+$/ || &error($text{'create_exenswapsize'});
	$server->{'kvm_swap'} = ($in{'kvm_swap'} * $in{'kvm_swap_units'}) /
				(1024*1024);
	$server->{'kvm_disktotal'} += $server->{'kvm_swap'}*1024*1024;
	}

# Validate disk size
if ($plan && $plan->{'max_disk'}) {
	$server->{'kvm_disksize'} = $plan->{'max_disk'} / (1024*1024);
	$server->{'kvm_disktotal'} += $server->{'kvm_disksize'}*1024*1024;
	}
elsif (!$in{'kvm_disk_def'} || $empty) {
	$in{'kvm_disk'} =~ /^\d+$/ || &error($text{'create_exendisksize'});
	$server->{'kvm_disksize'} = ($in{'kvm_disk'} * $in{'kvm_disk_units'}) /
				    (1024*1024);
	$server->{'kvm_disktotal'} += $server->{'kvm_disksize'}*1024*1024;
	}
else {
	$server->{'kvm_disktotal'} += $img->{'rawsize'};
	}
if (!$empty &&
    $server->{'kvm_disksize'} &&
    $img->{'rawsize'} &&
    $img->{'rawsize'} > $server->{'kvm_disksize'}*1024*1024) {
	&error(&text('create_exendisksize2',
		     &nice_size($img->{'rawsize'})));
	}

# Validate CPU
if ($plan && $plan->{'max_cpu'}) {
	$server->{'kvm_cpu'} = $plan->{'max_cpu'};
	}
elsif (!$in{'kvm_cpu_def'}) {
	$in{'kvm_cpu'} =~ /^[1-9]\d*$/ || &error($text{'create_exencpu'});
	$server->{'kvm_cpu'} = $in{'kvm_cpu'};
	}

# Validate virtual CPUs
$in{'kvm_smp'} =~ /^[1-9]\d*$/ || &error($text{'create_ekvmvcpus'});
$in{'kvm_smp_cores'} =~ /^[1-9]\d*$/ || &error($text{'create_ekvmcores'});
$in{'kvm_smp_cores'} <= $in{'kvm_smp'} || &error($text{'create_ekvmcores2'});
$in{'kvm_smp'} % $in{'kvm_smp_cores'} == 0 ||
	&error($text{'create_ekvmcores3'});
$server->{'kvm_smp'} = $in{'kvm_smp'};
$server->{'kvm_smp_cores'} = $in{'kvm_smp_cores'};

# Validate IO class
if (&can_action(undef, "ioclass")) {
	$in{'kvm_ioclass'} =~ /^[0-7]$/ ||
		&error($text{'create_ekvmioclass'});
	$in{'kvm_ioclass'} >= $access{'ioclass'} ||
		&error(&text('create_ekvmioclassmax', $access{'ioclass'}));
	$server->{'kvm_ioclass'} = $in{'kvm_ioclass'};
	}
else {
	$server->{'kvm_ioclass'} = &get_default_ioclass('kvm');
	}

# Select host system
my $vhost = &parse_host_server_field($server, 'kvm', 'kvm', $in,
				     $server->{'kvm_memory'}*1024*1024,
				     0,
				     $server->{'kvm_disktotal'});
$server->{'kvm_on'} = $vhost->{'id'};

my $bridges;
if ($in->{'kvm_ip_def'} == 0 && &can_action(undef, "ips")) {
	# Validate IP addresses
	my @allhostifaces = grep { &can_use_bridge($_) }
				 split(/\s+/, $vhost->{'kvm_iface'});
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
	if ($in{'kvm_ip_def'} == 2) {
		$bridges = [ grep { &can_use_bridge($_) }
				  split(/\0/, $in->{'kvm_bridge'}) ];
		}
	my $err = &allocate_kvm_ip_addresses($server, $vhost, $bridges);
	&error($err) if ($err);
	}
$server->{'ip_addresses'} = $server->{'kvm_ip'};

if (!$empty) {
	if ($in->{'kvm_ip6_mode'} == 2 && &can_action(undef, "ips")) {
		# Validate manually entered IPv6 address
		&check_ip6address($in{'kvm_ip6'}) ||
			&error($text{'create_ekvmip6'});
		$in{'kvm_netmask6'} =~ /^\d+$/ && $in{'kvm_netmask6'} > 0 ||
			&error($text{'create_ekvmnetmask6'});
		$server->{'kvm_ip6'} = $in{'kvm_ip6'};
		$server->{'kvm_netmask6'} = $in{'kvm_netmask6'};

		# Validate gateway
		if ($in{'kvm_gw6_def'}) {
			$server->{'kvm_gw6'} = '*';
			}
		else {
			&check_ip6address($in{'kvm_gw6'}) ||
				&error($text{'create_exengw6'});
			$server->{'kvm_gw6'} = $in{'kvm_gw6'};
			}
		}
	elsif ($in->{'kvm_ip6_mode'} == 1 && &can_action(undef, "ips") ||
	       $config{'alloc_ipv6'}) {
		# Allocate automatically
		my $err = &allocate_kvm_ip6_addresses($server, $vhost,$bridges);
		&error($err) if ($err);
		}
	else {
		# IPv6 not in use .. clear
		$server->{'kvm_ip6'} = undef;
		$server->{'kvm_netmask6'} = undef;
		$server->{'kvm_gw6'} = undef;
		}
	$server->{'ip6_addresses'} = $server->{'kvm_ip6'};
	}

# Storage location setting
my $storages = &type_kvm_list_storages($vhost);
my $storage;
if ($in{'kvm_storage'}) {
	ref($storages) || &error(&text('create_exenstorages', $storages));
	($storage) = grep { $_->{'id'} eq $in{'kvm_storage'} } @$storages;
	}
else {
	($storage) = grep { $_->{'default'} } @$storages;
	}
$storage || &error(&text('create_exenstorage',
			 $in{'kvm_storage'}, $vhost->{'host'}));
if ($storage->{'type'} eq 'files') {
	$server->{'kvm_nolvm'} = 1;
	}
elsif ($storage->{'type'} eq 'lvm') {
	$server->{'kvm_force_vg'} = $storage->{'vg'};
	}
elsif ($storage->{'type'} eq 'thin') {
	$server->{'kvm_force_vg'} = $storage->{'vg'};
	$server->{'kvm_force_thin'} = $storage->{'lv'};
	}
elsif ($storage->{'type'} eq 'iscsi') {
	$server->{'kvm_force_iscsi'} = $storage->{'iscsi'};
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
if (!$in{'kvm_model'}) {
	# Use image or global default
	$server->{'kvm_model'} = $empty ? $config{'kvm_model'} :
				  $img->{'kvm_virtio'} ? 'virtio' : undef;
	}
elsif ($in{'kvm_model'}) {
	# User selection
	my $models = &type_kvm_list_models();
	my ($m) = grep { $_->[0] eq $in{'kvm_model'} } @$models;
	$m || &error($text{'create_ekvmmodel'});
	$server->{'kvm_model'} = $in{'kvm_model'};
	}

# MAC address
if (!$in{'kvm_mac_def'} && &can_action(undef, "advanced")) {
	$in{'kvm_mac'} =~ /^([0-9a-f]{1,2}:)*[0-9a-f]{1,2}$/i ||
		&error($text{'create_exenmac'});
	$server->{'kvm_mac'} = $in{'kvm_mac'};
	}

# Start at creation
$server->{'kvm_start'} = defined($in{'kvm_start'}) ? $in{'kvm_start'} : 1;

# High-res graphics
$server->{'kvm_vga'} = defined($in{'kvm_vga'}) ? $in{'kvm_vga'} : 0;

# KVM keymap
$server->{'kvm_keymap'} = $config{'kvm_keymap'};

# Additional KVM args
$in{'kvm_args'} =~ /;|\&|\||<|>|\0|\!/ && &error($text{'create_ekvmargs'});
$server->{'kvm_args'} = $in{'kvm_args'};

# Firewall spoofed IPs
$server->{'kvm_firewall'} = (defined($in{'kvm_firewall'}) ?
				$in{'kvm_firewall'} : $config{'kvm_firewall'}) ?
			    '*' : '';

# Append zone name
my @zones = &list_bind_zones();
my $zone;
if ($vhost->{'kvm_zone'}) {
	($zone) = grep { $_->{'name'} eq $vhost->{'kvm_zone'} } @zones;
	}
if ($zone) {
	# Append zone name, but disallow dots in entered name
	$in->{'host'} =~ /\./ && &error($text{'create_ekvmhost'});
	$server->{'host'} .= ".".$vhost->{'kvm_zone'};
	}
}

# type_kvm_create_args([empty])
# Returns an array of parameters to type_kvm_create_args_parse
sub type_kvm_create_args
{
my ($empty) = @_;
my @rv = ( $module_info{'onehost'} eq 'kvm' ? ( ) :
	   	( { 'name' => 'host', 'value' => 'host-system' },
	   	  { 'name' => 'location', 'value' => 'name' } ),
	   { 'name' => 'ip', 'value' => 'address[,address]', 'opt' => 1 },
	   { 'name' => 'cidr', 'value' => 'number[,number]', 'opt' => 1 },
	   { 'name' => 'netmask', 'value' => 'mask,[mask]', 'opt' => 1 },
	   { 'name' => 'gw', 'value' => 'address[,address|*]', 'opt' => 1 },
	   { 'name' => 'bridge', 'value' => 'name[,name]', 'opt' => 1 },
	   { 'name' => 'disksize', 'value' => 'megabytes', 'opt' => !$empty },
	   $empty ? ( ) : ( { 'name' => 'swap',
                              'value' => 'megabytes',
                              'opt' => 1 } ),
	   { 'name' => 'memory', 'value' => 'megabytes', 'opt' => 1 },
	   { 'name' => 'cpu', 'value' => 'percent', 'opt' => 1 },
	   { 'name' => 'vcpus', 'value' => 'number', 'opt' => 1 },
	   { 'name' => 'cores', 'value' => 'number', 'opt' => 1 },
	   { 'name' => 'ioclass', 'value' => 'priority', 'opt' => 1 },
	   { 'name' => 'ip6', 'value' => 'ipv6-address,[ipv6-address]', 'opt' => 1 },
	   { 'name' => 'netmask6', 'value' => 'mask,[mask]', 'opt' => 1 },
	   { 'name' => 'gw6', 'value' => 'ipv6-address,[ipv6-address]', 'opt' => 1 },
	   { 'name' => 'allocate-ip6', 'value' => 'true|false', 'opt' => 1 },
	 );
if (&can_action(undef, "advanced")) {
	my $models = join('|', map { $_->[0] } @{&type_kvm_list_models()});
	push(@rv, { 'name' => 'lvm', 'value' => 'true|false', 'opt' => 1,
		    'deprecated' => 1 },
		  { 'name' => 'storage', 'value' => 'storage-id', 'opt' => 1 },
	 	  { 'name' => 'mac', 'value' => 'ethernet-address', 'opt' => 1 },
		  { 'name' => 'virtio', 'value' => 'true|false', 'opt' => 1 },
		  { 'name' => 'model', 'value' => $models, 'opt' => 1 },
		  { 'name' => 'start', 'value' => 'true|false', 'opt' => 1 },
		  { 'name' => 'vga', 'value' => 'true|false', 'opt' => 1 },
		  { 'name' => 'firewall', 'value' => 'true|false', 'opt' => 1 },
		  { 'name' => 'iscsi', 'value' => 'hostname', 'opt' => 1,
		    'deprecated' => 1 },
		  { 'name' => 'args', 'value' => 'parameters', 'opt' => 1 },
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

# Validate swap flag
$server->{'kvm_disktotal'} = 0;
if (!$empty && &can_action(undef, 'swap')) {
        if ($args->{'swap'} ne '') {
                $args->{'swap'} =~ /^\d+$/ ||
                        return "Non-numeric swap allocation";
                $server->{'kvm_swap'} = $args->{'swap'};
                }
        else {
                $server->{'kvm_swap'} = $config{'kvm_swap'};
                }
        $server->{'kvm_disktotal'} += $args->{'swap'}*1024*1024;
        }

# Validate filesystem size flag
if ($args->{'disksize'} || $empty) {
	$args->{'disksize'} || return "Missing disk size parameter";
	$args->{'disksize'} =~ /^\d+$/ ||
		return "Non-numeric disk size";
	$server->{'kvm_disksize'} += $args->{'disksize'};
	if (!$empty &&
            $img->{'rawsize'} &&
	    $img->{'rawsize'} > $args->{'disksize'}*1024*1024) {
		return "--kvm-disksize must be at least $img->{'rawsize'} ".
		       "bytes, as that is the size of the selected image";
		}
	$server->{'kvm_disktotal'} += $args->{'disksize'}*1024*1024;
	}
else {
	$server->{'kvm_disktotal'} += $img->{'rawsize'};
	}

# Validate CPU flag
if ($args->{'cpu'}) {
	$args->{'cpu'} =~ /^[1-9]\d*$/ || return "Non-numeric CPU percentage";
	$server->{'kvm_cpu'} = $args->{'cpu'};
	}

# Validate CPUs and cores flags
my $smp = $args->{'vcpus'} || 1;
my $cores = $args->{'cores'} || 1;
my $err = &type_kvm_save_smp($server, $smp, $cores);
return $err if ($err);

# Validate IO class flag
if ($args->{'ioclass'} ne '') {
	&can_action(undef, "ioclass") ||
	    return "You are not allowed to set the IO class for new systems";
	$args->{'ioclass'} =~ /^[0-7]$/ ||
	    return "IO class must be a number from 0 to 7";
	$args->{'ioclass'} >= $access{'ioclass'} ||
	    return "IO class cannot be better than your plan ".
		   "limit of $access{'ioclass'}";
	$server->{'kvm_ioclass'} = $args->{'ioclass'};
	}
else {
	$server->{'kvm_ioclass'} = &get_default_ioclass('kvm');
	}

# Hosting server
my $vhost;
if ($module_info{'onehost'} eq 'kvm') {
	# KVM host is always this box
	($vhost) = grep { $_->{'manager'} eq 'this' } &list_managed_servers();
	}
elsif ($args->{'host'}) {
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
					  0,
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
				     0,
                                     $server->{'kvm_disktotal'},
				     $server,
				     1);
$ok || return "Host system $vhost->{'host'} cannot be used : $err";
$server->{'kvm_on'} = $vhost->{'id'};

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
		my @hostifaces = grep { &can_use_bridge($_) }
				      split(/[, ]+/, $args->{'bridge'});
		scalar(@ips) == scalar(@hostifaces) ||
		    return "The number of IPs must match the number of bridges";
		$server->{'kvm_hostifaces'} = join(' ', @hostifaces);
		}
	else {
		# Automatically determine from host system
		my @hostifaces = grep { &can_use_bridge($_) }
				      split(/\s+/, $vhost->{'kvm_iface'});
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
	my $err = &allocate_kvm_ip_addresses($server, $vhost,
			$args->{'bridge'} ? [ split(/,/, $args->{'bridge'}) ]
					  : undef);
	return $err if ($err);
	}
$server->{'ip_addresses'} = $server->{'kvm_ip'};

# Validate IPv6 flags
if ($args->{'ip6'}) {
	# Use specified addresses
	&can_action(undef, "ips") ||
		return "You are not allowed to specify IPv6 addresses";
	my @ips = split(/[, ]+/, $args->{'ip6'});
	foreach my $ip (@ips) {
		&check_ip6address($ip) || return "Invalid KVM IPv6 address $ip";
		}
	my @netmasks;
	if ($args->{'netmask6'}) {
		@netmasks = split(/[, ]+/, $args->{'netmask6'});
		foreach my $n (@netmasks) {
			$n =~ /^\d+$/ && $n > 0 ||
				return "Invalid KVM IPv6 netmask $n";
			}
		}
	else {
		@netmasks = map { 64 } @ips;
		}
	scalar(@ips) == scalar(@netmasks) ||
		return "The number of IPv6 addresses must match the number ".
		       "of netmasks";
	$server->{'kvm_ip6'} = join(' ', @ips);
	$server->{'kvm_netmask6'} = join(' ', @netmasks);

	# Gateway IPs
	if ($args->{'gw6'}) {
		# Set on command line
		my @gws6 = split(/[, ]+/, $args->{'gw6'});
		foreach my $gw6 (@gws6) {
			$gw6 eq '*' || &check_ip6address($gw6) ||
				return "Invalid gateway IPv6 address $gw6";
			}
		scalar(@ips) == scalar(@gws6) ||
			return "The number of IPv6 addresses must match the ".
			       "number of gateways";
		$server->{'kvm_gw6'} = join(' ', @gws6);
		}
	else {
		# Assume all are using default
		$server->{'kvm_gw6'} = join(' ', map { "*" } @ips6);
		}
	}
elsif ($args->{'allocate-ip6'} =~ /true|yes/ ||
       !$args->{'allocate-ip6'} && $config{'alloc_ipv6'}) {
	# Allocate addresses
	my $err = &allocate_kvm_ip6_addresses($server, $vhost,
			$args->{'bridge'} ? [ split(/,/, $args->{'bridge'}) ]
					  : undef);
	return $err if ($err);
	}
else {
	# IPv6 not in use .. clear
	$server->{'kvm_ip6'} = undef;
	$server->{'kvm_netmask6'} = undef;
	$server->{'kvm_gw6'} = undef;
	}
$server->{'ip6_addresses'} = $server->{'kvm_ip6'};

# Adjust hostname for DNS
my @zones = &list_bind_zones();
my $zone;
if ($vhost->{'kvm_zone'}) {
	($zone) = grep { $_->{'name'} eq $vhost->{'kvm_zone'} } @zones;
	}
if ($zone) {
	$server->{'host'} =~ /\./ && return "KVM hostnames cannot contain .";
	$server->{'host'} .= ".".$vhost->{'kvm_zone'};
	}

my $storages = &type_kvm_list_storages($vhost);
ref($storages) || return "Failed to list storages : $storages";
my $storage;

if (&can_action(undef, "advanced")) {
	# Validate storage location flag
	my ($fstorage) = grep { $_->{'id'} eq 'files' } @$storages;
	if ($args->{'storage'}) {
		# Find requested storage
		($storage) = grep { $_->{'id'} eq $args->{'storage'} } 
				  @$storages;
		$storage ||return "No storage with ID $args->{'storage'} found";
		}
	elsif ($args->{'iscsi'}) {
		# Validate forced iSCSI server flag (deprecated)
		my $iscsiserver = &get_managed_server_by(
					"host", $args->{'iscsi'});
		$iscsiserver ||
			return "iSCSI server $args->{'iscsi'} does not exist";
		$iscsiserver->{'iscsi_module'} ||
			return "System $args->{'iscsi'} is not an iSCSI server";
		($storage) = grep { $_->{'iscsi'} eq $iscsiserver->{'id'} }
				  @$storages;
		}
	elsif ($args->{'lvm'}) {
		# Validate LVM flag (deprecated)
		if ($args->{'lvm'} =~ /true|yes/i) {
			($storage) = grep { $_->{'id'} =~ /^lvm_/ } @$storages;
			$storage || return "Host system $vhost->{'host'} ".
					   "does not use LVM";
			$server->{'directory'} &&
				return "LVM cannot be enabled when a disk ".
				       "directory is specified";
			}
		elsif ($args->{'lvm'} =~ /false|no/i) {
			$storage = $fstorage;
			}
		}
	else {
		# Default storage
		if ($server->{'directory'}) {
			$storage = $fstorage;
			}
		else {
			($storage) = grep { $_->{'default'} } @$storages;
			}
		}

	# Validate virtio flag, or use image or configured default
	if ($args->{'virtio'} =~ /true|yes/i) {
		$server->{'kvm_virtio'} = 1;
		}
	elsif ($args->{'virtio'} =~ /no|false/i) {
		$server->{'kvm_virtio'} = 0;
		}
	else {
		$server->{'kvm_virtio'} = $empty ? $config{'kvm_virtio'}
						 : $img->{'kvm_virtio'};
		}

	# MAC address flag
	if ($args->{'mac'}) {
		$args->{'mac'} =~ /^([0-9a-f]{1,2}:)*[0-9a-f]{1,2}$/i ||
			return "Invalid MAC address";
		$server->{'kvm_mac'} = $args->{'mac'};
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
		$server->{'kvm_model'} = $empty ? $config{'kvm_model'} :
				  $img->{'kvm_virtio'} ? 'virtio' : undef;
		}

	# Validate start at creation flag
	if ($args->{'start'} =~ /false|no/i) {
		$server->{'kvm_start'} = 0;
		}
	else {
		$server->{'kvm_start'} = 1;
		}

	# Validate VGA
	if ($args->{'vga'} =~ /true|yes/i) {
		$server->{'kvm_vga'} = 1;
		}
	else {
		$server->{'kvm_vga'} = 0;
		}

	# Validate extra command-line args
	$args->{'args'} =~ /;|\&|\||<|>|\0|\!/ &&
		return "Invalid characters in additional args";
	$server->{'kvm_args'} = $args->{'args'};

	# Save spoofing firewall
	if ($args->{'firewall'} =~ /true|yes/i) {
		$server->{'kvm_firewall'} = '*';
		}
	else {
		$server->{'kvm_firewall'} = '';
		}
	}
else {
	# Use defaults
	$server->{'kvm_virtio'} = $empty ? $config{'kvm_virtio'}
					 : $img->{'kvm_virtio'};
	$server->{'kvm_model'} = $config{'kvm_model'};
	$server->{'kvm_start'} = 1;
	$server->{'kvm_vga'} = 0;
	$server->{'kvm_firewall'} = $config{'kvm_firewall'} ? '*' : '';
	($storage) = grep { $_->{'default'} } @$storages;
	}
$server->{'kvm_keymap'} = $config{'kvm_keymap'};

# Use the storage chosen
$storage || return "No storage location found!";
if ($storage->{'type'} eq 'files') {
	$server->{'kvm_nolvm'} = 1;
	}
elsif ($storage->{'type'} eq 'lvm') {
	$server->{'kvm_force_vg'} = $storage->{'vg'};
	}
elsif ($storage->{'type'} eq 'thin') {
	$server->{'kvm_force_vg'} = $storage->{'vg'};
	$server->{'kvm_force_thin'} = $storage->{'lv'};
	}
elsif ($storage->{'type'} eq 'iscsi') {
	$server->{'kvm_force_iscsi'} = $storage->{'iscsi'};
	}

return undef;
}

# type_kvm_create(&server, [serial, key], [reset], [empty], [no-start])
# Create a new KVM instance, by unzipping the filesystem image in the background
sub type_kvm_create
{
my ($server, $serial, $key, $reset, $empty, $nostart) = @_;
my $vhost = &type_kvm_parent($server);
$vhost && $vhost->{'kvm_host'} || return "Host system does not exist or is ".
					 "not a KVM host";
my $img = $server->{'image'} ? &get_server_image($server->{'image'}) : undef;
delete($server->{'kvm_filesystem_offset'});
$server->{'kvm_args'} = $config{'kvm_manual'} if (!$reset);
my $kvm_dir = $server->{'directory'} || $vhost->{'kvm_dir'};

# If re-creating a system, the monitor port can be re-generated
if (!$reset) {
	delete($server->{'kvm_monitor_port'});
	}

# Create base dir if needed
my @st = &stat_file_on_server($vhost, $kvm_dir);
if (!@st) {
	&make_dir_on_server($vhost, $kvm_dir, 0755, 1);
	}

# Validate CD image on host
if ($empty && !$server->{'image'} && $server->{'imagefile'}) {
	&stat_file_on_server($vhost, $server->{'imagefile'}) ||
		return "CD image $server->{'imagefile'} on host system ".
		       "$vhost->{'host'} does not exist";
	}

# Work out the config and image file locations
my ($fsfile, $swfile, $lvmsuffix);
if ($reset) {
	# Filesystem remains the same
	$fsfile = $server->{'kvm_filesystem'};
	$swfile = $server->{'kvm_swapfile'};
	if (!$fsfile) {
		return "A system with no primary disk cannot be reset";
		}
	}
elsif ($server->{'kvm_force_iscsi'} ne '' ||
       $vhost->{'kvm_iscsi'} ne '' && !$server->{'kvm_nolvm'}) {
	# On iSCSI server
	$server->{'kvm_filesystem_iscsi'} = $server->{'kvm_force_iscsi'} ne '' ?
		$server->{'kvm_force_iscsi'} : $vhost->{'kvm_iscsi'};
	delete($server->{'kvm_filesystem_vg'});
	delete($server->{'kvm_filesystem_lv'});
	delete($server->{'kvm_swapfile_vg'});
	delete($server->{'kvm_swapfile_lv'});
        if ($server->{'kvm_swap'}) {
		$server->{'kvm_swapfile_iscsi'} =
			$server->{'kvm_filesystem_iscsi'};
		}
	else {
		delete($server->{'kvm_swapfile_iscsi'});
		}
	}
elsif ($server->{'kvm_force_vg'} ||
       $vhost->{'kvm_vg'} && !$server->{'kvm_nolvm'}) {
	# On LVM logical volumes
	$server->{'kvm_filesystem_vg'} = $server->{'kvm_force_vg'} ||
					 $vhost->{'kvm_vg'};
	$server->{'kvm_filesystem_lv'} = $server->{'host'}.'_img';
	$server->{'kvm_filesystem_lv'} =~ s/\./_/g;
	$server->{'kvm_filesystem_thin'} = $server->{'kvm_force_thin'};
	$fsfile = "/dev/".$server->{'kvm_filesystem_vg'}."/".
		  $server->{'kvm_filesystem_lv'};
	delete($server->{'kvm_filesystem_iscsi'});
	delete($server->{'kvm_swapfile_iscsi'});
        if ($server->{'kvm_swap'}) {
                $server->{'kvm_swapfile_vg'} = $server->{'kvm_filesystem_vg'};
                $server->{'kvm_swapfile_lv'} = $server->{'host'}.'_swap';
		$server->{'kvm_swapfile_lv'} =~ s/\./_/g;
		$server->{'kvm_swapfile_thin'} = $server->{'kvm_force_thin'};
                $swfile = "/dev/".$server->{'kvm_swapfile_vg'}."/".
                          $server->{'kvm_swapfile_lv'};
                }
	else {
		delete($server->{'kvm_swapfile_vg'});
		delete($server->{'kvm_swapfile_lv'});
		}
	}
else {
	# On regular files
	$fsfile = "$kvm_dir/$server->{'host'}.img";
	my @st = &stat_file_on_server($vhost, $fsfile);
	return "Disk image file $fsfile already exists" if (@st);
	delete($server->{'kvm_filesystem_vg'});
	delete($server->{'kvm_filesystem_lv'});
	delete($server->{'kvm_filesystem_thin'});
	delete($server->{'kvm_filesystem_iscsi'});
	delete($server->{'kvm_swapfile_vg'});
	delete($server->{'kvm_swapfile_lv'});
	delete($server->{'kvm_swapfile_thin'});
	delete($server->{'kvm_swapfile_iscsi'});
        if ($server->{'kvm_swap'}) {
                $swfile = "$kvm_dir/$server->{'host'}.swap";
		my @st = &stat_file_on_server($vhost, $swfile);
		return "Swap image file $fsfile already exists" if (@st);
                }
	}

# Check again if host supports iSCSI
if ($server->{'kvm_filesystem_iscsi'} ne '') {
	my $err = &check_iscsi_client($vhost);
	$err && return "Host system $vhost->{'host'} does not support iSCSI : $err";
	}

# Generate MAC addresses
my @ips = split(/\s+/, $server->{'kvm_ip'});
my @ips6 = split(/\s+/, $server->{'kvm_ip6'});
my @macs;
for(my $i=0; $i<@ips; $i++) {
	if ($i == 0 && $server->{'kvm_mac'}) {
		my $macclash = &get_managed_server_by(
			"kvm_mac", $server->{'kvm_mac'});
		if (!$macclash || $macclash->{'id'} eq $server->{'id'}) {
			push(@macs, $server->{'kvm_mac'});
			next;
			}
		}
	push(@macs, &generate_mac_address($server, $i));
	}
$server->{'mac'} = join(" ", @macs);
$server->{'mac_addresses'} = join(" ", @macs);

# If not resetting and firewall is set to all IPs, change it to the actual list
# of assigned IPs now
if (!$reset && $server->{'kvm_firewall'} eq '*') {
	$server->{'kvm_firewall'} = join(" ", @ips, @ips6);
	}

# Work out interface parameters, create networking config
my @ifaces = split(/\s+/, $server->{'kvm_hostifaces'});
my @gws = split(/\s+/, $server->{'kvm_gw'});
my @nets;
for(my $i=0; $i<@ips; $i++) {
	# Create bridge script
	my $net = "tap";
	$net .= ",vlan=$i" if (&kvm_host_supports_vlan($vhost));
	my ($data, $script) = &generate_kvm_bridge_script(
			$server, { 'name' => 'eth'.$i }, $ifaces[$i]);
	my $err = &put_file_data_to_server($vhost, $data, $script);
	return "Failed to create script $script : $err" if ($err);
	&execute_command_on_server($vhost, "chmod +x $script");
	$net .= ",script=$script";
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

# Find existing LV if resetting
my (@lvs, $fslv);
&remote_finished();
if ($reset && $server->{'kvm_filesystem_vg'}) {
	&remote_foreign_require($vhost, "lvm", "lvm-lib.pl");
	@lvs = &remote_foreign_call($vhost, "lvm",
		"list_logical_volumes", $server->{'kvm_filesystem_vg'});
	($fslv) = grep { $_->{'vg'} eq $server->{'kvm_filesystem_vg'} &&
			 $_->{'name'} eq $server->{'kvm_filesystem_lv'} } @lvs;
	($swlv) = grep { $_->{'vg'} eq $server->{'kvm_swapfile_vg'} &&
			 $_->{'name'} eq $server->{'kvm_swapfile_lv'} } @lvs;
	}

# Create swap LV or iSCSI target
$last_remote_error = undef;
if ($server->{'kvm_swapfile_vg'}) {
	# Create swap LV
	&remote_foreign_require($vhost, "lvm", "lvm-lib.pl");
        my $lv = { 'name' => $server->{'kvm_swapfile_lv'},
                   'size' => int($server->{'kvm_swap'}*1024),
                   'perm' => 'rw',
                   'alloc' => 'n',
                   'vg' => $server->{'kvm_swapfile_vg'},
	           'thin_in' => $server->{'kvm_swapfile_thin'}, };
	if (!$swaplv || !&size_close_enough($swaplv->{'size'}, $lv->{'size'})) {
                # Only delete and re-create if an old LV with close enough to
                # the same size doesn't exist
                if ($reset && $swlv) {
                        # Delete the old LV
                        &delete_all_disk_image_partitions($vhost, $swfile);
			&delete_mapper_entries(
				$vhost, $lv->{'vg'}, $lv->{'name'});
                        my $err = &remote_foreign_call($vhost, "lvm",
                                             "delete_logical_volume",
                                             { 'device' => $swfile });
                        $err ||= $last_remote_error;
                        return "LVM logical volume deletion failed : $err"
                                if ($err);
                        }
                my $err = &remote_foreign_call($vhost, "lvm",
                                                "create_logical_volume", $lv);
                $err ||= $last_remote_error;
                return "LVM logical volume creation for swap failed : $err"
                        if ($err);
                }
        }
elsif ($server->{'kvm_swapfile_iscsi'} ne '') {
	# Create iSCSI disk for swap
	my $disk = { 'size' => $server->{'kvm_swap'}*1024*1024,
		     'iscsi_server' => $server->{'kvm_swapfile_iscsi'},
		   };
	my $keep_disk = 0;
	if ($reset) {
		# If resettting, disk already exists .. fill in object
		# with info from VM
		$disk->{'iscsi_name'} = $server->{'kvm_swapfile_iscsi_name'};
		$disk->{'iscsi_target'} = $server->{'kvm_swapfile_iscsi_target'};
		$disk->{'iscsi_ip'} = $server->{'kvm_swapfile_iscsi_ip'};
		$disk->{'iscsi_port'} = $server->{'kvm_swapfile_iscsi_port'};
		$disk->{'iscsi_connect'} = -1;	# May or may not be connected

		# Get info on existing disk on iSCSI server
		my $iscsiserver = &get_managed_server(
					$server->{'kvm_swapfile_iscsi'});
		my $idisk = &get_iscsi_disk_info($iscsiserver, $disk);
		if (ref($idisk) &&
		    &size_close_enough($idisk->{'size'}, $disk->{'size'})) {
			$keep_disk = 1;
			}
		}
	if (!$keep_disk) {
		# Disk needs to be deleted (if re-setting) and then created
		# on iSCSI server
		if ($reset) {
			my $err = &delete_iscsi_disk($server, $disk);
			}
		my $err = &create_iscsi_disk($server, $disk);
		$err && return "iSCSI swap disk creation failed : $err";
		$swfile = $disk->{'real'};
		$server->{'kvm_swapfile_iscsi_name'} = $disk->{'iscsi_name'};
		$server->{'kvm_swapfile_iscsi_target'} = $disk->{'iscsi_target'};
		$server->{'kvm_swapfile_iscsi_ip'} = $disk->{'iscsi_ip'};
		$server->{'kvm_swapfile_iscsi_port'} = $disk->{'iscsi_port'};
		$server->{'kvm_swapfile_iscsi_real'} = $disk->{'iscsi_real'};
		}
	}

# Create filesystem LV or iSCSI target
$last_remote_error = undef;
if ($server->{'kvm_filesystem_vg'}) {
	# If on LVM, create an LV first
	&remote_foreign_require($vhost, "lvm", "lvm-lib.pl");
	my $lv = { 'name' => $server->{'kvm_filesystem_lv'},
		   'size' =>
			($img && !$empty ? int($img->{'rawsize'}/1024) : 0) ||
			int($server->{'kvm_disksize'}*1024) ||
			1024*1024,
		   'perm' => 'rw',
		   'alloc' => 'n',
		   'vg' => $server->{'kvm_filesystem_vg'},
	           'thin_in' => $server->{'kvm_filesystem_thin'}, };
	if (!$fslv ||
	    !&size_close_enough($fslv->{'size'}*1024, $lv->{'size'}*1024)) {
		# Only delete and re-create if an old LV with close enough to
		# the same size doesn't exist
		if ($reset && $fslv) {
			# Delete the old LV
			&delete_all_disk_image_partitions($vhost, $fsfile);
			&delete_mapper_entries(
				$vhost, $lv->{'vg'}, $lv->{'name'});
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
elsif ($server->{'kvm_filesystem_iscsi'} ne '') {
	# On iSCSI, so create iSCSI disk and attach to host
	my $disk = { 'size' => ($img && !$empty ? $img->{'rawsize'} : 0) ||
			       $server->{'kvm_disksize'}*1024*1024 ||
			       1024*1024,
		     'iscsi_server' => $server->{'kvm_filesystem_iscsi'},
		   };
	my $keep_disk = 0;
	if ($reset) {
		# If resettting, disk already exists .. fill in object
		# with info from VM
		$disk->{'iscsi_name'} = $server->{'kvm_filesystem_iscsi_name'};
		$disk->{'iscsi_target'} = $server->{'kvm_filesystem_iscsi_target'};
		$disk->{'iscsi_ip'} = $server->{'kvm_filesystem_iscsi_ip'};
		$disk->{'iscsi_port'} = $server->{'kvm_filesystem_iscsi_port'};
		$disk->{'iscsi_connect'} = -1;	# May or may not be connected

		# Get info on existing disk on iSCSI server
		my $iscsiserver = &get_managed_server(
					$server->{'kvm_filesystem_iscsi'});
		my $idisk = &get_iscsi_disk_info($iscsiserver, $disk);
		if (ref($idisk) &&
		    &size_close_enough($idisk->{'size'}, $disk->{'size'})) {
			$keep_disk = 1;
			}
		}
	if (!$keep_disk) {
		# Disk needs to be deleted (if re-setting) and then created
		# on iSCSI server
		if ($reset) {
			my $err = &delete_iscsi_disk($server, $disk);
			}
		my $err = &create_iscsi_disk($server, $disk);
		$err && return "iSCSI disk creation failed : $err";
		$fsfile = $disk->{'real'};
		$server->{'kvm_filesystem_iscsi_name'} = $disk->{'iscsi_name'};
		$server->{'kvm_filesystem_iscsi_target'} = $disk->{'iscsi_target'};
		$server->{'kvm_filesystem_iscsi_ip'} = $disk->{'iscsi_ip'};
		$server->{'kvm_filesystem_iscsi_port'} = $disk->{'iscsi_port'};
		$server->{'kvm_filesystem_iscsi_real'} = $disk->{'iscsi_real'};
		}
	}

# Work out default cache type
my $cacheflag;
if ($config{'kvm_cache'}) {
	my $caches = &type_kvm_list_disk_caches($server);
	my ($obj) = grep { $_->{'id'} eq $config{'kvm_cache'} ||
			   $_->{'alt'} eq $config{'kvm_cache'} } @$caches;
	if ($obj) {
		$cacheflag = ",cache=$obj->{'id'}";
		}
	}

# Set drive in config, unless resetting in which case they stay the same
$server->{'kvm_filesystem'} = $fsfile;
$server->{'kvm_swapfile'} = $swfile;
if (!$reset) {
	my $ver = &kvm_host_version($vhost);
	my $boot = $ver && &compare_versions($ver, "1.1") >= 0 ? ""
							       : ",boot=on";
	my $formatflag = $ver && &compare_versions($ver, "1.1") >= 0 ?
				",format=raw" : "";
	$server->{'kvm_drives'} = "file=$fsfile,media=disk,index=0".
		  ($server->{'kvm_virtio'} ? ",if=virtio".$boot : ",if=ide").
		  $cacheflag.$formatflag;
	if ($swfile) {
		$server->{'kvm_drives'} .=
			" file=$swfile,media=disk,index=1,cache=off,".
			($server->{'kvm_virtio'} ? "if=virtio" : "if=ide").
			$formatflag;
		}
	}

# Create empty disk file, with no partitions
if ($empty) {
	my $dksize = $server->{'kvm_disksize'}*1024*1024;
	$dksize ||= $server->{'kvm_disktotal'};
	if (!$server->{'kvm_filesystem_vg'} &&
	    $server->{'kvm_filesystem_iscsi'} eq '') {
		# Create whole disk file with dd
		my $cmd = &dd_command("/dev/zero", $fsfile, $dksize);
		my ($out, $ex, $err) = &execute_command_on_server(
						$vhost, $cmd);
		$err = $out if ($ex);
		$err && return "Failed to create file $disk->{'real'} : $err";
		}
	else {
		# Just empty first 32k
		my $cmd = &dd_command("/dev/zero", $fsfile, 32768);
		my ($out, $ex, $err) = &execute_command_on_server(
						$vhost, $cmd);
		$err = $out if ($ex);
		$err && return "Failed to zero out $disk->{'real'} : $err";
		}
	my $err = &create_disk_image_partition($vhost, $fsfile,
					       undef, $dksize, 1);
	return $err if ($err);
	}

# Add CD to list of disks
my $imgdestfile;
my $copyserver = $vhost;	# Where the image is at
if ($empty && $server->{'image'}) {
	# CD will be copied to a new file
	$imgdestfile = "$kvm_dir/$server->{'host'}.cd";
	$server->{'kvm_drives'} .=
		" file=$imgdestfile,media=cdrom,index=2";
	$server->{'kvm_bootdevice'} = 'd';
	$server->{'kvm_cdimage'} = $imgdestfile;
	}
elsif ($empty && !$server->{'image'}) {
	# CD is in an existing file, or no image is needed
	if ($server->{'imagefile'}) {
		$server->{'kvm_drives'} .=
		    " file=$server->{'imagefile'},media=cdrom,index=1,if=ide";
		$server->{'kvm_bootdevice'} = 'd';
		}
	}
else {
	# Copying image to first drive on the system
	$copyserver = &get_transfer_image_dest($server);
	if ($copyserver->{'id'} eq $vhost->{'id'}) {
		# Copy to disk image file on the host
		$imgdestfile = $fsfile;
		}
	else {
		# Copy to the underlying iSCSI disk file
		$imgdestfile = $server->{'kvm_filesystem_iscsi_real'};
		}
	$server->{'kvm_bootdevice'} = 'c';
	}

# Put the image into place, in the background
if ($imgdestfile) {
	my $err = &deploy_disk_image($server, $img, $imgdestfile, $copyserver);
	return $err if ($err);
	}

return undef;
}

# type_kvm_create_done(&server, [empty])
# Checks if the filesystem gunzip is complete, and returns OK if so.
# Returns undef if still running, or an error message on failure.
sub type_kvm_create_done
{
my ($server, $empty) = @_;
my $vhost = &type_kvm_parent($server);
my $copyserver = $empty ? $vhost : &get_transfer_image_dest($server);
return &done_deploy_disk_image($server, $copyserver);
}

# type_kvm_create_post(&server, [serial, key], [reset], [empty], [no-start])
# Called after creation is complete. Here we can mount and fix up config
# files in the filesytem, then start the instance.
sub type_kvm_create_post
{
my ($server, $serial, $key, $reset, $empty, $nostart) = @_;
my $vhost = &type_kvm_parent($server);
my $img = $server->{'image'} ? &get_server_image($server->{'image'}) : undef;
my @ips = split(/\s+/, $server->{'kvm_ip'});
my @cidrs = split(/\s+/, $server->{'kvm_cidr'});
my @netmasks = map { &net::prefix_to_mask($_) } @cidrs;
my @ips6 = split(/\s+/, $server->{'kvm_ip6'});
my @netmasks6 = split(/\s+/, $server->{'kvm_netmask6'});
my @macs = split(/\s+/, $server->{'mac'});
$server->{'status'} = 'down';
$nostart = 1 if (!$server->{'kvm_start'});
$nostart = 0 if ($reset);

# Gateways can either be set per IP address, or copy from host system.
# If none are set, assume the first IP uses the host system gateway.
my $defgw = &get_server_default_gateway($vhost);
my @gws = split(/\s+/, $server->{'kvm_gw'});
my @setgws = grep { $_ ne "*" } @gws;
if (!@setgws && $defgw) {
	@gws = ( $defgw );
	}
my $defgw6 = &get_server_default_ipv6_gateway($vhost);
my @gws6 = split(/\s+/, $server->{'kvm_gw6'});
my @setgws6 = grep { $_ ne "*" } @gws6;
if (!@setgws6 && $defgw6) {
	@gws6 = ( $defgw6 );
	}

# If root disk is on iSCSI, disconnect and re-connect
&remote_finished();
my $disks = &type_kvm_list_disks($server, 0);
if (ref($disks) && $disks->[0]->{'iscsi_server'} ne '') {
	&$first_print($text{'create_iscsireconnect'});
	&disconnect_iscsi_disk($server, $disks->[0]);
	my $err = &connect_iscsi_disk($server, $disks->[0]);
	if ($err) {
		&$second_print(&text('create_eiscsireconnect', $err));
		}
	else {
		&$second_print($text{'create_done'});
		}
	}

# Fix root disk device in /etc/fstab to match virtio mode
# XXX should this be sda? When?
my $wantdev = $server->{'kvm_virtio'} ? "/dev/vda" : "/dev/hda";
my $hasbootfs = 0;
if (!$empty && ($server->{'kvm_virtio'} != $img->{'kvm_virtio'} ||
		$img->{'kvm_virtio'} eq '')) {
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
				# Leave hda/sda unchanged if another variant
				# is selected
				next if ($wantdev =~ /^\/dev\/[hs]da/ &&
					 $f->[0] =~ /^\/dev\/[hs]da/);
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
my $grubdir = $hasbootfs ? "/grub" : "/boot/grub";
if (!$empty && ($server->{'kvm_virtio'} != $img->{'kvm_virtio'} ||
		$img->{'kvm_virtio'} eq '')) {
	&$first_print($text{'create_kvmgrub'});
	&mount_filesystem_if_needed($server, $grubdir);
	my $grubconf;
	my $data;
	foreach my $g ("$grubdir/menu.lst", "$grubdir/grub.conf",
		       "$grubdir/grub.cfg") {
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
		if ($wantdev =~ /^\/dev\/[hs]da$/ &&
		    $data =~ /root=\/dev\/[hs]da/) {
			# Assume that if hda/sda is in use and one of those
			# is what we want, that it is correct
			&$second_print($text{'create_kvmgrubhda'});
			}
		else {
			# Need to fix
			$data =~ s/ root=(\S+)(\d+)(\s|$)/ root=$wantdev$2$3/g;
			my $err = &put_file_data_to_server(
					$server, $data, $grubconf);
			if ($err) {
				&$second_print(&text('create_ekvmgrub', $err));
				}
			else {
				&$second_print($text{'create_done'});
				}
			}
		}
	&umount_filesystem_if_needed($server);
	}

# Fix grub configs to use ethN style interface names (as seen on Debian)
if (!$empty) {
	&$first_print($text{'create_kvmgrubeth'});
	my $flags = "net.ifnames=0 biosdevname=0";

	# Fix /etc/default/grub, from which the main .cfg file is generated
	&mount_filesystem_if_needed($server);
	my $grubdef = &get_file_data_from_server($server, "/etc/default/grub");
	if ($grubdef && $grubdef =~ /GRUB_CMDLINE_LINUX="(.*)"/) {
		my $cmdline = $1;
		if ($cmdline !~ /\Q$flags\E/) {
			$cmdline .= " " if ($cmdline);
			$cmdline .= $flags;
			$grubdef =~ s/GRUB_CMDLINE_LINUX="(.*)"/GRUB_CMDLINE_LINUX="$cmdline"/;
			my $err = &put_file_data_to_server($server, $grubdef,
					"/etc/default/grub");
			}
		}
	&umount_filesystem_if_needed($server);

	# Fix the actual grub config file
	&mount_filesystem_if_needed($server, $grubdir);
	my $grubconf;
	my $datafile = &transname();
	foreach my $g ("$grubdir/menu.lst", "$grubdir/grub.conf",
		       "$grubdir/grub.cfg") {
		my $err = &get_file_from_server($server, $g, $datafile);
		if (!$err) {
			$grubconf = $g;
			last;
			}
		}
	if (!$grubconf) {
		&$second_print(&text('create_ekvmgrubget'));
		}
	else {
		my $lref = &read_file_lines($datafile);
		foreach my $l (@$lref) {
			if ($l =~ /^\s*linux\s+.*root=/ && $l !~ /\Q$flags\E/) {
				$l .= " ".$flags;
				}
			}
		&flush_file_lines($datafile);
		my $err = &put_file_to_server($server, $datafile, $grubconf);
		if ($err) {
			&$second_print(&text('create_ekvmgrub', $err));
			}
		else {
			&$second_print($text{'create_done'});
			}
		}
	&umount_filesystem_if_needed($server);
	}

my ($fsfile, $swfile, $swsize);
if (!$empty && $server->{'kvm_swapfile'}) {
        # Create the swap file, if needed
	$swsize = $server->{'kvm_swap'}*1024*1024;
	$swfile = $server->{'kvm_swapfile'};
	my @st = &recursive_stat_file_on_server($vhost, $swfile);
	if (!@st || $server->{'kvm_swapfile_vg'} ||
	    $server->{'kvm_swapfile_iscsi'} ne '') {
		&$first_print(&text('create_xenswap',
				    &nice_size($swsize)));
		my ($out, $ex, $err);
		if (!$server->{'kvm_swapfile_vg'} &&
		    $server->{'kvm_swapfile_iscsi'} eq '') {
			# Zero out swap file, but only if a local file
			($out, $ex, $err) = &execute_command_on_server(
			  $vhost, &dd_command("/dev/zero", $swfile, $swsize));
			}
		if (!$err) {
			$err = &create_disk_image_partition($vhost, $swfile,
							    1, $swsize, 1, 0,
							    "linux-swap");
			}
		if (!$err) {
			$err = &create_disk_image_filesystem($vhost, $swfile,
							     "swap", 1);
			}
		if ($err) {
			&$second_print(&text('create_exenswap', $out));
			}
		else {
			&$second_print($text{'create_done'});
			}
		}
	}

if (!$empty && &mountable_filesystem($server)) {
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
	$fsfile = $server->{'kvm_filesystem'};
	if ($server->{'kvm_disksize'}) {
		my $dksize = $server->{'kvm_disksize'}*1024*1024;
		&start_background_dot_printer(
			&text('create_xenresize', &nice_size($dksize)));
		my $disks = &type_kvm_list_disks($server, 1);
		my $disk;
		if (ref($disks)) {
			($disk) = grep { $_->{'real'} eq
					 $server->{'kvm_filesystem'} } @$disks;
			}
		if (!$disk || !$disk->{'fs'}) {
			&stop_background_dot_printer();
			&$second_print(&text('create_exenresize2'));
			}
		elsif (&freebsd_server_type($server) ||
		       $disk->{'fs'} eq 'ufs') {
			&stop_background_dot_printer();
			&$second_print(&text('create_exenresizebsd'));
			}
		else {
			my $olddisk = { %$disk };
			$disk->{'size'} = $dksize;
			my $err = &type_kvm_modify_disk($server, $disk,
							$olddisk);
			&stop_background_dot_printer();
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

	# On FreeBSD, create an /etc/rc.local script that runs pwd_mkdb
	# so that any password change gets applied
	if ($server->{'type'} eq 'freebsd') {
		&put_file_data_to_server(
			$server,
			"/usr/sbin/pwd_mkdb -p /etc/master.passwd\n",
			"/etc/rc.local");
		}

	# Create authorized keys file
	if ($server->{'key'}) {
		&$first_print($text{'create_xensetkey'});
		my $err = &create_authorized_key($server);
		&$second_print($err ? &text('create_exensetkey', $err)
				    : $text{'create_done'});
		}
	elsif (!$img->{'keepkeys'}) {
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

        # Add the swap file to /etc/fstab, if any
        &$first_print($text{'create_xenfstab'});
        my $fstab = &get_system_fstab($server);
        if (!ref($fstab)) {
                &$second_print(&text('create_exenswaptab', $fstab));
                }
        else {
		my $wantdev = $server->{'kvm_virtio'} ? "/dev/vdb" : "/dev/hdb";
		my ($root) = grep { $_->[1] eq '/' } @$fstab;
		if ($root && $root->[0] =~ /^(\/dev\/[hsv]d)/) {
			# Can guess swap device based on root device, on a
			# Linux VM
			$wantdev = $1."b";
			}
		elsif ($root && $root->[0] =~ /^(\/dev\/(ada|da|ad))/) {
			# Can guess swap device from root, on FreeBSD VM
			$wantdev = $1."1";
			}
		if (&freebsd_server_type($server)) {
			# On FreeBSD, add p1 or s1 to get the partition
			if ($root && $root->[0] =~ /p1/) {
				$wantdev .= "p1";
				}
			else {
				$wantdev .= "s1";
				}
			}
		else {
			# On Linux, add 1 to get the first partition
			$wantdev .= "1";
			}
                my $changed_fstab;
                if ($server->{'kvm_swapfile'}) {
                        # Add swap device
                        my ($sw) = grep { $_->[0] eq $wantdev } @$fstab;
                        if (!$sw) {
				if (&freebsd_server_type($server)) {
					push(@$fstab, [ $wantdev, 'none',
						'swap', 'sw', 0, 0 ]);
					}
				else {
					push(@$fstab, [ $wantdev, 'swap',
						'swap', 'defaults', 0, 0, ]);
					}
                                $changed_fstab++;
                                }
                        }
                if ($changed_fstab) {
                        # Write out again
                        my $err = &put_system_fstab($server, $fstab);
                        if ($err) {
                                &$second_print(
                                        &text('create_exenswaptab', $err));
                                }
                        else {
                                &$second_print($text{'create_done'});
                                }
                        }
                else {
                        &$second_print(&text('create_xenswaptabok'));
                        }
                }

	# Apply IPv6 addresses to interfaces
	if (@ips6) {
		&$first_print($text{'create_xenipv6'});
		my $err = &apply_ipv6_addresses($server, \@ips6, \@netmasks6,
						\@gws6);
		if ($err) {
			&$second_print(&text('create_exenipv6', $err));
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

	# Set SSH port
	&$first_print($text{'create_sshport'});
	my $err = &set_ssh_port($server);
	if ($err) {
		&$second_print(&text('create_esshport', $err));
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
	if ($ips6[0]) {
		&add_bind8_record($dnsname, $ips6[0], $vhost->{'kvm_zone'});
		}
	}

# Start up the instance
my $started = 0;
if (!$nostart) {
	&$first_print($text{'create_kvmstartup'});
	my ($ok, $err) = &type_kvm_startup($server, $empty);
	if ($ok != 1) {
		&$second_print(&text('create_exenstartup', $err));
		}       
	else {
		&$second_print($text{'create_done'});
		$started = 1;
		}
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
# Shut down and then re-start
sub type_kvm_reboot
{
my ($server) = @_;
&type_kvm_shutdown($server, !&can_ssh_status($server));
return &type_kvm_startup($server);
}

# type_kvm_shutdown(&server, [force])
# SSH in and shutdown, or kill
sub type_kvm_shutdown
{
my ($server, $force) = @_;
my $vhost = &type_kvm_parent($server);
delete($kvm_check_login_procs_cache{$vhost->{'id'}});

# Remove all anti-spoof firewall rules
my $ifaces = &type_kvm_list_interfaces($server, 1);
if (ref($ifaces) && !&check_firewall_allowed_ips($server)) {
	foreach my $iface (grep { $_->{'tap'} } @$ifaces) {
		&activate_firewall_commands($server, "", $iface->{'tap'});
		}
	}

# If paused, delete any pause file
if ($server->{'kvm_pause'}) {
	&delete_file_on_server($vhost, $server->{'kvm_pause'});
	delete($server->{'kvm_pause'});
	}

if (&can_ssh_status($server) && !$force) {
	# Sync filesystems first, to avoid corruption
	&execute_command_on_server($server, "sync ; sync ; sync", $short_timeout);
	}
my $proc = &get_server_kvm_instance($server);
my $wait = $config{'kvm_powerdown'} || 30;
if (&can_ssh_status($server) && !$force) {
	# Try poweroff command
	my ($out, $ex, $err) = &execute_command_on_server($server,
		  "poweroff >/dev/null 2>&1 </dev/null &", $short_timeout);
	return $err if ($err);
	return $out if ($ex);

	# Wait 30 seconds for shutdown
	my $tries = 0;
	while($tries < $wait) {
		my ($kout, $kex, $kerr) = &execute_command_on_server(
					$vhost, "kill -0 $proc->{'pid'}", $short_timeout);
		if ($kex && !$kerr) {
			&delete_kvm_cgroup($server, $vhost);
			return undef;
			}
		sleep(1);
		$tries++;
		}
	#return "Failed to shut down after 30 seconds";
	}

# Next try shutdown monitor command
if (!$force) {
	my ($mok, $merr) = &run_kvm_monitor_command($server,
				[ "system_powerdown" ]);
	if ($mok) {
		# Wait for it to work
		my $tries = 0;
		while($tries < $wait) {
			my ($kout, $kex) = &execute_command_on_server(
					$vhost, "kill -0 $proc->{'pid'}");
			if ($kex) {
				&delete_kvm_cgroup($server, $vhost);
				return undef;
				}
			sleep(1);
			$tries++;
			}
		}
	}

$proc = &get_server_kvm_instance($server);
if ($proc) {
	# Just kill it
	my ($out, $ex, $err) = &execute_command_on_server($vhost,
					"kill -9 $proc->{'pid'}");
	return $err if ($err);
	return $out if ($ex);
	&delete_kvm_cgroup($server, $vhost);
	return undef;
	}
return "No KVM process found!";
}

# type_kvm_startup(&server, [no-ping], [extra-args])
# Start the kvm or qemu-kvm process, and wait till it responds to ping and SSH
sub type_kvm_startup
{
my ($server, $noping, $extra) = @_;
if ($server->{'ssh_nologin'} && $server->{'ssh_noping'}) {
	$noping = 1;
	}
my $vhost = &type_kvm_parent($server);
delete($kvm_check_login_procs_cache{$vhost->{'id'}});
&find_qemu_kvm_command($vhost) ||
	return (0, "KVM command was not found!");
my $cmd = &get_kvm_start_command($server, 0, $extra, 0);
my ($pinged, $sshed);

# Double-check if already running
my $instances = &list_kvm_instances($vhost);
if (ref($instances)) {
	my ($already) = grep { &match_kvm_instance($server, $_) } @$instances;
	if ($already) {
		return (0, "Already running with process ID $already->{'pid'}");
		}
	}

# Re-generate interface scripts
my @nets = split(/\s+/, $server->{'kvm_net'});
my @bridges = split(/\s+/, $server->{'kvm_hostifaces'});
my $i = 0;
my $changed_net = 0;
foreach my $net (@nets) {
	my $bridge = $bridges[$i];
        if ($net =~ /script=([^,]+-(eth\d+)\.sh)/) {
		# Update the existing bridge script
		my $script = $1;
		my $eth = $2;
		$bridge = undef if ($bridge eq '*');
		my ($data, undef) = &generate_kvm_bridge_script(
			$server, { 'name' => $eth }, $bridge);
		&put_file_data_to_server($vhost, $data, $script);
		&execute_command_on_server($vhost, "chmod +x $script");
		}
	else {
		# Create a bridge script, so that the tap device is recorded
		my $eth = "eth".$i;
		my ($data, $script) = &generate_kvm_bridge_script(
			$server, { 'name' => $eth }, $bridge);
		if (!&put_file_data_to_server($vhost, $data, $script)) {
			&execute_command_on_server($vhost, "chmod +x $script");
			$net .= ",script=".$script;
			$changed_net++;
			}
		}
	$i++;
	}
if ($changed_net) {
	# Re-save after setting up script
	$server->{'kvm_net'} = join(" ", @nets);
	&save_managed_server($server);
	}

# Make sure we have nc.pl
my $ncerr = &upload_nc_script($vhost);
return (0, "Failed to create nc.pl : $ncerr") if ($ncerr);

# Create a console output file and monitor input file
$server->{'kvm_console'} ||= &get_kvm_console_file($server);
my $oldmon = $server->{'kvm_monitor'};
my $oldpass = $server->{'kvm_vnc_passwd'};
my $err = &create_kvm_monitor_file($server);
if ($oldmon ne $server->{'kvm_monitor'} ||
    $oldpass ne $server->{'kvm_vnc_passwd'}) {
	# Re-save after setting password for VNC
	&save_managed_server($server);
	}
return (0, "Failed to create monitor input file : $err") if ($err);

# If on iSCSI, re-connect any disconnected disks
if ($server->{'kvm_filesystem_iscsi'} ne '') {
	my $disks = &type_kvm_list_disks($server, 0);
	if (ref($disks)) {
		foreach my $d (@$disks) {
			if ($d->{'iscsi_server'} ne '' &&
			    $d->{'iscsi_connect'} == 0) {
				&connect_iscsi_disk($server, $d);
				}
			}
		}
	}

# Run qemu-kvm to start it up, in the background
my ($out, $ex, $err) = &execute_command_on_server($vhost,
	"$cmd >$server->{'kvm_console'} 2>&1 </dev/null &");
return (0, $err) if ($err);
return (0, $out || "Unknown error") if ($ex);

# Wait 60 seconds for it to start
my $tries = 0;
my $found = 0;
while($tries++ < 60) {
	my $proc = &get_server_kvm_instance($server);
	if ($proc) {
		$server->{'kvm'} = $proc->{'pid'};
		$found++;
		last;
		}
	sleep(1);
	$tries++;
	}

# Set the VNC password
my ($pok, $perr);
if ($found) {
	($pok, $perr) = &run_kvm_monitor_command($server,
			[ "change vnc password",
			  $server->{'kvm_vnc_passwd'} ], 3);
	}

# If this is an un-pause, continue the VM
if ($extra =~ /-incoming/) {
	&run_kvm_monitor_command($server, [ "cont" ], 3, -1);
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
if (defined($pinged) && $pinged && !$server->{'ssh_nologin'}) {
	$sshed = &wait_for_ssh($server);
	}

# Re-check which IPs are really active
if ($sshed) {
	&compute_ip_addresses($server);
	}

# Return an error if something went wrong
if (defined($pinged) && !$pinged) {
	return (2, &text('kvm_estartping', $config{'ping_wait_timeout'}));
	}
if (defined($sshed) && !$sshed) {
	return (3, &text('kvm_estartssh', $config{'ping_wait_timeout'}));
	}

if (!$pok) {
	return (0, &text('kvm_estartpass', $perr));
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
my $kvm_dir = $server->{'directory'} || $vhost->{'kvm_dir'};

# Force shutdown if needed
my $proc = &get_server_kvm_instance($server);
if ($proc) {
	&type_kvm_shutdown($server, 1);
	$server->{'status'} = 'down';
	}
&delete_kvm_cgroup($server, $vhost);

# Remove all anti-spoof firewall rules, if the VM wasn't running. This is 
# needed if it was shutdown outside of Cloudmin.
if (!$proc) {
	my $ifaces = &type_kvm_list_interfaces($server, 1);
	if (ref($ifaces) && !&check_firewall_allowed_ips($server)) {
		foreach my $iface (grep { $_->{'tap'} } @$ifaces) {
			&activate_firewall_commands(
				$server, "", $iface->{'tap'});
			}
		}
	}

# Delete boot-time entry
&type_kvm_set_atboot($server, 0);

# Delete virtual disks
if (!$keep) {
	my $disks = &type_kvm_list_disks($server, 0);
	if (ref($disks)) {
		foreach my $d (reverse(@$disks)) {
			my @st = &recursive_stat_file_on_server(
					$vhost, $d->{'real'});
			next if (!@st);			# Already gone
			next if ($d->{'media'} eq 'cdrom' &&
				 $d->{'real'} ne $server->{'kvm_cdimage'} &&
				 !$d->{'device'});	# CD image in file
			next if ($d->{'device'} &&	# Attached real device
				 $d->{'iscsi_server'} eq '' &&
				 !$d->{'lv'});
			my $err = &type_kvm_delete_disk($server, $d, 0, 1);
			return $err if ($err);
			}
		}
	}

# Delete mount dir
if (!$keep) {
	&delete_file_on_server($vhost, "/mnt/kvm-".$server->{'host'});
	}

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
if ($server->{'kvm_ip6'}) {
	&delete_bind8_record($server->{'kvm_dns'}, $vhost->{'kvm_zone'},
			     &to_ip6address($server->{'host'}));
	}

# Remove DHCP entries
&delete_all_iface_dhcpd($server);

# Delete bridge scripts, and files containing tap interface names
my @nets = split(/\s+/, $server->{'kvm_net'});
foreach my $net (@nets) {
	if ($net =~ /script=([^,]+)/) {
		my $script = $1;
                if ($script =~ /^\Q$kvm_dir\/\E/) {
                        &delete_file_on_server($vhost, $script);
			local $tapfile = $script;
			if ($tapfile =~ s/\.sh$/\.tap/) {
				&delete_file_on_server($vhost, $tapfile);
				}
                        }
		}
	}

return undef;
}

# get_kvm_start_command(&server, [for-boot], [extra-args], [startup-delay])
# Returns the full command line to start a KVM instance
sub get_kvm_start_command
{
my ($server, $forboot, $extra, $delay) = @_;
my $vhost = &type_kvm_parent($server);
my $inuse = &list_ports_in_use($vhost, "tcp");
my $cmd = &find_qemu_kvm_command($vhost);

# Name flag, if supported
if (&kvm_host_supports_flag($vhost, "name")) {
	$cmd .= " -name ".quotemeta($server->{'host'});
	}

# Memory flag
$cmd .= " -m ".$server->{'kvm_memory'};

# Add disks
my $ver = &kvm_host_version($vhost);
foreach my $d (split(/\s+/, $server->{'kvm_drives'})) {
	if ($ver && &compare_versions($ver, "1.1") >= 0) {
		$d =~ s/,boot=on//g;	# No longer needed
		}
	$cmd .= " -drive $d";
	}

# Boot device
$cmd .= " -boot ".($server->{'kvm_bootdevice'} || 'c');

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

# Figure out ports used by other known VMs
my @vmports = map { $_->{'kvm_vnc_display'}+5900 }
		  grep { $_->{'kvm_vnc_display'} &&
			 $_->{'id'} ne $server->{'id'} }
		       &list_managed_servers();

# VNC settings, on a free port
if (ref($inuse)) {
	# Add VNC flag with random port, if none has been set yet OR if some
	# other system or command is using the same port
	if (!$server->{'kvm_vnc_display'} ||
	    &indexof($server->{'kvm_vnc_display'}+5900, @vmports) ||
	    (!$forboot &&
	     &indexof($server->{'kvm_vnc_display'}+5900, @$inuse))) {
		push(@$inuse, @vmports);
		my $vport = 5901;
		while(1) {
			last if (&indexof($vport, @$inuse) < 0 &&
				 &indexof($vport - 200, @$inuse) < 0);
			$vport++;
			}
		$server->{'kvm_vnc_display'} = $vport-5900;
		}
	$cmd .= " -vnc :".$server->{'kvm_vnc_display'}.",password";
	if (&kvm_host_version($vhost) >= 1.5) {
		# Can also enable websockets
		$server->{'kvm_vnc_websocket'} =
			$server->{'kvm_vnc_display'} + 5700;
		$cmd .= ",websocket=".$server->{'kvm_vnc_websocket'};
		}

	# Enable high-resolution mode
	if ($server->{'kvm_vga'}) {
		if (&kvm_host_supports_flag($vhost, "std-vga")) {
			$cmd .= " -std-vga";
			}
		elsif (&kvm_host_supports_flag($vhost, "vga.*std")) {
			$cmd .= " -vga std";
			}
		}

	# Enable tablet USB device, to fix mouse pointer
	if (&kvm_host_supports_flag($vhost, "usbdevice")) {
		$cmd .= " -usbdevice tablet";
		}
	}
else {
	# Disable graphics
	$cmd .= " -nographic";
	}

# Allocate a free port for the monitor
if (!$server->{'kvm_monitor_port'}) {
	my $mport = 40000;
	my @minuse;
	push(@minuse, @$inuse) if (ref($inuse));
	push(@minuse, map { $_->{'kvm_vnc_display'}+5900 }
			  grep { $_->{'kvm_vnc_display'} }
			       &list_managed_servers());
	push(@minuse, map { $_->{'kvm_monitor_port'} }
			  grep { $_->{'kvm_monitor_port'} }
			       &list_managed_servers());
	while(1) {
		last if (&indexof($mport, @minuse) < 0);
		$mport++;
		}
	$server->{'kvm_monitor_port'} = $mport;
	}
$cmd .= " -monitor tcp:127.0.0.1:$server->{'kvm_monitor_port'},server";

# Add keymap flag
if ($server->{'kvm_keymap'}) {
	$cmd .= " -k ".$server->{'kvm_keymap'};
	}

# Add SMP flag
if ($server->{'kvm_smp'}) {
	$cmd .= " -smp ".$server->{'kvm_smp'};
	if ($server->{'kvm_smp_cores'} > 1) {
		$cmd .= ",cores=".$server->{'kvm_smp_cores'};
		}
	}

# Add other imported flags
if ($server->{'kvm_args'}) {
	$cmd .= " ".$server->{'kvm_args'};
	}
$cmd .= " ".$extra if ($extra);

# If cgroups are supported, run kvm command in one
if ($server->{'kvm_ioclass'} ne '') {
	$cmd = "ionice -n$server->{'kvm_ioclass'} $cmd";
	}
my @cmds;
if ($delay ne '') {
	push(@cmds, "sleep $delay");
	}
if ($vhost->{'kvm_cgroup_support'}) {
	push(@cmds, "test -d $vhost->{'kvm_cgroup_dir'}/cpu || sleep 20",
		    "cgcreate -g cpu:$server->{'id'}");
	if ($server->{'kvm_cpu'}) {
		my $n = int($server->{'kvm_cpu'} * 1024 / 100);
		push(@cmds, "echo $n >$vhost->{'kvm_cgroup_dir'}/cpu/$server->{'id'}/cpu.shares");
		}
	push(@cmds, "exec cgexec -g cpu:$server->{'id'} $cmd");
	}
else {
	push(@cmds, $cmd);
	}

return "(".join(" ; ", @cmds).")";
}

# generate_kvm_bridge_script(&server, &iface, [bridge])
# Returns the contents of and path to a script to connect the right bridge
# for a virtual interface
sub generate_kvm_bridge_script
{
my ($server, $iface, $bridge) = @_;
my $vhost = &type_kvm_parent($server);
my $brctl = &has_command_on_server($vhost, "brctl");
my $ip = &has_command_on_server($vhost, "ip");
my $ifconfig = &has_command_on_server($vhost, "ifconfig") || "ifconfig";
my $kvm_dir = $server->{'directory'} || $vhost->{'kvm_dir'};
my $data = "#!/bin/sh\n".
	   "echo \$1 >".$kvm_dir."/".
	     $server->{'host'}."-".$iface->{'name'}.".tap\n";
if (!$bridge || $bridge eq "*") {
	($bridge) = &list_host_bridges($vhost);
	$bridge ||= "br0";
	}
if ($brctl) {
	$data .= "$brctl addif $bridge \$1\n";
	}
elsif ($ip) {
	$data .= "$ip link set dev \$1 master $bridge\n";
	}
if ($ip) {
	# Use ip command
	$data .= "$ip link set dev \$1 up\n";
	$data .= "mtu=`$ip link | head -1 | grep ${bridge}: | sed -e 's/.*mtu //; s/ .*//'`\n";
	$data .= "if [ \"\$mtu\" != \"\" ]; then\n";
	$data .= "    $ip link set dev \$1 mtu \$mtu\n";
	$data .= "fi\n";
	}
else {
	# Use ifconfig command
	$data .= "$ifconfig \$1 up\n";
	$data .= "mtu=`$ifconfig $bridge | grep MTU | sed -e 's/.*MTU://; s/ .*//'`\n";
	$data .= "if [ \"\$mtu\" != \"\" ]; then\n";
	$data .= "    $ifconfig \$1 mtu \$mtu\n";
	$data .= "fi\n";
	}
if (!&check_firewall_allowed_ips($server)) {
	# Add commands to limit allowed IPs and MACs, or not
	my @ips = $server->{'kvm_firewall'} eq '' ? ( ) :
		  $server->{'kvm_firewall'} eq '*' ?
			&get_all_firewall_addresses($server) :
			( split(/\s+/, $server->{'kvm_firewall'}),
			  &get_server_mac($server) );
	foreach my $cmd (&get_firewall_commands($server, \@ips, '$1')) {
		$data .= $cmd."\n";
		}
	}
return ($data,
	$kvm_dir."/".$server->{'host'}."-".$iface->{'name'}.".sh");
}

# type_kvm_can_disks(&server)
# Returns 1, as we can manage disks for KVM instances. These are files or
# devices mapped to virtual disks in the instance.
sub type_kvm_can_disks
{
my ($server) = @_;
return $server->{'status'} ne 'nohost' ? 1 : 0;
}

# type_kvm_can_safely_resize_disk(&server, &disk, &old-disk)
# Returns undef if some disk can be safely resized, or an error message if not
sub type_kvm_can_safely_resize_disk
{
my ($server, $disk, $olddisk) = @_;
if (!$disk->{'fs'}) {
	return $text{'disk_eresizefs'};
	}
elsif ($disk->{'fs'} eq 'ufs') {
	#my $vhost = &type_kvm_parent($server);
	#&has_command_on_server($vhost, "growfs.ufs") ||
	#	return $text{'disk_eresizefsufs'};
	#return undef;
	return $text{'disk_eresizefsufs2'};
	}
elsif ($disk->{'fs'} eq 'xfs') {
	$disk->{'size'} >= $olddisk->{'size'} ||
		return $text{'disk_eshrinkxfs'};
	my $vhost = &type_kvm_parent($server);
	&has_command_on_server($vhost, "xfs_growfs") ||
		return $text{'disk_eresizefsxfs'};
	return undef;
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

# Check if any disk are on LVM
my $lvmcount = 0;
foreach my $dstr (split(/\s+/, $server->{'kvm_drives'})) {
	if ($dstr =~ /file=\/dev\/[^\/]+\/[^\/]+,/) {
		$lvmcount++;
		}
	}

# If LVM is in use, get LVs from the host system
my (@lvs, @vgs);
my $lvm_error;
$last_remote_error = undef;
if ($server->{'kvm_filesystem_vg'} || $lvmcount) {
	if ($main::list_logical_cache{$vhost->{'id'}}) {
		@lvs = @{$main::list_logical_cache{$vhost->{'id'}}};
		@vgs = @{$main::list_volume_cache{$vhost->{'id'}}};
		}
	else {
		&remote_foreign_require($vhost, "lvm", "lvm-lib.pl");
		@vgs = &remote_foreign_call($vhost, "lvm",
			"list_volume_groups");
		$lvm_error = $last_remote_error;
		if (!$lvm_error) {
			$main::list_volume_cache{$vhost->{'id'}} = \@vgs;
			@lvs = ( );
			foreach my $vg (@vgs) {
				push(@lvs, &remote_foreign_call($vhost, "lvm",
					"list_logical_volumes", $vg->{'name'}));
				}
			$main::list_logical_cache{$vhost->{'id'}} = \@lvs;
			}
		}
	}
my %vgnames = map { $_->{'name'}, $_ } @vgs;

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
		     'cache' => $drive{'cache'},
		     'format' => 'disk' };
	if ($disk->{'media'} eq 'cdrom') {
		# Can change device, but not size
		$disk->{'change'} = 1;
		$disk->{'fixedsize'} = 1;
		}
	$disk->{'device'} = $drive{'file'} =~ /^\/dev\// ? 1 : 0;
	if (!$disk->{'device'}) {
		my @st = &stat_file_on_server($vhost, $drive{'file'});
		$disk->{'size'} = $st[7];
		}
	if ($disk->{'real'} =~ /^\/dev\/([^\/]+)\/([^\/]+)$/ &&
	    $vgnames{$1}) {
		# Disk is on LVM
		$disk->{'vg'} = $1;
		$disk->{'lv'} = $2;
		my ($lv) = grep { $_->{'name'} eq $disk->{'lv'} } @lvs;
		if ($lv) {
			$disk->{'size'} = $lv->{'size'} * 1024;
			$disk->{'lv_snap_of'} = $lv->{'snap_of'};
			$disk->{'thin'} = $lv->{'thin_in'};
			}
		elsif ($lvm_error) {
			# Disk is on LVM, but failed to get details
			return "Failed to fetch LVM devices : $lvm_error";
			}
		else {
			return "Logical volume $disk->{'lv'} was not found";
			}
		if ($disk->{'thin'}) {
			$disk->{'storage_id'} =
				'thin_'.$disk->{'vg'}.'_'.$disk->{'thin'};
			$disk->{'storage'} = &text('storage_thin',
						   $disk->{'thin'});
			}
		else {
			$disk->{'storage_id'} = 'lvm_'.$disk->{'vg'};
			$disk->{'storage'} = &text('storage_lvm',
						   $disk->{'vg'});
			}
		}
	elsif ($disk->{'real'} =~ /^\/dev\/disk\/by-path\/ip-(\S+):(\d+)-iscsi-(\S+):(\S+)-lun-(\d+)$/) {
		# Disk is on an iSCSI server
		$disk->{'iscsi_ip'} = $1;
		$disk->{'iscsi_port'} = $2;
		$disk->{'iscsi_name'} = $3;
		$disk->{'iscsi_target'} = $4;
		$disk->{'iscsi_lun'} = $5;
		$disk->{'iscsi_connect'} = 0;
		$disk->{'fixedreal'} = 1;
		my $iscsiserver = &get_managed_server_by(
					"ip", $disk->{'iscsi_ip'});
		if ($iscsiserver) {
			$disk->{'iscsi_server'} = $iscsiserver->{'id'};
			}

		# Get size from /proc/partitions on host
		my $realdevice;
		my ($out, $ex, $err) = &execute_command_on_server(
					$vhost, "readlink $disk->{'real'}");
		if (!$ex && !$err && $out =~ /\/(sd[a-z]+)/) {
			$realdevice = $1;
			}
		($out, $ex, $err) = &execute_command_on_server(
					$vhost, "cat /proc/partitions");
		if (!$ex && !$err && $realdevice) {
			foreach my $l (split(/\r?\n/, $out)) {
				$l =~ s/^\s+//;
				my ($major, $minor, $blocks, $name) =
					split(/\s+/, $l);
				if ($name eq $realdevice) {
					$disk->{'size'} = $blocks * 1024;
					$disk->{'iscsi_connect'} = 1;
					}
				}
			}
		$disk->{'storage_id'} = 'iscsi_'.$iscsiserver->{'host'};
		$disk->{'storage'} = &text('storage_iscsi',
					   $iscsiserver->{'host'});
		}
	else {
		# Disk is just in a regular file
		$disk->{'storage_id'} = 'files';
		$disk->{'storage'} = $text{'storage_files'};
		}
	$disk->{'index'} = scalar(@rv);
	if ($disk->{'real'} && $disk->{'real'} eq $server->{'kvm_swapfile'}) {
		# Disk is the swapfile
		$disk->{'swap'} = 1;
		}
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
			       &sort_system_fstab(@$fstab);
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
				# A label was found, use the underlying virtual
				# device instead
				($f) = grep { $_->[0] eq 'LABEL='.$label ||
					     uc($_->[0]) eq 'UUID='.uc($label) }
					    @$fstab;
				if ($f) {
					$f->[0] = $label_to_part{$label};
					$d->{'virt_label'} = $label;
					}
				}
			}
		if (!$f) {
			# If no fstab entry was found but there is only one
			# disk with one partition, it must be the root
			my ($rootf) = grep { $_->[1] eq '/' } @$fstab;
			my $parts = &list_disk_image_partitions($vhost,
								$d->{'real'});
			if ($rootf && ref($parts) && @$parts == 1 &&
			    $d->{'real'} eq $server->{'kvm_filesystem'}) {
				$f = $rootf;
				$f->[0] = $d->{'virt'}.'1';
				}
			}
		if ($f) {
			$d->{'virt_mount'} = $f->[0];
			$d->{'virt_onsystem'} = $f->[0];
			if ($d->{'virt_onsystem'} =~
			    /^\/dev\/(s|h|v)d[a-z]+\d+$/) {
				# Change mount point on Linux like /dev/hda1 to
				# disk device like /dev/hda
				$d->{'virt_onsystem'} =~ s/\d+$//;
				}
			elsif ($d->{'virt_onsystem'} =~
			       /^\/dev\/(ada|ad|da)\d+s/) {
				# Change mount point on FreeBSD like
				# /dev/ada0s1a to disk device like /dev/ada0
				$d->{'virt_onsystem'} =~ s/s\d+[a-z]?$//;
				}
			$d->{'mount'} = $f->[1];
			$d->{'fs'} = $f->[2];
			if (&freebsd_server_type($server) &&
			    $f->[0] =~ /s(\d+)[a-z]?$/) {
				# Get partition number on FreeBSD
				$d->{'virt_part'} = $1;
				}
			elsif (!&freebsd_server_type($server) &&
			       $f->[0] =~ /(\d+)$/) {
				# Partition number on Linux
				$d->{'virt_part'} = $1;
				}
			if ($d->{'fs'} eq 'swap') {
				$d->{'swap'} = 1;
				}
			}
		}

	# Check if actually mounted
	if (&can_ssh_status($server)) {
		my $mounted = &get_mounted_map($server);
		foreach my $d (@rv) {
			$d->{'mounted'} = $mounted->{$d->{'virt'}} ||
					  $mounted->{$d->{'virt_mount'}};
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

# type_kvm_list_disk_partitions(&server, &disk)
# Returns an array ref of partitions on some disk
sub type_kvm_list_disk_partitions
{
my ($server, $disk) = @_;
my $vhost = &type_kvm_parent($server);
return &list_disk_image_partitions($vhost, $disk->{'real'});
}

# type_kvm_list_disk_devices(&server)
# Quick function to return just the list of disk files a KVM instances uses
sub type_kvm_list_disk_devices
{
my ($server) = @_;
my @rv;
foreach my $dstr (split(/\s+/, $server->{'kvm_drives'})) {
	my %drive = map { split(/=/, $_, 2) } split(/,/, $dstr);
	push(@rv, $drive{'file'}) if ($drive{'file'});
	}
return @rv;
}

# type_kvm_need_disk_reboot(&server, &disk, &old-disk)
# A reboot is needed unless hot-adding is possible, to apply the new
# command line
sub type_kvm_need_disk_reboot
{
my ($server, $disk, $olddisk) = @_;
if ($server->{'status'} eq 'down') {
	return 0;	# Already down, no need to reboot
	}
elsif ($disk && $disk->{'reboot'}) {
	return 1;	# Attaching while running failed
	}
elsif ($olddisk && $olddisk->{'reboot'}) {
	return 1;	# Detaching while running failed
	}
elsif ($server->{'kvm_monitor_port'} && $disk &&
       $disk->{'virt'} !~ /\/hd/) {
	return 0;	# Can live attach non-IDE disk
	}
elsif ($server->{'kvm_monitor_port'} && $olddisk &&
       $olddisk->{'virt'} !~ /\/hd/) {
	return 0;	# Can live detach non-IDE disk
	}
elsif ($server->{'kvm_monitor_port'} && $disk && $olddisk &&
       $disk->{'media'} eq 'cdrom' &&
       $disk->{'virt'} eq $olddisk->{'virt'}) {
	return 0;	# Can change real device of CD-ROM live
	}
else {
	return 1;
	}
}

# type_kvm_new_disk(&server, &disks, real?, [&storage], [disk-index])
# Returns a structure for a new disk on some KVM system
sub type_kvm_new_disk
{
my ($server, $disks, $device, $storage, $index) = @_;
my $rv = { };

# Find which device files are used
my %used;
foreach my $d (@$disks) {
	$used{$d->{'virt'}}++;
	if ($d->{'virt'} =~ /^(\/dev\/(s|h|v)d)([a-z])$/) {
		$used{"/dev/sd".$3}++;
		$used{"/dev/hd".$3}++;
		$used{"/dev/vd".$3}++;
		}
	}
if (!&freebsd_server_type($server)) {
	$used{"/dev/hdc"}++;	# Typically for CD-ROM, on Linux
	}

# Pick a /dev/???? file that is free on the virtual system
my $n;
if ($disks->[0]->{'virt'} =~ /^(\/dev\/(s|h|v)d)[a-z]$/) {
	# Pick a free partition on the next disk
	$prefix = $1;
	for($n='a'; $used{$prefix.$n}; $n=chr(ord($n)+1)) { }
	$prefix .= $n;
	$rv->{'virt'} = $prefix;
	if ($disks->[0]->{'virt_onsystem'} =~ /^(\/dev\/(s|h|v)d)[a-z]$/) {
		# Use same device path as root, on Linux
		$rv->{'virt_onsystem'} = $1.$n;
		}
	elsif ($disks->[0]->{'virt_onsystem'} =~ /^(\/dev\/(ada|ad|da))(\d+)/) {
		# Use same device as root, on FreeBSD, then construct a path for
		# the new disk like /dev/ada1
		$rv->{'virt_onsystem'} = $1.(ord($n)-97);
		}
	else {
		$rv->{'virt_onsystem'} = $rv->{'virt'};
		}
	if ($rv->{'virt_onsystem'} =~ /^(\/dev\/(ada|ad|da))/) {
		# Mount point on FreeBSD is like /dev/ada1s1
		$rv->{'virt_mount'} = $rv->{'virt_onsystem'}."s1";
		}
	else {
		# Mount point on Linux is like /dev/hdb1
		$rv->{'virt_mount'} = $rv->{'virt_onsystem'}."1";
		}
	}
else {
	# No idea .. just guess
	$rv->{'virt_onsystem'} = $rv->{'virt'} = "/dev/hdb";
	$rv->{'virt_mount'} = $rv->{'virt_onsystem'}."1";
	}
$rv->{'virt_part'} = 1;
$rv->{'virt_auto'} = $rv->{'virt'};

if (!$device) {
	my $vhost = &type_kvm_parent($server);
	my $kvm_dir = ($storage ? $storage->{'directory'} : undef) ||
		      $server->{'new_directory'} || $vhost->{'kvm_dir'};
	my ($vg, $thin);
	my $iscsi;
	if ($storage) {
		if ($storage->{'id'} =~ /^lvm_(\S+)/) {
			$vg = $1;
			}
		elsif ($storage->{'id'} =~ /^thin_(\S+)_(\S+)/) {
			$vg = $1;
			$thin = $2;
			}
		elsif ($storage->{'id'} =~ /^iscsi_(\S+)/) {
			my $iscsiserver = &get_managed_server_by("host", "$1");
			$iscsi = $iscsiserver->{'id'};
			}
		elsif ($storage->{'id'} eq 'iscsi') {
			$iscsi = $server->{'kvm_filesystem_iscsi'};
			}
		$rv->{'storage_id'} = $storage->{'id'};
		}
	else {
		$vg = $server->{'kvm_filesystem_vg'};
		$iscsi = $server->{'kvm_filesystem_iscsi'};
		$rv->{'storage_id'} = $vg ? 'lvm_'.$vg :
				      $iscsi ne '' ? 'iscsi' : 'files';
		}
	my $filenum = defined($index) ? $index : (scalar(@$disks)+1);
	if ($vg) {
		# Create an LVM name
		$rv->{'vg'} = $vg;
		$rv->{'lv'} = $server->{'host'}."_".$filenum."_img";
		$rv->{'lv'} =~ s/\./_/g;
		$rv->{'thin'} = $thin;
		$rv->{'real'} = "/dev/".$rv->{'vg'}."/".$rv->{'lv'};
		}
	elsif ($iscsi ne '') {
		# Disk will be on an iSCSI server. The real field gets set later
		$rv->{'iscsi_server'} = $iscsi;
		$rv->{'fixedreal'} = 1;
		}
	else {
		# Pick an image file
		$rv->{'real'} = "$kvm_dir/$server->{'host'}.".
				$filenum.".img";
		$rv->{'dir'} = $kvm_dir;
		}
	}
$rv->{'format'} = 'disk';
$rv->{'device'} = $device;
$rv->{'media'} = 'disk';
return $rv;
}

# type_kvm_create_disk(&server, &disk, [bootable], [don't-add-to-config])
# Adds a new virtual disk to a KVM system's config.
# If this is a real file that doesn't exist yet, create it and optionally mkfs
# it. Also add to the /etc/fstab file, if requested.
sub type_kvm_create_disk
{
my ($server, $disk, $bootable, $noconfig) = @_;
my $vhost = &type_kvm_parent($server);

# Fix up virt_mount if virt was changed
if ($disk->{'virt_auto'} && $disk->{'virt'} ne $disk->{'virt_auto'}) {
	if ($disk->{'virt_onsystem'} =~ /^(\/dev\/(s|h|v)d)[a-z]/) {
		# Convert the entered device path that appears on the KVM
		# command line like /dev/hda1 to the path used inside the VM,
		# like /dev/vda1
		my $prefix = $1;
		if ($disk->{'virt'} =~ /^\/dev\/(s|h|v)d([a-z]\d*)$/) {
			$disk->{'virt_onsystem'} = $prefix.$2;
			}
		}
	# XXX does something need to be done here for FreeBSD paths?
	$disk->{'virt_mount'} = $disk->{'virt_onsystem'}.'1';
	}

my @st = &recursive_stat_file_on_server($vhost, $disk->{'real'});
if ($disk->{'device'} && !$disk->{'lv'} || $disk->{'new'} == 2) {
	# Check if the device exists, for when an existing file or device
	# is being added
	@st || return "Device $disk->{'real'} does not exist ".
		      "on $vhost->{'host'}";
	}
else {
	# A new disk file or LV is being created
	@st || $disk->{'size'} || $disk->{'iscsi_target'} ||
		return "Missing size for new disk";
	if ($disk->{'lv'} && $disk->{'overwrite'}) {
		# Delete existing LV
		&delete_all_disk_image_partitions($vhost, $disk->{'real'});
		&delete_mapper_entries($vhost, $disk->{'vg'}, $disk->{'lv'});
		&remote_foreign_require($vhost, "lvm", "lvm-lib.pl");
		&remote_foreign_call($vhost, "lvm",
				     "delete_logical_volume",
				     { 'device' => $disk->{'real'} });
		}
	elsif (@st && $disk->{'overwrite'}) {
		# Delete existing file
		&delete_file_on_server($vhost, $disk->{'real'});
		@st = ( );
		}

	if ($disk->{'lv'}) {
		# Create the logical volume
		$last_remote_error = undef;
		&remote_foreign_require($vhost, "lvm", "lvm-lib.pl");
		my $lv = { 'name' => $disk->{'lv'},
			   'size' => int($disk->{'size'}/1024),
			   'perm' => 'rw',
			   'alloc' => 'n',
			   'vg' => $disk->{'vg'},
			   'thin_in' => $disk->{'thin'}, };
		my $err = &remote_foreign_call($vhost, "lvm",
					       "create_logical_volume", $lv);
		$err ||= $last_remote_error;
		return "LVM logical volume creation failed : $err" if ($err);

		# Invalidate LV cache for host
		delete($main::list_logical_cache{$vhost->{'id'}});

		# Zero out first 32k
		my $cmd = &dd_command("/dev/zero", $disk->{'real'}, 32768);
		my ($out, $ex, $err) = &execute_command_on_server(
						$vhost, $cmd);
		$err = $out if ($ex);
		$err && return "Failed to zero out $disk->{'real'} : $err";
		}
	elsif ($disk->{'iscsi_server'} ne '' && $disk->{'iscsi_target'}) {
		# Attach to iSCSI disk
		my $err = &attach_iscsi_disk($server, $disk);
		return $err if ($err);
		@st = &stat_file_on_server($vhost, $disk->{'real'});
		}
	elsif ($disk->{'iscsi_server'} ne '' && !$disk->{'iscsi_target'}) {
		# Create iSCSI disk
		my $err = &create_iscsi_disk($server, $disk);
		return $err if ($err);
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
		my $ptype = &freebsd_server_type($server) ? "ufs" : "ext2";
		my $err = &create_disk_image_partition($vhost, $disk->{'real'},
						       1, $disk->{'size'}, 1, 0,
						       $ptype);
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

# Create the drive object using KVM's fields
my @drives = split(/\s+/, $server->{'kvm_drives'});
my %drive = ( 'file' => $disk->{'real'},
	      'media' => $disk->{'media'} || 'disk' );
if ($disk->{'cache'}) {
	$drive{'cache'} = $disk->{'cache'};
	}
if ($disk->{'media'} eq 'cdrom') {
	# CDs must be on IDE
	$drive{'if'} = 'ide';
	$disk->{'virt'} =~ s/\/(s|v)d([a-z]+)$/\/hd$2/;
	}
elsif ($disk->{'virt'} =~ /sd[a-z]+$/) {
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
if ($disk->{'mount'} && $disk->{'fs'} eq 'swap') {
	# Turn off caching for swapfiles
	$drive{'cache'} = 'off';
	}

if (!$noconfig) {
	# Add the disk to the KVM config
	push(@drives, join(",", map { $_."=".$drive{$_} } keys %drive));
	$server->{'kvm_drives'} = join(" ", @drives);
	}
if (!$server->{'kvm_filesystem'} && $drive{'media'} eq 'disk') {
	# This is the new root disk
	&set_server_disk_fields($server, $disk, 'filesystem');
	}
if (!$server->{'kvm_swapfile'} && $drive{'media'} eq 'disk' &&
    $disk->{'mount'} && $disk->{'fs'} eq 'swap') {
	# This is the new swap disk
	&set_server_disk_fields($server, $disk, 'swapfile');
	}
if (!$noconfig) {
	&save_managed_server($server);
	&type_kvm_set_atboot($server, 2);
	}

# Add block device on server now
my $attacherr;
if ($server->{'status'} ne 'down' && $server->{'kvm_monitor_port'} &&
    $drive{'if'} ne 'ide') {
	# Force load of PCI hot-add modules
	&load_kvm_hotplug_modules($server);

	# Connect to KVM monitor
	delete($drive{'index'});
	my $str = join(",", map { $_."=".$drive{$_} } keys %drive);
	my ($aok, $aout) = &run_kvm_monitor_command($server,
		[ "pci_add 0 storage $str" ]);
	if (!$aok || $aout !~ /OK/) {
		# Try again with auto, as this is needed by some KVM instances
		($aok, $aout) = &run_kvm_monitor_command($server,
			[ "pci_add auto storage $str" ]);
		}
	if (!$aok && $aout =~ /unknown\s+command/) {
		# Try again with new drive_add command
		($aok, $aout) = &run_kvm_monitor_command($server,
			[ "drive_add 0 $str" ]);
		}
	$attacherr = !$aok ? $aout :
		      $aout =~ /OK/ ? undef : $aout;
	$disk->{'reboot'} = 1 if ($attacherr);
	}

# Add to total disk size
if (!$noconfig && $server->{'kvm_disktotal'} ne '' &&
    (!$disk->{'device'} || $disk->{'lv'})) {
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
	if ($disk->{'fs'} ne 'swap') {
		return "Failed to mount filesystem : $err" if ($err);
		$err = &make_dir_on_server($server, $disk->{'mount'}, 0755, 1);
		}
	return "Failed to create mount point : $err" if ($err);
	my $fstab = &get_system_fstab($server);
	$fserr = "Failed to read fstab file : $fstab" if (!ref($fstab));
	if (!$fserr) {
		my $fs = $disk->{'fs'} ? $disk->{'fs'} :
			  $disk->{'media'} eq 'cdrom' ? 'iso9660' : 'ext3';
		my $opts = &freebsd_server_type($server) ? "rw" : "defaults";
		push(@$fstab, [ $disk->{'virt_mount'}, $disk->{'mount'},
				$fs, $opts, 0, 0 ]);
		my $err = &put_system_fstab($server, $fstab);
		$fserr = "Failed to update fstab file : $err" if ($err);
		}
	&umount_filesystem_if_needed($server);
	}

# Actually mount if possible
if ($disk->{'mount'} && &can_ssh_status($server) && !$attacherr) {
	my $cmd;
	my $virt = $disk->{'virt_mount'} || $disk->{'virt'};
	if ($disk->{'fs'} eq 'swap') {
		$cmd = "swapon ".quotemeta($virt);
		}
	else {
		$cmd = "mount ".quotemeta($virt)." ".
			 	quotemeta($disk->{'mount'});
		}
	my ($out, $ex, $err) = &execute_command_on_server($server, $cmd);
	if ($ex || $err) {
		return "Failed to mount $virt on $disk->{'mount'} : ".
		       ($err || $out);
		}
	}

return $fserr;
}

# type_kvm_delete_disk(&server, &disk, [detach-only], [leave-fstab],
# 		       [don't-update-config])
# Removes a disk from the KVM configuration, the system's fstab file, and
# deletes the underlying config file. The disk object must come from a call
# to type_kvm_list_disks with the mount flag set to 1.
sub type_kvm_delete_disk
{
my ($server, $disk, $detach, $nofstab, $noconfig) = @_;
&temp_umount_filesystem_if_needed($server);
my $vhost = &type_kvm_parent($server);

# Actually un-mount if mounted
if (&can_ssh_status($server) && $disk->{'mounted'}) {
	my ($out, $ex, $err) = &execute_command_on_server($server,
		$disk->{'fs'} eq 'swap' ?
			"swapoff ".$disk->{'mounted'} :
			"umount ".$disk->{'mounted'});
	if ($err || $ex) {
		return "Failed to un-mount $disk->{'virt_mount'} : ".
		       ($err || $out);
		}
	}

# Disconnect PCI device, if not IDE
if ($server->{'status'} ne 'down' &&
    $server->{'kvm_monitor_port'} &&
    $disk->{'virt'} !~ /\/hd/) {
	my $pcis = &list_kvm_pci_devices($server);
	if (ref($pcis)) {
		my @stors = grep { $_->{'type'} =~
				   /storage|SCSI\s+controller/i } @$pcis;
		my $stor = $stors[$disk->{'drive_index'}];
		if ($stor) {
			&load_kvm_hotplug_modules($server);
			my ($ok, $out) = &run_kvm_monitor_command($server,
				[ "pci_del $stor->{'bus'} $stor->{'device'}" ]);
			if (!$ok || $out =~ /extraneous|empty/) {
				# Try alternate pci_del command format
				($ok, $out) = &run_kvm_monitor_command($server,
					[ "pci_del $stor->{'bus'}:$stor->{'device'}" ]);
				}
			if (!$ok && $out =~ /unknown\s+command/ &&
			    $stor->{'id'}) {
				# Try with new device_del command
				($ok, $out) = &run_kvm_monitor_command($server,
					[ "device_del $stor->{'id'}" ]);
				}
			if (!$ok || $out =~ /empty/) {
				$disk->{'reboot'} = 1;
				}
			}
		}
	}

# If on LVM and the VM is still connected to the LV, fail now to prevent
# leftover LVs
if ($disk->{'lv'} && !$detach && $server->{'status'} ne 'down') {
	my ($out, $ex, $err) = &execute_command_on_server(
		$vhost, "fuser ".quotemeta($disk->{'real'})." 2>&1");
	if (!$ex && !$err) {
		$out =~ s/^\S+:\s*//;
		my @pids = grep { /^\d+$/ } split(/\s+/, $out);
		@pids && return "Logical volume cannot be removed while the ".
				"disk is still in use by the running KVM ".
				"virtual system";
		}
	}

# Remove from the KVM config
if (!$noconfig) {
	my @drives = split(/\s+/, $server->{'kvm_drives'});
	splice(@drives, $disk->{'drive_index'}, 1);
	$server->{'kvm_drives'} = join(" ", @drives);

	# Main drive has been removed, so remove reference to it in config
	if ($server->{'kvm_filesystem'} eq $disk->{'real'}) {
		delete($server->{'kvm_filesystem'});
		}
	if ($server->{'kvm_swapfile'} eq $disk->{'real'}) {
		delete($server->{'kvm_swapfile'});
		}

	&save_managed_server($server);
	&type_kvm_set_atboot($server, 2);

	# Remove from total disk size
	if ($server->{'kvm_disktotal'} ne '' &&
	    (!$disk->{'device'} || $disk->{'lv'})) {
		$server->{'kvm_disktotal'} -= $disk->{'size'};
		}
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
		&delete_mapper_entries($vhost, $disk->{'vg'}, $disk->{'lv'});

		# Delete the logical volume
		&remote_foreign_require($vhost, "lvm", "lvm-lib.pl");
		my $err = &remote_foreign_call($vhost, "lvm",
				"delete_logical_volume",
				{ 'device' => $disk->{'real'} });
		$err ||= $last_remote_error;
		return $err if ($err);

		# Invalidate LV cache for host
		delete($main::list_logical_cache{$vhost->{'id'}});
		}
	elsif ($disk->{'iscsi_server'} ne '') {
		# Delete from iSCSI server
		my $err = &delete_iscsi_disk($server, $disk);
		return $err if ($err);
		}
	if ($disk->{'lv'} && $disk->{'lv_snap_of'}) {
		# LV is a snapshot .. does any existing system use it?
		my $srcreal = &find_snapshot_source_logical_volume(
				$server, $disk->{'vg'}, $disk->{'lv_snap_of'});
		if ($srcreal) {
			# Source of snapshot is un-used, likely because it was
			# deleted before this clone. Delete the LV.
			&delete_all_disk_image_partitions($vhost, $srcreal);
			&delete_mapper_entries($vhost, $disk->{'vg'},
						$disk->{'lv_snap_of'});
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
&temp_umount_filesystem_if_needed($server);
my $vhost = &type_kvm_parent($server);
my $moderr;
my $parts = &list_disk_image_partitions($vhost, $disk->{'real'});
my $part = ref($parts) ? $parts->[@$parts - 1] : undef;

# Connect iSCSI now if requested
if ($disk->{'iscsi_ip'} && $disk->{'iscsi_connect'} &&
    !$olddisk->{'iscsi_connect'}) {
	my $err = &connect_iscsi_disk($server, $disk);
	return $err if ($err);
	}

# Work out if we can resize the filesystem
my $resizefs;
if ($disk->{'size'} != $olddisk->{'size'}) {
	if ($disk->{'fs'} =~ /^ext\d+$/ || $disk->{'fs'} eq 'swap' ||
            $disk->{'fs'} eq 'ufs' || $disk->{'fs'} eq 'xfs') {
		$part || return "No partitions were found on the disk image!";
		$disk->{'virt_part'} == scalar(@$parts) ||
			return "Only the last partition on a disk image can ".
			       "be resized";
		$resizefs = 1;
		}
	}

# Make sure new disk file exists
if ($disk->{'real'} ne $olddisk->{'real'}) {
	my @st = &stat_file_on_server($vhost, $disk->{'real'});
	@st || return "Device $disk->{'real'} does not exist ".
		      "on $vhost->{'host'}";
	}

# If the system is up, un-mount the disk
my $mounted = 0;
if (&can_ssh_status($server) && $olddisk->{'mounted'}) {
	$olddisk->{'virt_mount'} eq '/' &&
		return "The root disk of a running system cannot be resized";
	my ($out, $ex, $err) = &execute_command_on_server($server,
		$olddisk->{'fs'} eq 'swap' ?
			"swapoff ".$olddisk->{'virt_mount'} :
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

	if ($disk->{'iscsi_server'} ne '') {
		# On iSCSI, so if growing the disk it needs to be expanded
		# on the the remote server now
		if ($disk->{'size'} > $olddisk->{'size'}) {
			push(@cmds, sub {
				&modify_iscsi_disk($server, $disk, $olddisk);
				});
			}
		}
	elsif ($disk->{'lv'} && $disk->{'size'} > $olddisk->{'size'}) {
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
		if ($disk->{'fs'} eq 'swap') {
			push(@cmds, "mkswap $loop");
			}
		else {
			push(@cmds, &get_fsck_command($vhost, $disk->{'fs'},
						      $loop));
			push(@cmds, &get_resize_command($vhost, $disk->{'fs'},
							$loop, $newmbs));
			}
		push(@cmds, "losetup -d $loop");
		}

	# Delete the last partition, then re-create it (with a fall back to
	# the original size if re-creation fails)
	my $need_part_resize = 0;
	if ($part && $server->{'type'} ne 'windows' && $part->{'type'} ne '7') {
		push(@cmds, "parted -s ".quotemeta($disk->{'real'})." rm ".
			    $part->{'part'});
		if (@$parts == 1 && $part->{'disklabel'} eq 'gpt' &&
		    $disk->{'size'} > $olddisk->{'size'}) {
			# Re-create the GPT disk label, so it is the right size
			push(@cmds, "parted -s ".quotemeta($disk->{'real'}).
				    " mklabel gpt");
			}
		push(@cmds, "(echo print ; echo Fix ; echo quit) | ".
			    "parted ---pretend-input-tty ".
			    quotemeta($disk->{'real'})." ; ".
			    "/bin/true");
		push(@cmds, [ "parted -s ".quotemeta($disk->{'real'}).
			        " mkpart ".
			        $part->{'parted_type'}." ".
			        $part->{'parted_start'}." ".
			        int($disk->{'size'}/1000000)."MB",
			      "parted -s ".quotemeta($disk->{'real'}).
				" mkpart ".
                                $part->{'parted_type'}." ".
                                $part->{'parted_start'}." ".
                                $part->{'parted_end'} ]);
		$need_part_resize = 1;
		}

	if ($disk->{'size'} > $olddisk->{'size'} && $resizefs) {
		# Expand the filesystem
		push(@cmds, "losetup -o $part->{'offset'} $loop ".
			    quotemeta($disk->{'real'}));
		if ($disk->{'fs'} eq 'swap') {
			push(@cmds, "mkswap $loop");
			}
		else {
			push(@cmds, &get_fsck_command($vhost, $disk->{'fs'},
						      $loop));
			push(@cmds, &get_resize_command($vhost, $disk->{'fs'},
							$loop, $newmbs));
			push(@cmds, &get_fsck_command($vhost, $disk->{'fs'},
						      $loop));
			}
		push(@cmds, "losetup -d $loop");
		}

	if ($disk->{'iscsi_server'} ne '') {
		# Shrink on the iSCSI server after resizing the partition
		if ($disk->{'size'} < $olddisk->{'size'}) {
			push(@cmds, sub {
				&modify_iscsi_disk($server, $disk, $olddisk);
				});
			}
		}
	elsif (!$disk->{'lv'} && $disk->{'size'} < $olddisk->{'size'}) {
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

	# For GPT format disks, the disk label has to be re-generated
	# AFTER shrinking so that it matches the new device size
	if ($need_part_resize && $part->{'disklabel'} eq 'gpt' &&
	    $disk->{'size'} < $olddisk->{'size'} && @$parts == 1) {
		push(@cmds, "parted -s ".quotemeta($disk->{'real'}).
			    " mklabel gpt");
		push(@cmds, "parted -s ".quotemeta($disk->{'real'}).
			    " mkpart ".
			    $part->{'parted_type'}." ".
			    $part->{'parted_start'}." ".
			    int($disk->{'size'}/1000000)."M");
		}

	# Run them in turn
	foreach my $cmd (@cmds) {
		my ($out, $ex, $err);
		if (ref($cmd) eq 'CODE') {
			# Call a function (used for iSCSI resizes)
			$err = &$cmd;
			}
		elsif (ref($cmd) eq 'ARRAY') {
			# Run a primary and recovery command
			($out, $ex, $err) = &execute_command_on_server(
				$vhost, $cmd->[0]);
			if ($ex) {
				# Failed, try to back out
				&execute_command_on_server($vhost, $cmd->[1]);
				}
			}
		else {
			# Run a command
			($out, $ex, $err) = &execute_command_on_server(
				$vhost, $cmd);
			if ($cmd =~ /fsck/ && ($ex == 1 || $ex == 256)) {
				# Safe to ignore filesystem fixes
				$ex = 0;
				}
			}
		if ($err) {
			$moderr = $err;
			last;
			}
		elsif ($ex) {
			my $cmdstr = ref($cmd) eq 'ARRAY' ? $cmd->[0] : $cmd;
			$moderr = "$cmdstr failed : $out";
			last;
			}
		}

	# Always remove loopback
	&execute_command_on_server($vhost, "losetup -d $loop");

	# Update total disk size
	if (!$moderr &&
	    $server->{'kvm_disktotal'} ne '' &&
	    (!$disk->{'device'} || $disk->{'lv'})) {
		$server->{'kvm_disktotal'} -= $olddisk->{'size'};
		$server->{'kvm_disktotal'} += $disk->{'size'};
		}

	# Invalidate LV cache for host, due to size change
	delete($main::list_logical_cache{$vhost->{'id'}});
	}

# If this was the primary disk, update disk details in the VM
if ($olddisk->{'real'} eq $server->{'kvm_filesystem'}) {
	&set_server_disk_fields($server, $disk, 'filesystem');
	}
if ($olddisk->{'real'} eq $server->{'kvm_swapfile'}) {
	&set_server_disk_fields($server, $disk, 'swapfile');
	}

if ($disk->{'virt'} ne $olddisk->{'virt'} ||
    $disk->{'media'} ne $olddisk->{'media'} ||
    $disk->{'cache'} ne $olddisk->{'cache'} ||
    $disk->{'real'} ne $olddisk->{'real'}) {
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
	if ($disk->{'cache'}) {
		$drive{'cache'} = $disk->{'cache'};
		}
	else {
		delete($drive{'cache'});
		}
	if ($disk->{'real'}) {
		$drive{'file'} = $disk->{'real'};
		}
	$drives[$disk->{'drive_index'}] =
		join(",", map { $_."=".$drive{$_} } keys %drive);
	$server->{'kvm_drives'} = join(" ", @drives);
	&save_managed_server($server);
	&type_kvm_set_atboot($server, 2);

	# Caching mode cannot be changed live
	my $caches = &type_kvm_list_disk_caches($server);
	my ($ojb) = grep { $_->{'id'} eq $disk->{'cache'} ||
                           $_->{'alt'} eq $disk->{'cache'} } @$caches;
	my ($oldojb) = grep { $_->{'id'} eq $olddisk->{'cache'} ||
                              $_->{'alt'} eq $olddisk->{'cache'} } @$caches;
	if ($obj && $oldobj && $obj->{'id'} ne $oldobj->{'id'}) {
		$disk->{'reboot'} = 1;
		}

	# Update fstab, if in there
	if ($server->{'status'} ne 'alive' &&
	    $disk->{'virt'} ne $olddisk->{'virt'}) {
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

# If real device changed and VM is up and it was a CD, try to change it
if ($disk->{'real'} ne $olddisk->{'real'} &&
    $server->{'status'} ne 'down' &&
    $disk->{'media'} eq 'cdrom' &&
    $server->{'kvm_monitor_port'}) {
	# Find the block device for this CD
	my ($ok, $out) = &run_kvm_monitor_command($server,
						  [ "info block" ]);
	my $block;
	if ($ok) {
		foreach my $l (split(/\r?\n/, $out)) {
			if ($l =~ /^(\S+):.*file=(\S+)/ &&
			    $2 eq $olddisk->{'real'}) {
				$block = $1;
				}
			}
		}

	# Change it live
	if ($block) {
		my ($ok, $out) = &run_kvm_monitor_command($server,
			[ "change $block $disk->{'real'}" ]);
		$disk->{'reboot'} = $ok ? 0 : 1;
		}
	else {
		# Cannot find block device to change live
		$disk->{'reboot'} = 1;
		}
	}

# If it was mounted before, mount it now
if ($mounted && $disk->{'mount'}) {
	my ($out, $ex, $err) = &execute_command_on_server($server,
		$disk->{'fs'} eq 'swap' ?
			"swapon ".$disk->{'virt_mount'} :
			"mount ".$disk->{'virt_mount'}." ".$disk->{'mount'});
	if ($err || $ex) {
		return "Failed to mount $disk->{'virt'} : ".($err || $out);
		}
	}

# Disconnect iSCSI now if requested
if ($disk->{'iscsi_ip'} && !$disk->{'iscsi_connect'} &&
    $olddisk->{'iscsi_connect'}) {
	my $err = &disconnect_iscsi_disk($server, $disk);
	return $err if ($err);
	}

return $moderr;
}

# type_kvm_list_disk_filesystems(&server)
# Returns supported filesystem types. Assumes Linux.
sub type_kvm_list_disk_filesystems
{
return ('ext3', 'ext4', 'ext2', 'reiserfs', 'swap', 'ufs', 'xfs');
}

# type_kvm_list_storages(&vhost, [always-show-hosts])
# Returns a list of possible storage locations on some host system. Each is a
# hash ref with a id and desc fields. Example storages include local files and
# LVM volume groups.
sub type_kvm_list_storages
{
my ($vhost, $always) = @_;
my @rv;

# Regular files
push(@rv, { 'id' => 'files',
	    'type' => 'files',
	    'desc' => $text{'storage_files'},
	    'adddesc' => $text{'storage_addfiles'} });

# Add iSCSI servers
my @iscsis = &list_iscsi_target_servers();
my $showi = $always || @iscsis > 1;
foreach my $iscsi (@iscsis) {
	push(@rv, {
	    'id' => 'iscsi_'.$iscsi->{'host'},
	    'type' => 'iscsi',
	    'iscsi' => $iscsi->{'id'},
	    'desc' => $showi ? &text('storage_iscsi', $iscsi->{'host'})
			     : $text{'storage_iscsi1'},
	    'adddesc' => $showi ? &text('storage_addiscsi', $iscsi->{'host'})
				: $text{'storage_addiscsi1'} });
	}

if ($vhost->{'status'} eq 'virt' || $vhost->{'status'} eq 'novirt') {
	# Check for and add LVM volume groups
	my $info = &get_server_collected($vhost);
	my @vgs = grep { $_->{'vg'} ne 'gpt_vg' } @{$info->{'vg_list'}};
	my $showv = $always || @vgs > 1;
	foreach my $vg (@vgs) {
		push(@rv, {
		    'id' => 'lvm_'.$vg->{'vg'},
		    'type' => 'lvm',
		    'vg' => $vg->{'vg'},
		    'desc' => $showv ? &text('storage_lvm', $vg->{'vg'})
				     : $text{'storage_lvm1'},
		    'adddesc' => $showv ? &text('storage_addlvm', $vg->{'vg'})
					: $text{'storage_addlvm1'} });
		}

	# Also add thin pool LVs
	my @lvs = @{$info->{'lv_thin_list'}};
	my $showv = $always || @lvs > 1;
	foreach my $lv (@lvs) {
		push(@rv, {
		    'id' => 'thin_'.$lv->{'vg'}.'_'.$lv->{'lv'},
		    'type' => 'thin',
		    'vg' => $lv->{'vg'},
		    'lv' => $lv->{'lv'},
		    'desc' => $showv ? &text('storage_thin', $lv->{'lv'})
				     : $text{'storage_thin1'},
		    'adddesc' => $showv ? &text('storage_addthin',$lv->{'lv'})
					: $text{'storage_addthin'} });
		}
	}

# Work out the default storage
my $def;
if ($vhost->{'kvm_vg'}) {
	($def) = grep { $_->{'vg'} eq $vhost->{'kvm_vg'} } @rv;
	}
elsif ($vhost->{'kvm_iscsi'} ne '') {
	($def) = grep { $_->{'iscsi'} eq $vhost->{'kvm_iscsi'} } @rv;
	}
else {
	$def = $rv[0];
	}
$def || return "No default storage found for $vhost->{'host'}";
$def->{'default'} = 1;

return \@rv;
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
my ($ok, $loop) = &loopback_mount_partition($vhost, $disk->{'real'});
$ok || return (0, $loop);
my ($out, $ex, $err) = &execute_command_on_server($vhost,
	"fsck -y $flag $loop");
&loopback_unmount_partition($vhost, $loop);
if ($ex && $out =~ /fsck\S+:\s+not\s+found/) {
	# Filesystem not supported, so assume OK
	return (1, $out);
	}
elsif ($ex > 2 || $err) {
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

# type_kvm_list_disk_caches(&server)
# Returns the list of possible disk caching types for some system. Each is a
# has ref with id and desc fields
sub type_kvm_list_disk_caches
{
my ($server) = @_;
my $vhost = &get_parent_server($server);
if (&compare_versions(&kvm_host_version($vhost), "0.12") > 0) {
	return [ { 'id' => 'none',
		   'alt' => 'off',
		   'desc' => 'Disabled (Only uses host disk)', },
		 { 'id' => 'writeback',
		   'desc' => 'Writeback (Reads and writes to host cache)' },
		 { 'id' => 'writethrough',
		   'alt' => 'on',
		   'desc' => 'Writethrough (Reads from host cache)',
		   'default' => 1, },
		 { 'id' => 'unsafe',
		   'desc' => 'Unsafe' },
		];
	}
else {
	return [ { 'id' => 'on',
		   'default' => 1,
		   'desc' => 'Enabled (Reads from host cache)' },
		 { 'id' => 'off',
		   'desc' => 'Disabled (Only uses host disk)' } ];
	}
}

# type_kvm_can_cpu(&server)
# Checks if the host of some KVM system supports cgroups. If so, returns 5
# meaning it can be changed without a reboot.
sub type_kvm_can_cpu
{
my ($server) = @_;
my $vhost = &get_parent_server($server);
return $vhost->{'kvm_cgroup_support'} ? 5 : 0;
}

# type_kvm_get_cpu(&server)
# Returns the percentage of a CPU granted to this server, or 0 for unlimited
sub type_kvm_get_cpu
{
my ($server) = @_;
my $vhost = &type_kvm_parent($server);
if (!$vhost->{'kvm_cgroup_support'}) {
	return ( );
	}
if ($server->{'status'} ne 'down' && $server->{'status'} ne 'nohost') {
	# Get actual live value
	my ($out, $ex, $err) = &execute_command_on_server(
		$vhost, "cat $vhost->{'kvm_cgroup_dir'}/cpu/$server->{'id'}/cpu.shares");
	if (!$ex && !$err && $out =~ /^(\d+)/) {
		return ( $1 == 1024 ? 0 : int($1 * 100 / 1024) );
		}
	}
# Use cached value
return ( $server->{'kvm_cpu'} || 0 );
}

# type_kvm_save_cpu(&server, cpu)
# Updates the CPU limit in the local config file, and applies it
sub type_kvm_save_cpu
{
my ($server, $cpu) = @_;
if ($server->{'status'} ne 'down' && $server->{'status'} ne 'nohost') {
	# Update live value, creating group if needed
	my $vhost = &type_kvm_parent($server);
	&execute_command_on_server($vhost,
		"cgcreate -g cpu:$server->{'id'}");
	&execute_command_on_server($vhost,
		"cgclassify -g cpu:$server->{'id'} $server->{'kvm'}");
	my $n = $cpu == 0 ? 1024 : int($cpu * 1024 / 100);
	my ($out, $ex, $err) = &execute_command_on_server(
		$vhost, "echo $n >$vhost->{'kvm_cgroup_dir'}/cpu/$server->{'id'}/cpu.shares");
	return $err if ($err);
	return $out if ($ex);
	}
# Update boot-time config
$server->{'kvm_cpu'} = $cpu;
&type_kvm_set_atboot($server, 2);
return undef;
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

sub type_kvm_shared_memory
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
# Returns the number of virtual CPUs and the number of cores
sub type_kvm_get_smp
{
my ($server) = @_;
return ($server->{'kvm_smp'} || 1,
	$server->{'kvm_smp_cores'} || 1);
}

# type_kvm_save_smp(&server, cpus, cores)
# Sets the number of virtual CPUs and cores
sub type_kvm_save_smp
{
my ($server, $smp, $cores) = @_;
$smp > 0 || return "KVM virtual CPUs must be at least 1";
$smp < 256 || return "KVM virtual CPUs must be less than 256";
$cores > 0 || return "KVM virtual cores must be at least 1";
$cores <= $smp || return "KVM virtual cores cannot be greater than the number ".
			 "of CPUs";
$smp % $cores == 0 || return "Number of KVM CPUs must be a multiple of the ".
			     "number of KVM cores";
$server->{'kvm_smp'} = $smp;
$server->{'kvm_smp_cores'} = $cores;
&type_kvm_set_atboot($server, 2) if ($server->{'status'} ne 'create');
return undef;
}

# type_kvm_get_cpu_count(&server)
# Returns the number of virtual CPUs, cached
sub type_kvm_get_cpu_count
{
my ($server) = @_;
return $server->{'kvm_smp'} || 1;
}

# type_kvm_can_ioclass(&server)
# Returns 1, as the IO class can be set for KVM instances without a reboot
sub type_kvm_can_ioclass
{
return 1;
}

# type_kvm_get_ioclass(&server)
# Returns the IO class of a running KVM instance, or -1 if not set
sub type_kvm_get_ioclass
{
my ($server) = @_;
if ($server->{'status'} ne 'down' && $server->{'status'} ne 'nohost') {
	# Get live value of process
	my $vhost = &type_kvm_parent($server);
	my ($out, $ex, $err) = &execute_command_on_server(
		$vhost, "ionice -p$server->{'kvm'}");
	if (!$ex && !$err && $out =~ /\S+:\s+\S+\s+(\d+)/) {
		return $1;
		}
	}
# Use cached value
return ( $server->{'kvm_ioclass'} || 0 );
}

# type_kvm_save_ioclass(&server, class)
# Sets the IO class (a number from 0 to 7) of a KVM instance
sub type_kvm_save_ioclass
{
my ($server, $ioclass) = @_;
if ($server->{'status'} ne 'down') {
	# Update live value
	my $vhost = &type_kvm_parent($server);
	my ($out, $ex, $err) = &execute_command_on_server(
		$vhost, "ionice -n$ioclass -p$server->{'kvm'}");
	return $err if ($err);
	return $out if ($ex);
	}
# Update boot-time config
$server->{'kvm_ioclass'} = $ioclass;
&type_kvm_set_atboot($server, 2);
return undef;
}

# type_kvm_real_interfaces(&server, &vhost)
# Returns a list of interfaces on the KVM host system associated with some
# virtual system. Each is a hash ref with keys name, bytes_in, bytes_out,
# packets_in, packets_out
sub type_kvm_real_interfaces
{
my ($server, $vhost) = @_;

# Get network stats on the host, with caching
my ($out, $ex, $err);
$out = $proc_net_dev_cache{$vhost->{'id'}};
if (!$out) {
	($out, $ex, $err) = &execute_command_on_server($vhost,
				"cat /proc/net/dev");
	return $out if ($ex);
	return $err if ($err);
	$proc_net_dev_cache{$vhost->{'id'}} = $out;
	}

# Find the tap interfaces used by this KVM instance
my %taps;
my @nets = split(/\s+/, $server->{'kvm_net'});
foreach my $net (@nets) {
	if ($net =~ /script=([^,]+-(eth\d+))\.sh/) {
		my $scriptbase = $1;
		my $eth = $2;
		my $tapfile = $scriptbase.".tap";
		my $tap = &get_file_data_from_server($vhost, $tapfile);
		$tap =~ s/\r|\n//g;
		$taps{$tap} = $eth;
		}
	}

# Extract stats for this host
my @rv;
my %bwifaces = map { $_, 1 } split(/\s+/, $server->{'bw_ifaces'});
foreach my $dev (split(/\r?\n/, $out)) {
	$dev =~ s/^\s+//;
	my @w = split(/[ \t:]+/, $dev);
	my $eth = $taps{$w[0]};
	if ($eth && (!%bwifaces || $bwifaces{$eth})) {
		# Directions are reversed, as we are looking at a virtual
		# interface that talks *to* the host
		my $iface = { 'name' => $w[0],
			      'bytes_in' => $w[9],
			      'packets_in' => $w[10],
			      'bytes_out' => $w[1],
			      'packets_out' => $w[2] };
		push(@rv, $iface);
		}
	}
return \@rv;
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
       (&redhat_server_type($server) || &debian_server_type($server) ||
	&freebsd_server_type($server))) {
	# Can manage via direct file manipulation
	return 2;
	}
elsif ($server->{'status'} ne 'nohost') {
	# Can manage, but only create or delete and not set IPs
	return 3;
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
       &redhat_server_type($server) || &debian_server_type($server) ||
       &freebsd_server_type($server);
}

# type_kvm_can_ipv6(&server)
# Returns 1 if IPv6 addresses can be managed on a system
sub type_kvm_can_ipv6
{
return 1;
}

# type_kvm_list_interfaces(&server, [force-from-cfg])
# Returns a list of network interfaces on the system, or an error message
sub type_kvm_list_interfaces
{
my ($server, $fromcfg) = @_;
my $rv;
my $can = &type_kvm_can_interfaces($server);
my @net = split(/\s+/, $server->{'kvm_net'});
my @macs = split(/\s+/, $server->{'mac'});
my @bridges = split(/\s+/, $server->{'kvm_hostifaces'});
my @models = split(/\s+/, $server->{'kvm_model'});
my $eth = &get_interface_prefix($server);

if ($can == 3 || $fromcfg) {
	# Cannot manage IPs, like on a Windows VM
	$rv = [ map { my $deveth = &get_interface_prefix($server, $models[$_]);
		      { 'name' => $deveth.$_,
		        'fullname' => $deveth.$_,
			'unknown' => 1,
		        'up' => 1 } } (0 .. scalar(@net)-1) ];
	if ($server->{'status'} ne 'down') {
		# Set active field
		foreach my $iface (@$rv) {
			if ($iface->{'name'} =~ /^[a-z]0$/) {
				# We know the IP, so ping it
				$iface->{'active'} =
					$server->{'status'} eq 'noping' ? 0 : 1;
				}
			else {
				# Assume OK
				$iface->{'active'} = 1;
				}
			}
		}
	}
elsif ($server->{'status'} eq 'down') {
	# Get from network config files
	my $err = &mount_filesystem_if_needed($server);
	return "Failed to mount filesystem : $err" if ($err);
	$rv = &list_boot_server_interfaces($server);
	&umount_filesystem_if_needed($server);

	# Add interfaces that KVM has been configured with, but aren't active
	# on the VM
	for(my $i=0; $i<@net; $i++) {
		my $name = $eth.$i;
		my ($already) = grep { $_->{'fullname'} eq $name } @$rv;
		if (!$already) {
			my $deveth = &get_interface_prefix($server, $models[$i]);
			push(@$rv, { 'name' => $deveth.$i,
				     'fullname' => $deveth.$i,
				     'unknown' => 1,
				     'up' => 1 });
			}
		}
	}
else {
	# Get active and boot interfaces
	$rv = &list_active_server_interfaces($server);
	$bootrv = &list_boot_server_interfaces($server);
	if (ref($rv)) {
		foreach my $iface (@$rv) {
			$iface->{'active'} = 1;
			}
		}
	if (ref($rv) && ref($bootrv)) {
		# Add boot-time interfaces that aren't active yet
		my %got = map { $_->{'fullname'}, $_ } @$rv;
		push(@$rv, grep { !$got{$_->{'fullname'}} &&
				  (&check_ipaddress($_->{'address'}) ||
				   $_->{'address'} eq '') }
				@$bootrv);
		}
	}

# Set nodelete flag on first real interface, filter out interfaces
# with no IP or non-ethernet
# XXX deal with mixed interface types better
if (ref($rv)) {
	# Get all possible prefixes from network interface models, or use the
	# default prefix if no models set yet
	my @prefixes = map { &get_interface_prefix($server, $_) }
			   (@models ? @models : (""));
	$rv = [ grep { $_->{'fullname'} =~ /^([a-z]+)/ &&
		       &indexof($1, @prefixes) >= 0 &&
		       $_->{'up'} } @$rv ];
	foreach my $iface (@$rv) {
		$iface->{'active'} ||= 0;
		if ($iface->{'fullname'} =~ /^[a-z]0$/) {
			$iface->{'nodelete'} = 1
			}
		$iface->{'noedit'} = 1 if (!$iface->{'address'} &&
					   !$iface->{'unknown'});
		}
	}

# Set MAC, bridges and model field on real interfaces
for(my $i=0; $i<@macs; $i++) {
	my $mac = $macs[$i];
	my $b = $bridges[$i];
	my $m = $models[$i];
	my $deveth = &get_interface_prefix($server, $m);
	my ($iface) = grep { $_->{'fullname'} eq $deveth.$i } @$rv;
	if ($iface) {
		$iface->{'ether'} = $mac eq '*' || $mac eq '' ? undef : $mac;
		$iface->{'bridge'} = $b eq '*' || $b eq '' ? undef : $b;
		$iface->{'model'} = $m eq '*' || $m eq '' ? undef : $m;
		}
	}

# If VM is running, get tap interfaces
if ($server->{'status'} ne 'down' && $server->{'status'} ne 'nohost') {
	my $vhost = &type_kvm_parent($server);
	foreach my $net (@net) {
		if ($net =~ /script=([^,]+-(eth\d+))\.sh/) {
			my $scriptbase = $1;
			my $tapeth = $2;
			my $tapfile = $scriptbase.".tap";
			my $tap = &get_file_data_from_server($vhost, $tapfile);
			$tap =~ s/\r|\n//g;
			my ($iface) = grep { $_->{'fullname'} eq $tapeth } @$rv;
			if ($iface) {
				$iface->{'tap'} = $tap;
				}
			}
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

# type_kvm_create_interface(&server, &iface, [non-virtual])
# Add and activate a virtual interface
sub type_kvm_create_interface
{
my ($server, $iface, $nonvirt) = @_;
my $can = &type_kvm_can_interfaces($server);
my $eth = &get_interface_prefix($server, $iface);

# Find a free interface number, if needed
my $vhost = &type_kvm_parent($server);
if ($nonvirt) {
	$iface->{'name'} =~ /^$eth(\d+)$/ ||
		return "Only intefaces starting with $eth can be created";
	my @nets = split(/\s+/, $server->{'kvm_net'});
	$1 == scalar(@nets) ||
		return "A new real interface must be named $eth".scalar(@nets);
	$iface->{'fullname'} = $iface->{'name'};
	$iface->{'unknown'} = 1 if ($can == 3);
	}
else {
	my $ifaces = &type_kvm_list_interfaces($server);
	return "Failed to list interfaces : $ifaces" if (!ref($ifaces));
	my $n = 0;
	foreach my $oldiface (@$ifaces) {
		if ($oldiface->{'virtual'} ne '' &&
		    $oldiface->{'virtual'} >= $n &&
		    $oldiface->{'name'} eq $iface->{'name'}) {
			$n = $oldiface->{'virtual'} + 1;
			}
		}
	$iface->{'virtual'} = $n;
	$iface->{'fullname'} = $iface->{'name'}.":".$n;
	}

# Allocate IP, if needed
my @kvm_iface = split(/\s+/, $vhost->{'kvm_iface'});
my $idx = $iface->{'name'} =~ /^$eth(\d+)/ ? $1 : 0;
$iface->{'bridge'} ||= $kvm_iface[$idx];
if (!$iface->{'address'} && !$iface->{'unknown'}) {
	my $cidr;
	($iface->{'address'}, $cidr) = &allocate_ip_address(
	    $vhost->{'kvm_start'}, $vhost->{'kvm_end'}, $vhost->{'kvm_cidr'},
	    $vhost->{'kvm_gws'}, $vhost->{'kvm_ifaces'}, $iface->{'bridge'});
	$iface->{'address'} ||
		return &text('create_exenalloc', $vhost->{'host'},
			    &describe_ip_range($vhost->{'kvm_start'},
					       $vhost->{'kvm_end'},
					       $vhost->{'kvm_cidr'},
					       $vhost->{'kvm_ifaces'},
					       $iface->{'bridge'}));
	$iface->{'netmask'} = &net::prefix_to_mask($cidr);
	}

# Compute broadcast and network
$iface->{'up'} = 1;
if (!$iface->{'unknown'}) {
	$iface->{'broadcast'} = &net::compute_broadcast($iface->{'address'},
							$iface->{'netmask'});
	$iface->{'network'} = &net::compute_network($iface->{'address'},
						    $iface->{'netmask'});
	}

my $canactivate;
if ($nonvirt) {
	# Add to list of interfaces to activate at start time
	my @macs = split(/\s+/, $server->{'mac'});
	my @models = split(/\s+/, $server->{'kvm_model'});
	while(scalar(@models) < scalar(@macs)) {
		push(@models, "*");
		}
	my @nets = split(/\s+/, $server->{'kvm_net'});
	my @ifaces = split(/\s+/, $server->{'kvm_hostifaces'});
	my $num = scalar(@nets);
	my $mac = &generate_mac_address($server, $num);
	push(@macs, $mac);
	push(@models, $iface->{'model'} || "*");
	my $tap = "tap";
	$tap .= ",vlan=$num" if (&kvm_host_supports_vlan($vhost));
	push(@nets, $tap);
	push(@ifaces, $iface->{'bridge'} || '*');

	# Create script to attach correct bridge and record tap
	my ($data, $script) = &generate_kvm_bridge_script(
				$server, $iface, $iface->{'bridge'});
	my $err = &put_file_data_to_server($vhost, $data, $script);
	return "Failed to create script $script : $err" if ($err);
	&execute_command_on_server($vhost, "chmod +x $script");
	$nets[$#nets] .= ",script=$script";

	# Add the PCI device if possible
	my $model = $iface->{'model'} || "ne2k_pci";
	if ($server->{'status'} ne 'down' &&
	    $server->{'kvm_monitor_port'} &&
	    $model =~ /virtio|e1000|rtl8139|ne2k_pci/) {
		# Force load of PCI hot-add modules
		&load_kvm_hotplug_modules($server);

		# Connect to KVM monitor
		my $oldactive = &list_active_server_interfaces($server, 1);
		my $str = "model=$model,mac=$mac";
		$str .= ",vlan=$num" if (&kvm_host_supports_vlan($vhost));
		my ($aok, $aout) = &run_kvm_monitor_command($server,
			[ "pci_add 0 nic $str" ]);
		if (!$aok || $aout !~ /OK/) {
			# Try again with auto and without mac=, as some KVM
			# instances don't support it
			my $str2 = $str;
			$str2 =~ s/,mac=([^,]+)//;
			($aok, $aout) = &run_kvm_monitor_command($server,
				[ "pci_add auto nic $str2" ]);
			}
		if (!$aok && $aout =~ /unknown\s+command/) {
			# Try new device_add command
			my $driver = $model =~ /virtio/ ? "virtio-net-pci"
							: $model;
			$str =~ s/model=([^,]+),?//;
			($aok, $aout) = &run_kvm_monitor_command($server,
                                [ "device_add $driver,$str" ]);
			}
		if (!$aok) {
			# Certainly didn't get added
			$canactivate = 0;
			}
		elsif (ref($oldactive)) {
			# Wait for new interface to appear
			for(my $try=0; $try<5; $try++) {
				sleep(1);
				my $active = &list_active_server_interfaces(
						$server, 1);
				if (ref($active) && @$active > @$oldactive) {
					$canactivate = 1;
					last;
					}
				}
			}
		}
	$iface->{'reboot'} = !$canactivate;

	# Add to lists of interfaces on the system
	$server->{'mac'} = join(" ", @macs);
	$server->{'mac_addresses'} = join(" ", @macs);
	$server->{'kvm_model'} = join(" ", @models);
	$server->{'kvm_net'} = join(" ", @nets);
	$server->{'kvm_hostifaces'} = join(" ", @ifaces);
	&recompute_kvm_ips($server, $iface->{'address'}, undef);
	}
else {
	# Virtual interfaces can always be activated immediately
	$canactivate = 1;
	}

# Activate now if possible
if (&can_ssh_status($server) && $canactivate) {
	my $err = &create_active_server_interface($server, $iface);
	return $err if ($err);
	}

# Activate at boot
if (!$iface->{'unknown'}) {
	my $err = &mount_filesystem_if_needed($server);
	return "Failed to mount filesystem : $err" if ($err);
	$err = &create_boot_server_interface($server, $iface);
	&umount_filesystem_if_needed($server);
	return $err if ($err);
	}

if (!$iface->{'unknown'}) {
	&add_ip_address($server, $iface->{'address'});
	&add_delete_ip6_addresses($server, undef, $iface->{'address6'});
	}

# Add new IPs to firewall, and re-generate ifup scripts
if ($server->{'kvm_firewall'} && $server->{'kvm_firewall'} ne '*' &&
    !$iface->{'unknown'}) {
	my @fwips = split(/\s+/, $server->{'kvm_firewall'});
	push(@fwips, $iface->{'address'});
	push(@fwips, @{$iface->{'address6'}});
	$server->{'kvm_firewall'} = join(" ", &unique(@fwips));
	}
&type_kvm_save_firewall($server,
	[ split(/\s+/, $server->{'kvm_firewall'}) ]);

return undef;
}

# type_kvm_delete_interface(&server, &iface)
# Delete and de-activate a virtual interface
sub type_kvm_delete_interface
{
my ($server, $iface) = @_;
my $vhost = &type_kvm_parent($server);
my $kvm_dir = $server->{'directory'} || $vhost->{'kvm_dir'};
my $eth = &get_interface_prefix($server, $iface);

# Delete boot interface
if (!$iface->{'unknown'}) {
	my $err = &mount_filesystem_if_needed($server);
	return "Failed to mount filesystem : $err" if ($err);
	$err = &delete_boot_server_interface($server, $iface);
	&umount_filesystem_if_needed($server);
	return $err if ($err);
	}

# De-activate interface if possible. Ignore errors for non-virtual interfaces,
# as they generally can't be taken down without a reboot anyway
if (&can_ssh_status($server) && $iface->{'active'}) {
	my $err = &delete_active_server_interface($server, $iface);
	return $err if ($err && $iface->{'virtual'} ne '');
	}

# Remove from KVM config
my $idx = $iface->{'name'} =~ /^$eth(\d+)/ ? $1 : undef;
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
		if ($script =~ /^\Q$kvm_dir\/\E/) {
			&delete_file_on_server($vhost, $script);
			}
		}
	splice(@macs, $idx, 1);
	splice(@models, $idx, 1);
	splice(@nets, $idx, 1);
	splice(@ifaces, $idx, 1);
	$server->{'mac'} = join(" ", @macs);
	$server->{'mac_addresses'} = join(" ", @macs);
	$server->{'kvm_model'} = join(" ", @models);
	$server->{'kvm_net'} = join(" ", @nets);
	$server->{'kvm_hostifaces'} = join(" ", @ifaces);
	&recompute_kvm_ips($server, undef, $iface->{'address'});
	$iface->{'reboot'} = 1;
	}

# Remove PCI device if possible
my $model = $iface->{'model'} || "ne2k_pci";
if ($iface->{'virtual'} eq '' &&
    $server->{'status'} ne 'down' &&
    $model =~ /virtio|e1000|rtl8139|ne2k_pci/ &&
    $server->{'kvm_monitor_port'}) {
	my $pcis = &list_kvm_pci_devices($server);
	if (ref($pcis)) {
		my @eths = grep { $_->{'type'} =~ /ethernet/i } @$pcis;
		my $eth = $eths[$idx];
		if ($eth) {
			&load_kvm_hotplug_modules($server);
			my ($ok, $out) = &run_kvm_monitor_command($server,
				[ "pci_del $eth->{'bus'} $eth->{'device'}" ]);
			if (!$ok && $out =~ /unknown\s+command/ &&
			    $eth->{'id'}) {
				# Try with new device_del command
				($ok, $out) = &run_kvm_monitor_command($server,
					[ "device_del $eth->{'id'}" ]);
				}
			if ($ok) {
				$iface->{'reboot'} = 0;
				}
			}
		}
	}

if (!$iface->{'unknown'}) {
	&delete_ip_address($server, $iface->{'address'});
	&add_delete_ip6_addresses($server, $iface->{'address6'}, undef);
	}

# Remove old IPs from firewall, and re-generate ifup scripts
if ($server->{'kvm_firewall'} && $server->{'kvm_firewall'} ne '*' &&
    !$iface->{'unknown'}) {
	my @fwips = split(/\s+/, $server->{'kvm_firewall'});
	@fwips = grep { $_ ne $iface->{'address'} } @fwips;
	@fwips = grep { &indexof($_, @{$iface->{'address6'}}) < 0 } @fwips;
	$server->{'kvm_firewall'} = join(" ", &unique(@fwips));
	}
&type_kvm_save_firewall($server,
	[ split(/\s+/, $server->{'kvm_firewall'}) ]);

return undef;
}

# type_kvm_modify_interface(&server, &iface, &oldiface)
# Changes the active and boot-time IPs for an interface
sub type_kvm_modify_interface
{
my ($server, $iface, $oldiface) = @_;
my %oldserver = %$server;
my $vhost = &type_kvm_parent($server);
my $eth = &get_interface_prefix($server, $iface);
my $oldeth = &get_interface_prefix($server, $oldiface);

# Modify boot interface
if (!$iface->{'unknown'}) {
	my $err = &mount_filesystem_if_needed($server);
	return "Failed to mount filesystem : $err" if ($err);
	$err = &modify_boot_server_interface($server, $iface, $oldiface);
	&umount_filesystem_if_needed($server);
	return $err if ($err);
	}

# Change active interface if possible
if (&can_ssh_status($server) && $iface->{'active'}) {
	my $err = &modify_active_server_interface($server, $iface, $oldiface);
	return $err if ($err);
	}

if (!$iface->{'unknown'}) {
	&delete_ip_address($server, $oldiface->{'address'});
	&add_ip_address($server, $iface->{'address'});
	&add_delete_ip6_addresses($server, $oldiface->{'address6'},
					   $iface->{'address6'});
	}

# Change MAC address and model if non-virtual
if ($iface->{'virtual'} eq '') {
	my @macs = split(/\s+/, $server->{'mac'});
	my @models = split(/\s+/, $server->{'kvm_model'});
	my @ifaces = split(/\s+/, $server->{'kvm_hostifaces'});
	while(scalar(@models) < scalar(@macs)) {
		push(@models, "*");
		}
	while(scalar(@ifaces) < scalar(@macs)) {
		push(@ifaces, "*");
		}
	my $idx = $iface->{'name'} =~ /^$oldeth(\d+)/ ? $1 : 0;
	$macs[$idx] = $iface->{'ether'} || '*';
	$models[$idx] = $iface->{'model'} || '*';
	$ifaces[$idx] = $iface->{'bridge'} || '*';
	$server->{'mac'} = join(" ", @macs);
	$server->{'mac_addresses'} = join(" ", @macs);
	$server->{'kvm_model'} = join(" ", @models);
	$server->{'kvm_hostifaces'} = join(" ", @ifaces);
	&recompute_kvm_ips($server, $iface->{'address'},$oldiface->{'address'});
	&save_managed_server($server);
	&type_kvm_set_atboot($server, 2);
	}

# If bridge changed, update connection between tapN and new bridge
if ($iface->{'virtual'} eq '' && $iface->{'bridge'} ne $oldiface->{'bridge'}) {
	# If running, re-connect the tap interface to the new bridge
	my $idx = $iface->{'name'} =~ /^$eth(\d+)/ ? $1 : 0;
	my @nets = split(/\s+/, $server->{'kvm_net'});
	if ($server->{'status'} ne 'down' &&
	    $nets[$idx] =~ /script=([^,]+-(eth\d+))\.sh/) {
		my $tapfile = $1.".tap";
		my $tap = &get_file_data_from_server($vhost, $tapfile);
		$tap =~ s/\r|\n//g;
		if ($tap) {
			&execute_command_on_server($vhost,
				"brctl delif $oldiface->{'bridge'} $tap");
			&execute_command_on_server($vhost,
				"brctl addif $iface->{'bridge'} $tap");
			}
		}
	}

if ($iface->{'virtual'} eq '') {
	# Always update bridge creation script
	my ($data, $script) = &generate_kvm_bridge_script(
				$server, $iface, $iface->{'bridge'});
	my $err = &put_file_data_to_server($vhost, $data, $script);
	return "Failed to create script $script : $err" if ($err);
	}

# Remove old IPs from firewall and add new, and re-generate ifup scripts
if ($server->{'kvm_firewall'} && $server->{'kvm_firewall'} ne '*') {
	my @fwips = split(/\s+/, $server->{'kvm_firewall'});
	if (!$oldiface->{'unknown'}) {
		@fwips = grep { $_ ne $oldiface->{'address'} } @fwips;
		@fwips = grep { &indexof($_, @{$oldiface->{'address6'}}) < 0 }
			      @fwips;
		}
	if (!$iface->{'unknown'}) {
		push(@fwips, $iface->{'address'});
		push(@fwips, @{$iface->{'address6'}});
		}
	$server->{'kvm_firewall'} = join(" ", &unique(@fwips));
	}
&type_kvm_save_firewall($server,
	[ split(/\s+/, $server->{'kvm_firewall'}) ]);

return undef;
}

# recompute_kvm_ips(&server, add-ip4, delete-ip4)
# After adding, removing or editing a real interface, update the internal list
# of those that should be used at creation time
sub recompute_kvm_ips
{
my ($server, $add, $del) = @_;
my @ips = split(/\s+/, $server->{'kvm_ip'});
if ($add && !$del) {
	push(@ips, $add);
	}
elsif (!$add && $del) {
	my $idx = &indexof($del, @ips);
	splice(@ips, $idx, 1) if ($idx >= 0);
	}
elsif ($add && $del && $add ne $del) {
	my $idx = &indexof($del, @ips);
	if ($idx >= 0) {
		$ips[$idx] = $add;
		}
	else {
		# List may be out of sync
		push(@ips, $add);
		}
	}
else {
	return;	# Nothing to do
	}
$server->{'kvm_ip'} = join(" ", @ips);
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

# type_kvm_get_default_model(&server)
# Returns the preferred default model for a system
sub type_kvm_get_default_model
{
my ($server) = @_;
my @models = grep { $_ ne '*' } split(/\s+/, $server->{'kvm_model'});
return $models[0] if (@models);
return 'virtio' if ($server->{'kvm_virtio'});
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
				if (!$d->{'device'} || $d->{'lv'} ||
				    $d->{'iscsi_server'} ne '');
			}
		}
	}
$server->{'kvm_disktotal'} += &compute_snapshots_size($server);
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
# Returns the amount of disk space used on the host by this KVM instance, which
# is the same as the disk allocated
sub type_kvm_get_disk_space
{
my ($server) = @_;
return &type_kvm_get_disk_size($server);
}

# type_kvm_get_memory_size(&server)
# Returns the memory allocated to this KVM instance, from a cache
sub type_kvm_get_memory_size
{
my ($server) = @_;
return $server->{'kvm_memory'}*1024*1024;
}

# type_kvm_get_cpu_size(&server)
# Returns the cached percentage of CPU allocated to this KVM instance
sub type_kvm_get_cpu_size
{
my ($server) = @_;
return $server->{'kvm_cpu'} || 0;
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
# If the filesystem for this KVM instance is locally mounted, write the file
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

# type_kvm_rename_file(&server, oldfile, newfile)
# If the filesystem for this Xen instance is locally mounted, rename the
# file directly from there
sub type_kvm_rename_file
{
my ($server, $oldfile, $newfile) = @_;
if ($server->{'kvm_mount'}) {
	my $vhost = &type_kvm_parent($server);
	return &rename_file_on_server($vhost, $server->{'kvm_mount'}.$oldfile, $server->{'kvm_mount'}.$newfile);
	}
else {
	return 'FALLBACK';
	}
}

# type_kvm_stat_file(&server, remotefile, [lookup-usernames])
# If the filesystem for this KVM instance is locally mounted, stat the file
# directly from there
sub type_kvm_stat_file
{
my ($server, $remotefile, $usernames) = @_;
if ($server->{'kvm_mount'}) {
	my $vhost = &type_kvm_parent($server);
	return &stat_file_on_server($vhost, $server->{'kvm_mount'}.$remotefile, $usernames, $server->{'kvm_mount'});
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

# type_kvm_list_dir(&server, dir, [full-stat], [lookup-usernames])
# If the filesystem for this KVM instance is locally mounted, list the dir
# directly from there
sub type_kvm_list_dir
{
my ($server, $remotedir, $fullstat, $usernames) = @_;
if ($server->{'kvm_mount'}) {
	my $vhost = &type_kvm_parent($server);
	return &list_dir_on_server($vhost, $server->{'kvm_mount'}.$remotedir,
				   $fullstat, $usernames,
				   $server->{'kvm_mount'});
	}
else {
	return 'FALLBACK';
	}
}

# type_kvm_readlink(&server, file)
# If the filesystem for this KVM instance is locally mounted, check the link
# from there
sub type_kvm_readlink
{
my ($server, $file) = @_;
if ($server->{'kvm_mount'}) {
        my $vhost = &type_kvm_parent($server);
        return &readlink_on_server($vhost, $server->{'kvm_mount'}.$file);
        }
else {
        return 'FALLBACK';
        }
}

# type_kvm_symlink_file(&server, source, dest)
# If the filesystem for this KVM instance is locally mounted, create the
# link from there
sub type_kvm_symlink_file
{
my ($server, $src, $dest) = @_;
if ($server->{'kvm_mount'}) {
        my $vhost = &type_kvm_parent($server);
        return &symlink_file_on_server($vhost, $src,
				       $server->{'kvm_mount'}.$dest);
        }
else {
        return 'FALLBACK';
        }
}

# type_kvm_set_ownership_permissions(&server, user, group, perms, file+)
# If the filesystem for this kvm instance is locally mounted, change the
# permissions there
sub type_kvm_set_ownership_permissions
{
my ($server, $user, $group, $perms, @files) = @_;
if ($server->{'kvm_mount'}) {
	my $vhost = &type_kvm_parent($server);
	my $dir = $server->{'kvm_mount'};
	return &set_ownership_permissions_on_server($server, $user, $group,
			$perms, map { $dir.$_ } @files);
	}
else {
	return 'FALLBACK';
        }
}

# type_kvm_disk_usage(&server, dir, [include-counts])
# If the filesystem for this kvm instance is locally mounted, run the du
# command there.
sub type_kvm_disk_usage
{
my ($server, $dir, $counts) = @_;
if ($server->{'kvm_mount'}) {
	my $vhost = &type_kvm_parent($server);
	return &disk_usage_on_server($vhost, $server->{'kvm_mount'}.$dir,
				     $counts);
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

	# Find Linux or BSD partitions and their offsets
	my @offsets;
	foreach my $p (@$parts) {
		if (($p->{'type'} eq '83' || $p->{'type'} eq 'a5') &&
		    $p->{'offset'}) {
			push(@offsets, $p);
			}
		}
	if (!@offsets) {
		@offsets = @$parts;
		}
	@offsets || return &text('create_ekvmfslinux', $fsfile);

	# Try each partition with an offset
	foreach my $o (@offsets) {
		my $cmd = $o->{'type'} eq 'a5' ?
		  "mount -t ufs -o loop,offset=$o->{'offset'},ufstype=ufs2,ro" :
		  "mount -o loop,offset=$o->{'offset'}";
		my ($out, $ex, $err) = &execute_command_on_server($vhost,
			$cmd." ".quotemeta($fsfile)." ".quotemeta($mp));
		next if ($ex || $err);
		my @st = &stat_file_on_server($vhost,
					      $mp.($wantfile || "/etc"));
		if (@st) {
			# Found it! Leave mounted
			$server->{'kvm_mount'} = $mp;
			if (!$wantfile) {
				$server->{'kvm_filesystem_offset'} = $o->{'offset'};
				$server->{'kvm_filesystem_type'} = $o->{'type'};
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
my $t = $server->{'kvm_filesystem_type'} || "83";
my $cmd = $t eq 'a5' ? "mount -t ufs -o loop,offset=$o,ufstype=ufs2"
		     : "mount -o loop,offset=$o";
my ($out, $ex, $err) = &execute_command_on_server($vhost,
	$cmd." ".quotemeta($fsfile)." ".quotemeta($mp));
if ($ex) {
	return "Failed to mount $fsfile on $mp : $out".
	       ($t eq "a5" ? "\nThis may be due to lack of read-write support ".
			     "for UFS in the kernel" : "");
	}
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
my $procs = $kvm_check_login_procs_cache{$vhost->{'id'}};
if (!$procs || !ref($procs)) {
	$kvm_check_login_procs_cache{$vhost->{'id'}} = $procs =
		&list_kvm_instances($vhost);
	}
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
my ($proc) = grep { &match_kvm_instance($server, $_) } @$procs;
if (!$proc) {
	if ($server->{'kvm_pause'}) {
		# Pause file exists, must be paused
		return (8, "KVM instance is paused");
		}
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
my $vhost = &get_parent_server($server);

# If running, cannot be mounted
if ($server->{'status'} ne 'down' &&
    $server->{'status'} ne 'nohost') {
	delete($server->{'kvm_mount'});
	}

if ($server->{'kvm_disktotal'} <= 0 || $regen) {
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

if ((!defined($server->{'kvm_ip6'}) || $regen) &&
    ($server->{'status'} eq 'down' || &can_ssh_status($server))) {
	# Fetch IPv4 addresses from interfaces if somehow they are missing
	my $newip = join(" ", &list_interface_ip_addresses($server));
	$server->{'kvm_ip'} = $newip if ($newip);
	}

if (!defined($server->{'kvm_ip6'}) &&
    ($server->{'status'} eq 'down' || &can_ssh_status($server))) {
	# Fetch IPv6 addresses from interfaces
	my $newip6 = join(" ", &list_interface_ip6_addresses($server));
	$server->{'kvm_ip6'} = $newip6 if ($newip6);
	}

# If paused, make sure pause file still exists
if ($server->{'kvm_pause'} && $server->{'status'} ne 'nohost') {
	my @st = &stat_file_on_server($vhost, $server->{'kvm_pause'});
	if (!@st) {
		delete($server->{'kvm_pause'});
		}
	}

# Re-get the VNC port from the command line
if ($server->{'status'} ne 'down' && $server->{'status'} ne 'nohost') {
	my $proc;
	my $procs = &list_kvm_instances($vhost);
	if (ref($procs)) {
		($proc) = grep { &match_kvm_instance($server, $_) } @$procs;
		}
	if ($proc && $proc->{'args'}->{'vnc'} =~ /^[a-z0-9\.\_\-]*:(\d+)/) {
		$server->{'kvm_vnc_display'} = $1;
		}
	}
}

# type_kvm_post_host_refresh(&server, regenerate?)
# Called after a KVM host system is refreshed, to maybe get LVM info
sub type_kvm_post_host_refresh
{
my ($server, $regen) = @_;

# Not needed anymore
delete($server->{'kvm_vg_total'});
delete($server->{'kvm_vg_used'});
delete($server->{'kvm_vg_free'});

# Check if cgroups are supported
if (&can_ssh_status($server) &&
    (!defined($server->{'kvm_cgroup_support'}) || $regen)) {
	$server->{'kvm_cgroup_support'} = 0;
	if (&has_command_on_server($server, "cgcreate")) {
		my $cpath;
		foreach my $c ("/mnt/cgroups", "/cgroup", "/sys/fs/cgroup") {
			my @st = &stat_file_on_server($server, $c."/cpu");
			if (@st > 1) {
				$cpath = $c;
				last;
				}
			}
		if ($cpath) {
			$server->{'kvm_cgroup_support'} = 1;
			$server->{'kvm_cgroup_dir'} = $cpath;
			}
		}
	}
}

# type_kvm_edit_form(&server, [view-only])
# Show information about some KVM system
sub type_kvm_edit_form
{
my ($server, $view) = @_;
my $rv;

# KVM process ID
if ($server->{'status'} ne 'down') {
	$rv .= &ui_table_row($text{'edit_kvmpid'}, $server->{'kvm'});
	}

# Disk mode
$rv .= &ui_table_row($text{'edit_kvmdriver'},
	$server->{'kvm_virtio'} ? "VirtIO" : "IDE");

if ($view) {
	# Console keymap
	my $keymap;
	if ($server->{'kvm_keymap'}) {
		($keymap) = map { $_->[1] }
			grep { $_->[0] eq $server->{'kvm_keymap'} }
				&list_kvm_keymaps($server);
		}
	else {
		$keymap = $text{'default'};
		}
	$rv .= &ui_table_row($text{'edit_kvmkeymap'}, $keymap);

	# High-res graphics?
	$rv .= &ui_table_row($text{'create_kvmvga'},
		$server->{'kvm_vga'} ? $text{'yes'} : $text{'no'});

	# Additional command-line args
	if ($server->{'kvm_args'}) {
		$rv .= &ui_table_row($text{'edit_kvmargs'},
				     "<tt>$server->{'kvm_args'}</tt>");
		}
	}
else {
	# Console keymap
	$rv .= &ui_table_row($text{'edit_kvmkeymap'},
		&ui_select('kvm_keymap', $server->{'kvm_keymap'},
			   [ [ '', "&lt;$text{'default'}&gt;" ],
			     sort { $a->[1] cmp $b->[1] }
				  &list_kvm_keymaps($server) ]));

	# High-res graphics?
	$rv .= &ui_table_row($text{'create_kvmvga'},
		&ui_yesno_radio("kvm_vga", $server->{'kvm_vga'}));

	# Additional command-line args
	$rv .= &ui_table_row($text{'edit_kvmargs'},
		&ui_textbox("kvm_args", $server->{'kvm_args'}, 40));

	# Message about reboot
	$rv .= &ui_table_row(" ", $text{'create_kvmreboot'});
	}

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
	}

# Save VGA mode
$server->{'kvm_vga'} = $in->{'kvm_vga'};

# Save extra args
$in->{'kvm_args'} =~ /;|\&|\||<|>|\0|\!/ && &error($text{'create_ekvmargs'});
$server->{'kvm_args'} = $in->{'kvm_args'};

&type_kvm_set_atboot($server, 2);
}

# type_kvm_server_info(&server, show-in-bytes)
# Returns an array of information for list-systems.pl to display
sub type_kvm_server_info
{
my ($server, $bytes) = @_;
my @rv;
my $vhost = &type_kvm_parent($server);
push(@rv, [ "Hosted on", $vhost->{'host'} ]);
my $proc = &get_server_kvm_instance($server);
if ($proc) {
	push(@rv, [ "KVM process ID", $proc->{'pid'} ]);
	}
if ($server->{'kvm_disktotal'}) {
	push(@rv, [ "KVM total disk size",
		    ($bytes ? $server->{'kvm_disktotal'}
			    : &nice_size($server->{'kvm_disktotal'})) ]);
	}
if ($server->{'kvm_args'}) {
	push(@rv, [ "KVM command line args", $server->{'kvm_args'} ]);
	}
push(@rv, [ "KVM disk driver", $server->{'kvm_virtio'} ? "VirtIO" : "IDE" ]);
if ($server->{'kvm_keymap'}) {
	push(@rv, [ "KVM console keyboard type", $server->{'kvm_keymap'} ]);
	}
push(@rv, [ "KVM high resolution graphics?",
	    $server->{'kvm_vga'} ? "Yes" : "No" ]);
push(@rv, [ "Block spoofed IPs and MACs?",
	    $server->{'kvm_firewall'} ? "Yes" : "No" ]);
return @rv;
}

# type_kvm_server_host_info(&server, show-in-bytes)
# Returns an array of information for list-systems.pl to display, for a KVM
# host system
sub type_kvm_server_host_info
{
my ($server, $bytes) = @_;
my @rv;      
if (&can_ssh_status($server)) {
	my @bridges = &list_host_bridges($server);
	if (@bridges) {
		push(@rv, [ "KVM network bridges", join(" ", @bridges) ]);
		}
	}
push(@rv, [ "KVM directory", $server->{'kvm_dir'} ]);
push(@rv, [ "KVM version", &kvm_host_version($server) ]);
if ($server->{'kvm_vg'}) {
	push(@rv, [ "KVM LVM VG", $server->{'kvm_vg'} ]);
	}
if ($server->{'kvm_iscsi'} ne '') {
	my $iscsiserver = &get_managed_server($server->{'kvm_iscsi'});
	push(@rv, [ "KVM iSCSI server", $iscsiserver->{'host'} ]);
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
	$l =~ s/^.*cgexec\s+\-g\s+(\S+)\s+//;
	$l =~ s/^.*ionice\s+\-n\d+\s+//;
	$l =~ s/^.*sleep\s+(\d*0)\s*;\s+//;
	my $kvm = &parse_kvm_start_command($l);
	if ($kvm && &match_kvm_instance($server, $kvm)) {
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

# Work out a startup delay, which is the based on the number of other systems
# started at boot time on the same host
my $delay = 0;
my $temp = &transname();
my $bfile = &stat_file_on_server($vhost, "/etc/init.d") ?
		"/etc/init.d/cloudmin-kvm" : "/etc/rc.local";
my %sleeps;
if ($atboot && !&get_file_from_server($vhost, $bfile, $temp)) {
	my $lref = &read_file_lines($temp);
	foreach my $l (@$lref) {
		if ($l =~ /sleep\s+(\d*0)/) {
			$sleeps{$1}++;
			}
		}
	for($delay=0; $sleeps{$delay}; $delay+=10) { }
	}

# Create monitor input file and command to write it to socket
$server->{'kvm_console'} ||= &get_kvm_console_file($server);
my $ncerr = upload_nc_script($vhost);
return $ncerr if ($ncerr);
&create_kvm_monitor_file($server);

my $cmd = &get_kvm_start_command($server, 1, undef, $delay).
          " >$server->{'kvm_console'} 2>&1 </dev/null &";
$cmd .= " sleep 3 ;";
$cmd .= " /usr/bin/nc.pl --sleep 3 127.0.0.1 $server->{'kvm_monitor_port'} ".
	"<$server->{'kvm_monitor'} >>$server->{'kvm_console'} 2>&1";

if ($bfile =~ /^\/etc\/init.d\//) {
	# Insert into init script
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
		$line =~ s/^.*cgexec\s+\-g\s+(\S+)\s+//;
		$line =~ s/^.*ionice\s+\-n\d+\s+//;
		$line =~ s/^.*sleep\s+(\d*0)\s*;\s+//;
		my $kvm = &parse_kvm_start_command($line);
		if ($kvm && &match_kvm_instance($server, $kvm)) {
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
		if ($kvm && &match_kvm_instance($server, $kvm)) {
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

# type_kvm_check_image(&server, &image)
# Returns an error message if a system cannot be imaged for some reason
sub type_kvm_check_image
{
my ($server, $image) = @_;
my $fstab = &get_system_fstab($server);
return undef if (!ref($fstab));
my ($root) = grep { $_->[1] eq '/' } @$fstab;
return "No root filesystem found in /etc/fstab" if (!$root);
$root->[0] =~ /^\/dev\/(h|s|v)d[a-z]/ ||
    $root->[0] =~ /^\/dev\/(ada|da|ad)\d/ ||
	return "Root filesystem in /etc/fstab is mounted from $root->[0], ".
	       "not a real device path. This will cause systems created from ".
	       "the image to use incorrect device paths";
return undef;
}

# type_kvm_can_direct_image(&server)
# Returns 1 since imaging direct to the master is supported
sub type_kvm_can_direct_image
{
return 1;
}

# type_kvm_can_stream_image(&server, &image)
# Returns 1 because piping the image directly in from the master is supported
sub type_kvm_can_stream_image
{
return 1;
}

# type_kvm_create_image(&server, &image, image-to-dir, [nomunge],
# 			[&image-from-server], [&image-to-server])
# Convert a KVM system into an image file, which is really just the KVM disk.
# Outputs text, and returns 0 on failure.
sub type_kvm_create_image
{
my ($server, $image, $image_to_dir, $nomunge, $image_from_server,
    $image_to_server) = @_;
my $vhost = &type_kvm_parent($server);
$image_from_server ||= $vhost;

# Mount the disk image
&$first_print($text{'mkimage_kvmmount'});
my $fsfile = $server->{'kvm_filesystem'};
if (!$fsfile) {
	&$second_print($text{'mkimage_nofilesystem'});
	return 0;
	}
my $err = &type_kvm_mount_filesystem($server);
if ($err) {
	&$second_print(&text('create_exenmount', $err));
	}
else {
	&$second_print(&text('create_xenmounted',
			     "<tt>$server->{'kvm_mount'}</tt>"));

	if ($nomunge != 1) {
		# Munge some or all files
		my ($mok, $munged) = &munge_all_files($server, 0,$nomunge == 2);
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
my $d;
if (ref($disks)) {
	($d) = grep { $_->{'real'} eq $fsfile } @$disks;
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

# If the disk is on iSCSI, take the image from the iSCSI server
my $isdevice = $server->{'kvm_filesystem_lv'} ||
	       $server->{'kvm_filesystem_iscsi'} ne '';
if ($server->{'kvm_filesystem_iscsi'} ne '') {
	my $iscsiserver = &get_managed_server(
				$server->{'kvm_filesystem_iscsi'});
	if (!$iscsiserver) {
		&$second_print($text{'mkimage_eiscsiserver'});
		return 0;
		}
	if (!$d) {
		&$second_print($text{'mkimage_efirstdisk'});
		return 0;
		}
	my $idisk = &get_iscsi_disk_info($iscsiserver, $d);
	if (!$idisk) {
		&$second_print($text{'mkimage_eiscsidisk'});
		return 0;
		}
	$isdevice = $idisk->{'type'} eq 'file' ? 0 : 1;
	$fsfile = $idisk->{'real'};
	}

# Build the compression command
my $rv;
my ($cmd, $outfile);
if (!$image->{'nocompress'}) {
	# Compress disk image
	&start_background_dot_printer($text{'mkimage_xengzip'});
	$cmd = $isdevice ? &dd_command($fsfile, undef)." | gzip -c"
			 : "gzip -c ".quotemeta($fsfile);
	$outfile = $image->{'id'}.".ext3.gz";
	}
else {
	# Just use the image file as-is
	&start_background_dot_printer($text{'mkimage_xengzip2'});
	$outfile = $image->{'id'}.".ext3";
	$cmd = &dd_command($fsfile, undef);
	}

my ($out, $ex, $err);
if ($image_to_server) {
	# Write to a file on the image destination server (likely the master)
	my $perr = &pipe_command_to_server($image_from_server, $image_to_server,
			$cmd, "$image_to_dir/$outfile");
	if ($perr) {
		$out = $perr;
		$ex = 1;
		}
	$rv = 2;
	}
else {
	# Write to a file on the host
	($out, $ex, $err) = &execute_command_on_server($image_from_server,
		$cmd." > ".quotemeta("$image_to_dir/$outfile"));
	$rv = 1;
	}
&stop_background_dot_printer();
if ($ex) {
	&$second_print(&text('mkimage_exenlink', "<pre>$out</pre>"));
	$rv = 0;
	}
else {
	&$second_print($text{'create_done'});
	$image->{'files'} = $outfile;
	}

return $rv;
}

# type_kvm_get_image_server(&server)
# If a system's disk is on iSCSI, return the iSCSI server as the disk image
# temp file will be created there. Otherwise it is created on the host.
sub type_kvm_get_image_server
{
my ($server) = @_;
if ($server->{'kvm_filesystem_iscsi'} ne '') {
	my $iscsiserver = &get_managed_server(
				$server->{'kvm_filesystem_iscsi'});
	if ($iscsiserver) {
		return $iscsiserver;
		}
	}
return &get_parent_server($server);
}

# type_kvm_cleanup_image(&server, &image, tempdir, [&image-from-server],
# 			 [&image-to-server])
# Delete all temp files created on the host system for an image, and reverse
# any munge processes that were done to prepare the imaged system.
sub type_kvm_cleanup_image
{
my ($server, $image, $tempdir, $image_from_server, $image_to_server) = @_;
my $vhost = &type_kvm_parent($server);
$image_from_server ||= $vhost;

# Remove compressed image temp file, if there was one
if (!$image_to_server) {
	&$first_print($text{'mkimage_xendelete'});
	my $gzfile = $image->{'id'}.".ext3.gz";
	my ($out, $ex, $err) = &execute_command_on_server($image_from_server,
					"rm -f ".quotemeta("$tempdir/$gzfile"));
	$err = $out if ($ex);
	if ($err) {
		&$second_print(&text('mkimage_exendelete', $out));
		return 0;
		}
	else {
		&$second_print($text{'create_done'});
		}
	}

# Re-mount KVM filesystem
&$first_print($text{'mkimage_kvmmount'});
my $err = &type_kvm_mount_filesystem($server);
if ($err) {
	&$second_print(&text('create_exenmount', $err));
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
foreach my $cmd ("qemu-img", "parted", "lsof") {
	&has_command_on_server($server, $cmd) ||
		return &text('kvm_ewhich', "<tt>$cmd</tt>");
	}

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
my @st2 = &stat_file_on_server($server, "/dev/loop-control");
@st || @st2 || return &text('kvm_eloop', "<tt>/dev/loop1</tt>");

return undef;
}

# find_qemu_kvm_command(&vhost)
# Returns the command used for running qemu on some system
sub find_qemu_kvm_command
{
my ($vhost) = @_;
if ($kvm_qemu_command_cache{$vhost->{'id'}}) {
	return $kvm_qemu_command_cache{$vhost->{'id'}};
	}
my $info = &get_server_collected($vhost);
my $arch = $info->{'kernel'}->{'arch'};
$arch = "i386" if ($arch =~ /^i[0-9]86$/);
foreach my $c ("kvm", "qemu-kvm", "/usr/libexec/qemu-kvm",
	       "qemu-system-$arch",
	       $config{'kvm_qemu'} ? ( "qemu" ) : ( )) {
	my $path = &has_command_on_server($vhost, $c);
	if ($path) {
		$kvm_qemu_command_cache{$vhost->{'id'}} = $path;
		return $path;
		}
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
return &images_backup_system($server, $deststr, $shutdown, $owner);
}

# type_kvm_backup_extension(&server)
# Always returns .gz, as even multi-disk systems are backed up as separate files
sub type_kvm_backup_extension
{
my ($server) = @_;
return "gz";
}

# type_kvm_restore_system(&server, dest, shutdown)
# Restore single KVM instance from the given destination, and return a backup
# status hash ref.
sub type_kvm_restore_system
{
my ($server, $deststr) = @_;
delete($server->{'kvm_console'});	# Not valid on new host
delete($server->{'kvm_monitor'});
return &image_restore_system($server, $deststr);
}

# type_kvm_open_shell(&server)
# Runs SSH to connect to a remote system. Returns an error message
# (or undef if OK), and a file handle.
sub type_kvm_open_shell
{
my ($server) = @_;
my ($out, $ex, $err, $status, $fh, $fpid) =
	&execute_command_on_server($server, &get_bourne_shell($server), 0, 1);
return $err ? ($err, undef) : $ex ? ($out, undef) : (undef, $fh);
}

# type_kvm_get_dns_name(&server)
# Returns a system's DNS name and zone name
sub type_kvm_get_dns_name
{
my $vhost = &get_parent_server($server);
return ( $server->{'kvm_dns'}, $vhost->{'kvm_zone'} );
}

# type_kvm_can_pause(&server)
# Returns 1 if a system can be paused, 2 if it can be resumed, 0 if neither
sub type_kvm_can_pause
{
my ($server) = @_;
if ($server->{'status'} eq 'nohost' || $server->{'status'} eq 'down') {
	# Down, so neither can be done
	return 0;
	}
elsif ($server->{'status'} eq 'paused') {
	# Currently paused, can resume
	return 2;
	}
else {
	# Now running, can pause
	return 1;
	}
}

# type_kvm_pause_system(&server)
# Pauses a KVM instance by stopping it, writing memory to a pause file, then
# shutting it down
sub type_kvm_pause_system
{
my ($server) = @_;
my $vhost = &type_kvm_parent($server);
my $cmd = &find_qemu_kvm_command($vhost);
&kvm_host_supports_flag($vhost, "incoming") ||
	return "KVM on $vhost->{'host'} does not support the -incoming flag ".
	       "which is needed to un-pause a KVM instance";
if (!$server->{'kvm_pause'}) {
	my $pause = $server->{'kvm_console'} || &get_kvm_console_file($server);
	if ($pause !~ s/\.console$/\.pause/) {
		$pause .= ".pause";
		}
	$server->{'kvm_pause'} = $pause;
	}
my ($ok, $out) = &run_kvm_monitor_command($server,
			[ "stop",
			  "migrate_set_speed 4095m",
			  "migrate \"exec:cat >$server->{'kvm_pause'}\"",
			  "quit" ],
			3, -1);
return $out if (!$ok);
return undef;
}

# type_kvm_unpause_system(&server)
# Resumes a KVM instance. Returns undef on success or an error message
# on failure.
sub type_kvm_unpause_system
{
my ($server) = @_;
my $vhost = &get_parent_server($server);
$server->{'kvm_pause'} || return "Not currently paused";
my @st = &stat_file_on_server($vhost, $server->{'kvm_pause'});
@st || return "Pause file $server->{'kvm_pause'} does not ".
	      "exist on $vhost->{'host'}";
my ($ok, $err) = &type_kvm_startup($server, 0,
			"-incoming \"exec:cat $server->{'kvm_pause'}\"");
&delete_file_on_server($vhost, $server->{'kvm_pause'});
delete($server->{'kvm_pause'});
return $ok == 1 ? undef : $err;
}

# type_kvm_can_move(&server, [&dest])
# Check if moving a KVM instance is allowed. Only possible if target is up
# Returns 2 indicating than manual moves are supported too, or 3 indicating
# that only manual moves are possible.
sub type_kvm_can_move
{
my ($server, $dest) = @_;
return 0 if ($server->{'status'} eq 'paused');
return 0 if ($module_info{'onehost'} eq 'kvm');
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

# type_kvm_move_system(&server, &dest, [shutdown], [allocate-ip], [directory])
# Actually move a KVM instance to a new host, printing messages as it goes.
sub type_kvm_move_system
{
my ($server, $dest, $shutdown, $allocate, $directory) = @_;
my $vhost = &get_parent_server($server);
my (@delfiles, @dellvs);
my $old_kvm_dir = $server->{'directory'} || $vhost->{'kvm_dir'};
my $new_kvm_dir = (defined($directory) ? $directory : $server->{'directory'}) ||
		  $dest->{'kvm_dir'};
delete($kvm_check_login_procs_cache{$vhost->{'id'}});
delete($kvm_check_login_procs_cache{$dest->{'id'}});

# If virtual system disks are on iSCSI, make sure the dest vhost is using
# the same iSCSI server
my $disks = &type_kvm_list_disks($server, 0);
foreach my $d (@$disks) {
	if ($d->{'iscsi_ip'}) {
		$d->{'iscsi_server'} eq '' && return $text{'smove_eicsiserver'};
		my $old_iscsiserver = &get_managed_server($d->{'iscsi_server'});
		if ($server->{'kvm_force_iscsi'} ne '') {
			my $new_iscsiserver = &get_managed_server(
						$d->{'iscsi_server'});
			my $err = &check_iscsi_client($dest);
			$err && return &text('smove_eiscsidest', $err);
			}
		else {
			$dest->{'kvm_iscsi'} eq '' &&
				return $text{'smove_eicsidest'};
			my $new_iscsiserver = &get_managed_server(
						$dest->{'kvm_iscsi'});
			$old_iscsiserver->{'id'} eq $new_iscsiserver->{'id'} ||
				return &text('smove_eiscsidiff',
					     $old_iscsiserver->{'host'},
					     $new_iscsiserver->{'host'});
			}
		}
	}

# Check if a shutdown is needed, if kvm on the dest doesn't support -incoming,
my $shutwhy;
if (!$shutdown) {
	if (!&kvm_host_supports_flag($dest, "incoming")) {
		$shutdown = 1;
		$shutwhy = $text{'smove_incoming'};
		}
	elsif (!&kvm_host_supports_flag($vhost, "incoming")) {
		$shutdown = 1;
		$shutwhy = $text{'smove_incoming2'};
		}
	elsif (!$server->{'kvm_monitor_port'}) {
		$shutdown = 1;
		$shutwhy = $text{'smove_monitor'};
		}
	}

# Check if KVM disks dir is shared
my $shared = $old_kvm_dir eq $new_kvm_dir &&
	     &shared_dir_on_servers($vhost, $dest, $old_kvm_dir);

# Find the bridge to use on the new host system
my @dest_kvm_ifaces = split(/\s+/, $dest->{'kvm_iface'});
my ($kvm_hostiface) = split(/\s+/, $server->{'kvm_hostifaces'});
my $dest_kvm_iface = &indexof($kvm_hostiface, @dest_kvm_ifaces) >= 0 ?
			$kvm_hostiface : $dest_kvm_ifaces[0];

# Check if need to allocate new IP
my $ip = &get_server_ip($server);
my ($newip, $newcidr, $newgw);
my $defgw = &get_server_default_gateway($vhost);
my @gws = split(/\s+/, $server->{'kvm_gw'});
my $gw = $gws[0] eq "*" ? $defgw : $gws[0];
if ($allocate && $dest->{'kvm_start'} &&
    !&range_check_ip_address($ip, $dest->{'kvm_start'}, $dest->{'kvm_end'},
				  $dest->{'kvm_cidr'}, $dest->{'kvm_gws'},
				  $dest->{'kvm_ifaces'}, $dest_kvm_iface)) {
	# Allocate the primary IP
	&$first_print($text{'smove_allocating'});
	($newip, $newcidr, $newgw) = &allocate_ip_address(
		$dest->{'kvm_start'}, $dest->{'kvm_end'},
	        $dest->{'kvm_cidr'}, $dest->{'kvm_gws'},
		$dest->{'kvm_ifaces'}, $dest_kvm_iface);
	$newip || return &text('create_exenalloc', $dest->{'host'},
			    &describe_ip_range($dest->{'kvm_start'},
					       $dest->{'kvm_end'}));
	$newgw ||= &get_server_default_gateway($dest);
	$newgw = "" if ($newgw eq "*");
	&$second_print(&text('smove_allocated', $newip));

	# If gateway has changed, we need to shut down
	if ($newgw ne $gw) {
		$shutdown = 1;
                $shutwhy = $text{'smove_gwchange'};
		}
	}

my ($dumpsrc, $dumpdest, $was_up);
if ($server->{'status'} ne 'down' && $shutdown) {
	# Shut down before moving
	&$first_print($shutwhy ? &text('smove_shutting2', $shutwhy)
			       : $text{'smove_shutting'});
	$err = &shutdown_server($server);
	if ($err) {
		return &text('smove_shutfailed', $err);
		}
	&check_server_status($server, 0, 1);
	$was_up = 1;
	&$second_print($text{'create_done'});
	}

if ($newip) {
	# Apply the IP change now
	&$first_print(&text('smove_ipchanging', $ip, $newip));
	$ifaces = &type_kvm_list_interfaces($server);
	return $ifaces if (!ref($ifaces));
	my ($iface) = grep { $_->{'address'} eq $ip } @$ifaces;
	$iface || return $text{'smove_eifaceip'};
	my $oldiface = { %$iface };
	$iface->{'address'} = $newip;
	$iface->{'netmask'} = &net::prefix_to_mask($newcidr);
	$iface->{'bridge'} = $dest_kvm_iface;
	&modify_primary_ip_address($server, $ip, $newip);
	my $err = &type_kvm_modify_interface($server, $iface, $oldiface);
	return $err if ($err);
	$server->{'ip'} = $newip;
	&delete_ip_address($server, $ip);
	&add_ip_address($server, $newip);
	&$second_print($text{'create_done'});
	}

if ($server->{'status'} ne 'down' && !$shutdown) {
	# Save memory to a state file, if running - this also shuts down the VM
	&$first_print($text{'smove_dumping'});
	$dumpsrc = &tempname_on_server($vhost, $server->{'host'}.".state");
	if (!$dumpsrc) {
		return $text{'smove_etemp'};
		}
	my ($ok, $out) = &run_kvm_monitor_command($server,
				[ "stop",
				  "migrate_set_speed 4095m",
				  "migrate \"exec:cat >$dumpsrc\"",
				  "quit" ],
				3, -1);
	if (!$ok) {
		return &text('smove_edump', $out);
		}
	&$second_print($text{'create_done'});

	# Transfer state file
        &$first_print($text{'smove_dumpsend'});
        $dumpdest = &tempname_on_server($dest, $server->{'host'}.".state");
	if (!$dumpdest) {
		return $text{'smove_etemp'};
		}
        my $err = &transfer_file_between_servers(
                        $vhost, $dest, $dumpsrc, $dumpdest, 0, 1);
        &delete_file_on_server($vhost, $dumpsrc);
	return $err if ($err);
        &$second_print($text{'create_done'});
	}

# Change the default gateway if needed
if ($newip && $newgw ne $gw) {
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

# Copy across all disk images, directly if possible
my $count = 0;
my $iscsi_count = 0;
my $sz = 0;
&$first_print($text{'smove_disks'});
&$indent_print();
foreach my $d (@$disks) {
	$d->{'newreal'} = $d->{'real'};
	if ($d->{'device'} && !$d->{'lv'} && $d->{'iscsi_server'} eq '') {
		# A real device, which shouldn't be touched
		&$first_print(&text('smove_onedisk', $d->{'real'}));
		&$second_print(&text('smove_devdisk'));
		next;
		}

	# Check if disk file exists on the target system already, and
	# that the KVM directory isn't being changed
	my @sst = &recursive_stat_file_on_server($vhost, $d->{'real'});
	my @dst = &recursive_stat_file_on_server($dest, $d->{'real'});
	if (@dst && $dst[7] == $sst[7] &&
	    ($old_kvm_dir eq $new_kvm_dir || $d->{'lv'})) {
		# Already there! Perhaps from shared LVM or directory
		&$first_print(&text('smove_onedisk', $d->{'real'}));
		&$second_print($text{'smove_alrdisk'});
		next;
		}

	# If the disk is on iSCSI, the move can be done by simply disconnecting
	# and re-connecting on the new host
	if ($d->{'iscsi_server'} ne '') {
		&remote_finished();
		my $iscsiserver = &get_managed_server($d->{'iscsi_server'});
		&$first_print(&text('smove_iscsi', $iscsiserver->{'host'},
				    $d->{'iscsi_target'}));
		my $err = &disconnect_iscsi_disk($server, $d);
		if ($err) {
			return &text('smove_eiscsidis', $err);
			}
		my $newserver = { %$server };
		$newserver->{'kvm_on'} = $dest->{'id'};
		my $newd = { %$d };
		$err = &connect_iscsi_disk($newserver, $newd);
		if ($err) {
			return &text('smove_eiscsiconn', $err);
			}
		$d->{'newreal'} = $newd->{'real'};
		&$second_print($text{'create_done'});
		$iscsi_count++;
		next;
		}

	&start_background_dot_printer(&text('smove_onedisk', $d->{'real'}));
	my $newreal;
	if ($d->{'lv'}) {
		# LVM logical volume .. transfer to LV of the same name
		if (!$dest->{'kvm_vg'}) {
			&stop_background_dot_printer();
			return $text{'smove_errvg'};
			}
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
		if ($err) {
			&stop_background_dot_printer();
			return &text('smove_errlv', $err);
			}

		# Transfer over the data, using dd. The size for
		# checksum purposes is rounded down to 1MB to account
		# for differences in LVM block sizes
		my $err = &transfer_file_between_servers($vhost, $dest,
			$d->{'real'}, $newreal, 1, 1,
			int($d->{'size'}/(1024*1024))*1024*1024);
		if ($err) {
			&stop_background_dot_printer();
			return &text('smove_errdisk', $err);
			}
		push(@dellvs, $d->{'real'});
		}
	else {
		# Work out a new filename, and copy over the file
		$newreal = $d->{'real'};
		$newreal =~ s/^.*[\\\/]//;
		$newreal = "$new_kvm_dir/$newreal";
		my $err = &transfer_file_between_servers($vhost, $dest,
			$d->{'real'}, $newreal, 0, 1);
		if ($err) {
			&stop_background_dot_printer();
			return &text('smove_errdisk', $err);
			}
		push(@delfiles, $d->{'real'});
		}

	&stop_background_dot_printer();
	$d->{'newreal'} = $newreal;
	&$second_print(&text('smove_donedisk',
			     &nice_size($d->{'size'})));
	$count++;
	$sz += $d->{'size'};
	}
my @deldiskfiles = ( @dellvs, @delfiles );
&$outdent_print();
if ($count) {
	&$second_print(&text('smove_disksdone', $count,
			     &nice_size($sz)));
	}
elsif ($iscsi_count) {
	&$second_print(&text('smove_disksdone2', $iscsi_count));
	}
else {
	&$second_print(&text('smove_disksnone'));
	}

# Delete boot script on old host
my $oldboot = &type_kvm_get_atboot($server);
&type_kvm_set_atboot($server, 0);

# Fix disk paths
my @drives = split(/\s+/, $server->{'kvm_drives'});
my $destver = &kvm_host_version($dest);
foreach my $d (@$disks) {
	my %drive = map { split(/=/, $_, 2) }
                        split(/,/, $drives[$d->{'drive_index'}]);
	$drive{'file'} = $d->{'newreal'};
	if ($d->{'drive_index'} == 0) {
		# Fix up boot flag
		if (&compare_versions($destver, "1.1") >= 0) {
			delete($drive{'boot'});
			}
		else {
			$drive{'boot'} = 'on';
			}
		}
	$drives[$d->{'drive_index'}] =
		join(",", map { $_."=".$drive{$_} } keys %drive);
	if ($server->{'kvm_filesystem'} eq $d->{'real'}) {
		$server->{'kvm_filesystem'} = $d->{'newreal'};
		}
	}
$server->{'kvm_drives'} = join(" ", @drives);
$server->{'kvm_on'} = $dest->{'id'};
$server->{'directory'} = $directory if (defined($directory));
delete($server->{'new_directory'}) if (defined($directory));

# Force re-generation of monitor port, to prevent clashes
delete($server->{'kvm_monitor_port'});

# Enable at boot on new system
&type_kvm_set_atboot($server, $oldboot);

# Fix monitoring and console paths
push(@delfiles, $server->{'kvm_console'})
	if ($server->{'kvm_console'} && !$shared);
push(@delfiles, $server->{'kvm_monitor'})
	if ($server->{'kvm_monitor'} && !$shared);
foreach my $f ('kvm_monitor', 'kvm_console') {
	$server->{$f} =~ s/^\Q$old_kvm_dir\/\E/$new_kvm_dir\//;
	}

# Copy across bridge scripts
my @nets = split(/\s+/, $server->{'kvm_net'});
foreach my $net (@nets) {
	if ($net =~ /script=([^,]+-(eth\d+)\.sh)/) {
		my $script = $1;
		my $newscript = "$new_kvm_dir/$server->{'host'}-${2}.sh";
		my @st = &stat_file_on_server($dest, $newscript);
		if ($script =~ /^\Q$old_kvm_dir\/\E/ && !@st) {
			my $err = &transfer_file_between_servers($vhost, $dest,
					$script, $newscript, 0, 1);
			if ($err) {
				return &text('smove_ebridge', $script, $err);
				}
			&delete_file_on_server($vhost, $script);
			my $tap = $script;
			if ($tap =~ s/\.sh$/\.tap/) {
				&delete_file_on_server($vhost, $tap);
				}
			if ($script ne $newscript) {
				$net =~ s/script=\Q$script\E/script=$newscript/;
				}
			}
		}
	}
$server->{'kvm_net'} = join(" ", @nets);

# Re-generate network scripts to update firewall rules
if ($newip && $ip ne $newip) {
	my @firewall = split(/\s+/, $server->{'kvm_firewall'});
	for(my $i=0; $i<@firewall; $i++) {
		if ($firewall[$i] eq $ip) {
			$firewall[$i] = $newip;
			}
		}
	&type_kvm_save_firewall($server, \@firewall);
	}

# Delete the original disk images
if (@delfiles || @dellvs) {
	&$first_print(&text(@deldiskfiles ? 'smove_delfiles'
					  : 'smove_delfiles2',
			    scalar(@delfiles)+scalar(@dellvs)));
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
		my $err = &delete_all_disk_image_partitions($vhost, $f);
		my ($vg, $lv) = &split_lvm_device($f);
		$err = &delete_mapper_entries($vhost, $vg, $lv);
		&remote_foreign_call($vhost, "lvm", "delete_logical_volume",
				     { 'device' => $f });
		my $srcf = &find_snapshot_source_logical_volume(
				\%oldserver, $vg, $lv);
		if ($srcf) {
			# Delete snapshot source if no longer in use
			&delete_all_disk_image_partitions($vhost, $srcf);
			my ($srcvg, $srclv) = &split_lvm_device($srcf);
			&delete_mapper_entries($vhost, $srcvg, $srclv);
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

if ($dumpsrc) {
	# Restore dump on the new host
        &$first_print($text{'smove_undumping'});
	my ($ok, $err) = &type_kvm_startup($server, 0,
			"-incoming \"exec:cat $dumpdest\"");
	&delete_file_on_server($dest, $dumpdest);
        if (!$ok) {
                return &text('smove_eundump', $err);
                }
        &$second_print($text{'create_done'});
        }
elsif ($was_up) {
	# Start on the new host, if it was up before
	&$first_print($text{'smove_starting'});
	my ($ok, $err) = &startup_server($server);
	if (!$ok) {
		return &text('smove_startfailed', $err);
		}
	&$second_print($text{'create_done'});
	}

return undef;
}

# type_kvm_manual_move_system(&server, &dest, [directory])
# Update the configs to reflect a system move already done
sub type_kvm_manual_move_system
{
my ($server, $dest, $directory) = @_;
my $vhost = &get_parent_server($server);
$server->{'kvm_on'} = $dest->{'id'};

# Check if disks exist on target
&$first_print($text{'smove_checkdisks'});
my $disks = &type_kvm_list_disks($server, 0);
return $disks if (!ref($disks));
foreach my $d (@$disks) {
	my @dst = &recursive_stat_file_on_server($dest, $d->{'real'});
	if (!@dst) {
		return &text('smove_echeckdisk', $d->{'real'});
		}
	}
&$second_print($text{'smove_checkdisksok'});

# Update disk directory if changed
$server->{'directory'} = $directory if (defined($directory));
delete($server->{'new_directory'}) if (defined($directory));

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
	my $parts = &list_disk_image_partitions($vhost, $proc->{'filesystem'});
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
while($cmd =~ s/(\d*)(<|>)((\/\S+)|&\d+)\s*$//) { }
if ($line =~ /^\s*(\S+\/|)(qemu-kvm|kvm|qemu|qemu-system-x86_64|qemu-system-i[0-9]86)\s+(.*)/) {
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
		$a =~ s/\\(.)/$1/g;	# un-escape
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
my ($proc) = grep { &match_kvm_instance($server, $_) } @$procs;
return $proc;
}

# match_kvm_instance(&server, &instance)
# Returns 1 if some KVM instance details match a system
sub match_kvm_instance
{
my ($server, $instance) = @_;
return $server->{'kvm_filesystem'} eq $instance->{'filesystem'} ||
       $server->{'host'} eq $instance->{'args'}->{'name'};
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
return "<input type=button onClick='ifield = form.$ifield; chooser = window.open(\"kvm_chooser.cgi?host=\"+escape(form.$hfield.value), \"chooser\", \"toolbar=no,menubar=no,scrollbars=yes,width=600,height=300\"); chooser.ifield = ifield; window.ifield = ifield' value=\"...\">\n";
}

# allocate_kvm_ip_addresses(&server, &vhost, [&bridges])
# Allocate one or more IP addresses for a KVM instance from the host's ranges.
# On success, returns undef and sets kvm_ip, kvm_cidr and kvm_iface to space-
# separated lists. On failure returns an error message.
sub allocate_kvm_ip_addresses
{
my ($server, $vhost, $bridges) = @_;
$vhost->{'kvm_start'} || return &text('create_exenallocnone', $vhost->{'host'});

# Work out interfaces on host system
my @hostifaces;
if ($bridges) {
	@hostifaces = @$bridges;
	}
elsif ($vhost->{'kvm_iface'}) {
	@hostifaces = grep { &can_use_bridge($_) }
			   split(/\s+/, $vhost->{'kvm_iface'});
	}
else {
	@hostifaces = ( "*" );
	}
@hostifaces || return $text{'create_exennoifaces'};

# For each, allocate an IP from a range
my (@ips, @cidrs, @gws);
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

# allocate_kvm_ip6_addresses(&server, &vhost, [&bridges])
# Allocate one or more IPv6 addresses for a KVM instance from the host's ranges.
# On success, returns undef and sets kvm_ip6, kvm_netmask6 and kvm_iface6 to
# space-separated lists. On failure returns an error message.
sub allocate_kvm_ip6_addresses
{
my ($server, $vhost, $bridges) = @_;
$vhost->{'kvm_pool6'} || return &text('create_exenallocnone6',$vhost->{'host'});

# Work out interfaces on host system
my @hostifaces;
if ($bridges) {
	@hostifaces = @$bridges;
	}
elsif ($vhost->{'kvm_iface'}) {
	@hostifaces = split(/\s+/, $vhost->{'kvm_iface'});
	}
else {
	@hostifaces = ( "*" );
	}

# For each, allocate an IP from a range
my (@ips, @netmasks, @gws);
foreach my $iface (@hostifaces) {
	my ($ip, $netmask, $gw) = &allocate_ip6_address(
		$vhost->{'kvm_pool6'}, $vhost->{'kvm_ifaces'}, $iface);
	$ip || return &text('create_exenalloc6', $vhost->{'host'},
			    &describe_ip6_pool($vhost->{'kvm_pool6'},
                                               $vhost->{'kvm_ifaces'},
                                               $iface));
	push(@ips, $ip);
	push(@netmasks, $netmask);
	push(@gws, $gw || "*");
	}
$server->{'kvm_ip6'} = join(" ", @ips);
$server->{'kvm_netmask6'} = join(" ", @netmasks);
$server->{'kvm_hostifaces6'} = join(" ", @hostifaces);
$server->{'kvm_gw6'} = join(" ", @gws);
return undef;
}

# get_kvm_console_file(&server)
# Returns the filename to use for a KVM system's console file
sub get_kvm_console_file
{
my ($server) = @_;
my $dir;
if ($server->{'kvm_filesystem_lv'} ||
    $server->{'kvm_filesystem_iscsi'} ne '' ||
    !$server->{'kvm_filesystem'}) {
	# On LVM, use config dir for console file
	my $vhost = &get_parent_server($server);
	$dir = $server->{'directory'} || $vhost->{'kvm_dir'};
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

# type_kvm_can_convert_image(&image)
# KVM images can be converted to Xen, with HVM
sub type_kvm_can_convert_image
{
return ( { 'manager' => 'xen',
	   'xen_hvm' => 1 },
	 { 'manager' => 'citrix',
	   'citrix_hvm' => 1 },
       );
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

# type_kvm_can_clone_remote(&server)
# KVM instances can be cloned to a another host system.
sub type_kvm_can_clone_remote
{
return 1;
}

# type_kvm_check_clone(&oldserver, &newserver, new-hostname, &ips, snapshot,
# 		       [&new-host], [&ips-v6])
# Checks if cloning of some system will work, before shutting it down. Returns
# undef on success or an error message on failure.
sub type_kvm_check_clone
{
my ($oldserver, $newserver, $newhost, $ips, $snapshot, $dest, $ips6) = @_;
my $vhost = &type_kvm_parent($newserver);
$dest ||= $vhost;

# Make sure hostname is sensible
if ($dest->{'kvm_zone'}) {
	return $text{'clone_ehost2'} if ($newhost =~ /\./);
	}

# Check for IPs if needed
if (!$dest->{'kvm_start'}) {
	$ips && scalar(@$ips) || return &text('clone_eips', $dest->{'host'});
	}
if ($ips) {
	my @oldips = split(/\s+/, $oldserver->{'kvm_ip'});
	scalar(@oldips) == scalar(@$ips) ||
		return &text('clone_eips2', scalar(@oldips), scalar(@$ips));
	}

# Check for IPv6 addresses
if (!$dest->{'kvm_pool6'} && $oldserver->{'kvm_ip6'}) {
	$ips6 && scalar(@$ips6) || return &text('clone_eips6', $dest->{'host'});
	}
if ($ips6) {
	my @oldips6 = split(/\s+/, $oldserver->{'kvm_ip6'});
	scalar(@oldips6) == scalar(@$ips6) ||
		return &text('clone_eips62', scalar(@oldips), scalar(@$ips));
	}

# Make sure all disks are on LVM if snapshotting
if ($snapshot) {
	my $disks = &type_kvm_list_disks($newserver, 0);
	foreach my $d (@$disks) {
		next if ($d->{'device'} && !$d->{'lv'});
		$d->{'lv'} || return &text('clone_elvm', $d->{'real'});
		}
	}

# If cloning to a new host, make sure it uses the same iSCSI server
if ($vhost->{'id'} ne $dest->{'id'}) {
	my $disks = &type_kvm_list_disks($newserver, 0);
	foreach my $d (@$disks) {
		if ($d->{'iscsi_ip'}) {
			$d->{'iscsi_server'} eq '' &&
				return $text{'clone_eicsiserver'};
			my $old_iscsiserver = &get_managed_server(
				$d->{'iscsi_server'});
			if ($server->{'kvm_force_iscsi'} ne '') {
				my $new_iscsiserver = &get_managed_server(
							$d->{'iscsi_server'});
				my $err = &check_iscsi_client($dest);
				$err && return &text('smove_eiscsidest', $err);
				}
			else {
				$dest->{'kvm_iscsi'} eq '' &&
					return $text{'clone_eicsidest'};
				my $new_iscsiserver = &get_managed_server(
							$dest->{'kvm_iscsi'});
				$old_iscsiserver->{'id'} eq
				    $new_iscsiserver->{'id'} ||
					return &text('clone_eiscsidiff',
					    $old_iscsiserver->{'host'},
					    $new_iscsiserver->{'host'});
				}
			}
		}
	}

# Prevent snapshotting when cloning remotely
if ($snapshot && $dest->{'id'} ne $vhost->{'id'}) {
	return $text{'clone_esnapremote'};
	}

# If cloning a system on LVM, make sure the dest also has LVM
if ($server->{'kvm_filesystem_vg'} && !$dest->{'kvm_vg'} &&
    $dest->{'id'} ne $vhost->{'id'}) {
	return $text{'clone_elvmremote'};
	}

return undef;
}

# type_kvm_clone_system(&oldserver, &newserver, new-hostname, &ips, snapshot,
# 			[&new-host], [&ips-v6])
# Creates a clone of some KVM instance, updating the newserver hash.
# Returns an error message and a flag indicating if the failure was total or
# only partial.
sub type_kvm_clone_system
{
my ($oldserver, $newserver, $newhost, $ips, $snapshot, $dest, $ips6) = @_;
my $vhost = &type_kvm_parent($newserver);
$dest ||= $vhost;
delete($kvm_check_login_procs_cache{$vhost->{'id'}});
delete($kvm_check_login_procs_cache{$dest->{'id'}});
my $old_kvm_dir = $oldserver->{'directory'} || $vhost->{'kvm_dir'};
my $new_kvm_dir = $newserver->{'directory'} || $dest->{'kvm_dir'};

# Generate the new full hostname
if ($dest->{'kvm_zone'}) {
	$newserver->{'host'} = $newhost.".".$dest->{'kvm_zone'};
	}
else {
	$newserver->{'host'} = $newhost;
	}
my $clash = &get_managed_server_by("host", $newserver->{'host'});
if ($clash) {
	return (&text('clone_eclash', $newserver->{'host'}), 1);
	}

# Allocate new IPv4 addresses
if ($ips) {
	# Use supplied list, keep old netmasks and gateways
	$newserver->{'kvm_ip'} = join(" ", @$ips);
	}
else {
	# Allocate new IPs
	&$first_print($text{'clone_allocating'});
	my $err = &allocate_kvm_ip_addresses($newserver, $dest);
	return ($err, 1) if ($err);
	}
my @oldips = split(/\s+/, $oldserver->{'kvm_ip'});
my @ips = split(/\s+/, $newserver->{'kvm_ip'});
my @cidrs = split(/\s+/, $newserver->{'kvm_cidr'});
my @netmasks = map { &net::prefix_to_mask($_) } @cidrs;
my $defgw = &get_server_default_gateway($dest);
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

# Allocate new IPv6 addresses
if ($ips6) {
	# Use supplied list, keep old netmasks
	$newserver->{'kvm_ip6'} = join(" ", @$ips6);
	}
elsif ($oldserver->{'kvm_ip6'}) {
	# Need to allocate new ones
	&$first_print($text{'clone_allocating6'});
	my $err = &allocate_kvm_ip6_addresses($newserver, $dest);
	return ($err, 1) if ($err);
	}
my @ips6 = split(/\s+/, $newserver->{'kvm_ip6'});
my @netmasks6 = split(/\s+/, $newserver->{'kvm_netmask6'});
$newserver->{'ip_addresses6'} = join(" ", @ips6);
&complete_managed_server($newserver);
if (!$ips6 && @ips6) {
	&$second_print(&text('clone_allocated', join(" ", @ips6)));
	}

delete($newserver->{'kvm_console'});

# Get old boot flag
my $oldboot = &type_kvm_get_atboot($oldserver);

# Clear iSCSI username and password, so that a new one is generated
delete($newserver->{'iscsi_user'});
delete($newserver->{'iscsi_pass'});
delete($newserver->{'iscsi_disk_count'});

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
	if ($d->{'device'} && !$d->{'lv'} && $d->{'iscsi_server'} eq '') {
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
		if ($dest->{'kvm_vg'} ne $d->{'vg'}) {
			$d->{'vg'} = $dest->{'kvm_vg'};
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
		&remote_foreign_require($dest, "lvm", "lvm-lib.pl");
		$err = &remote_foreign_call($dest, "lvm",
					  "create_logical_volume", $lv);
		$err ||= $last_remote_error;

		if (!$err && !$snapshot) {
			# Copy the data using dd
			$err = &transfer_file_between_servers(
			    $vhost, $dest,
			    $d->{'real'}, $d->{'newreal'}, 1, 1,
			    int($d->{'size'}/(1024*1024))*1024*1024);
			}
		elsif (!$err && !$d->{'swap'} && $snapshot &&
		       &type_kvm_can_fsck($oldserver, $d)) {
			# Fsck the disk after snapshotting
			my $newd = { %$d };
			$newd->{'real'} = $d->{'newreal'};
			$newd->{'lv'} = $newlv;
			my ($ok, $out) = &type_kvm_fsck_disk(
					$oldserver, $newd, 0);
			}
		}
	elsif ($d->{'iscsi_server'} ne '') {
		# Cloning to a new iSCSI disk (with new target name)
		my $newd = { %$d };
		delete($newd->{'iscsi_target'});
		$newserver->{'kvm_on'} = $dest->{'id'};	# So disk is mounted on
							# new host system
		$err = &create_iscsi_disk($newserver, $newd);
		if (!$err) {
			# Copy the data using DD, on the iSCSI server
			$d->{'newreal'} = $newd->{'real'};
			$err = &clone_iscsi_disk($oldserver, $newserver,
						 $d, $newd);
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
		if ($d->{'real'} !~ /^\Q$new_kvm_dir\E\//) {
			$d->{'newreal'} =~ s/^.*[\\\/]//;
			$d->{'newreal'} = "$new_kvm_dir/$d->{'newreal'}";
			}
		# Copy the file
		$err = &transfer_file_between_servers($vhost, $dest,
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
			$newserver->{'kvm_filesystem_iscsi_target'} =
				$d->{'iscsi_target'};
			}
		if ($newserver->{'kvm_swapfile'} eq $d->{'real'}) {
			$newserver->{'kvm_swapfile'} = $d->{'newreal'};
			$newserver->{'kvm_swapfile_iscsi_target'} =
				$d->{'iscsi_target'};
			}
		&$second_print(&text($snapped ? 'clone_snapdiskdone'
					      : 'clone_copydiskdone',
				     $d->{'newreal'}));
		$i++;
		}
	}
&$outdent_print();
$newserver->{'kvm_drives'} = join(" ", @drives);
$newserver->{'kvm_on'} = $dest->{'id'};
&$second_print($text{'create_done'});

# Register in DNS
if ($dest->{'kvm_zone'}) {
	my $dnsname = $newhost.".".$dest->{'kvm_zone'}.".";
	if (&add_bind8_record($dnsname, $ips[0],
			      $dest->{'kvm_zone'})) {
		$newserver->{'kvm_dns'} = $dnsname;
		if (@ips6) {
			&add_bind8_record($dnsname, $ips6[0],
					  $dest->{'kvm_zone'});
			}
		}
	else {
		delete($newserver->{'kvm_dns'});
		}
	}

# Mount the filesystem
&$first_print($text{'create_xenmount'});
delete($newserver->{'kvm_filesystem_offset'});	# May be invalidated
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
$newserver->{'mac_addresses'} = join(" ", @macs);

# Fix other config files that refer to the hostname or IP
&$first_print($text{'create_xenfix'});
my $fullhost = $dest->{'kvm_zone'} ? 
		$newhost.".".$dest->{'kvm_zone'} : $newhost;
my $err = &fix_hostname_config_files($newserver, $ips[0],
					$newserver->{'host'}, $fullhost, $dest,
					$mp, $dest->{'kvm_resolv'});
if ($err) {
	&$second_print(&text('create_ekvmfix', $err));
	}       
else {
	&$second_print($text{'create_done'});
	}

# Setup networking config files to use the IP.
&$first_print($text{'create_xennet'});
my $err = &fix_network_config_files($newserver, $ips[0], $netmasks[0],
				    $gws[0], $dest, $mp);
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
		[ @gws[1..$#gws] ], $dest, $mp);
	if ($err) {
		&$second_print(&text('create_ekvmnet2', $err));
		}       
	else {
		&$second_print($text{'create_done'});
		}
	}

# Apply IPv6 addresses to interfaces
if (@ips6) {
	&$first_print($text{'create_xenipv6'});
	my $err = &apply_ipv6_addresses($newserver, \@ips6, \@netmasks6);
	if ($err) {
		&$second_print(&text('create_exenipv6', $err));
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
		$fakeifaces->[0]->{'address'} ||= $ips[0];
		&add_all_iface_dhcpd($newserver, $fakeifaces);
		}
	}

# Copy network bridge scripts, with new paths and filename
my @nets = split(/\s+/, $newserver->{'kvm_net'});
foreach my $net (@nets) {
	if ($net =~ /script=([^,]+-(eth\d+)\.sh)/) {
		my $script = $1;
		my $newscript = "$new_kvm_dir/${newkvm}-${2}.sh";
		my $err = &transfer_file_between_servers($vhost, $dest,
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

# Re-generate network scripts to update firewall rules
my @firewall = split(/\s+/, $newserver->{'kvm_firewall'});
for(my $i=0; $i<@firewall; $i++) {
	my $idx = &indexof($firewall[$i], @oldips);
	if ($idx >= 0 && $idx < @ips) {
		$firewall[$i] = $ips[$idx];
		}
	}
&type_kvm_save_firewall($newserver, \@firewall);

# Fix up other config entries using the old name
foreach my $f ('kvm_filesystem_lv', 'kvm_swapfile_lv',
	       'kvm_console', 'kvm_monitor', 'login_user', 'data_files',
	       'kvm_net') {
	$newserver->{$f} =~ s/\Q$oldkvm_us\E/$newkvm_us/g;
	$newserver->{$f} =~ s/\Q$oldkvm\E/$newkvm/g;
	}

# Fix monitoring and console paths
foreach my $f ('kvm_monitor', 'kvm_console') {
	$newserver->{$f} =~ s/^\Q$old_kvm_dir\/\E/$new_kvm_dir\//;
	}

# Force re-generation of monitor port
delete($newserver->{'kvm_monitor_port'});

# Enable at boot for new VM
&type_kvm_set_atboot($newserver, $oldboot);

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
	return 0 if (!$server->{'data_files'} &&
		     !$server->{'checked_data_files'});
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
return map { $_->{'real'} } grep { $_->{'iscsi_server'} eq '' } @$disks;
}

# type_kvm_failover_system(&server, &dest)
# Has nothing to do really, as KVM has no config files to copy.
sub type_kvm_failover_system
{
my ($server, $dest) = @_;
my $vhost = &get_parent_server($server);
$server->{'kvm_on'} = $dest->{'id'};
delete($server->{'kvm_monitor_port'});
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
&type_kvm_set_atboot($server, 2);
return undef;
}

# type_kvm_can_graphical_password(&server)
# Returns 2, indicating that the VNC password can be set with a reboot
sub type_kvm_can_graphical_password
{
my ($server) = @_;
if ($server->{'kvm_vnc_display'}) {
	return 2;
	}
return 0;
}

# type_kvm_get_graphical_password(&server)
# Returns the VNC password
sub type_kvm_get_graphical_password
{
my ($server) = @_;
return $server->{'kvm_vnc_passwd'};
}

# type_kvm_set_graphical_password(&server, pass)
# Updates the VNC password to use at next boot
sub type_kvm_set_graphical_password
{
my ($server, $pass) = @_;
if (length($pass) > 7) {
	return &text('pass_evlength', 7);
	}
$server->{'kvm_vnc_passwd'} = $pass;
return undef;
}

# type_kvm_get_graphical_port(&server)
# Returns the VNC port number
sub type_kvm_get_graphical_port
{
my ($server) = @_;
return $server->{'kvm_vnc_display'} ? 5900 + $server->{'kvm_vnc_display'}
				    : undef;
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

if ($config{'vnc_passmode'} == 0) {
	$server->{'kvm_vnc_passwd'} ||= $server->{'ssh_pass'};
	}
$server->{'kvm_vnc_passwd'} ||= &generate_random_password(7);
push(@mlines, "change vnc password");
push(@mlines, $server->{'kvm_vnc_passwd'});

# Write out monitor input
return &put_file_data_to_server($vhost, join("", map { $_."\n" } @mlines),
			 	$server->{'kvm_monitor'});
}

# upload_nc_script(&vhost)
# Ensure that /usr/bin/nc.pl exists
sub upload_nc_script
{
my ($vhost) = @_;
return &put_file_to_server($vhost,
	"$module_root_directory/nc.pl", "/usr/bin/nc.pl");
}

# run_kvm_monitor_command(&server, &commands, command-delay, [timeout])
# Runs some commands by connecting to the KVM monitor port for a system,
# and returns an OK flag and the output.
sub run_kvm_monitor_command
{
my ($server, $cmds, $delay, $timeout) = @_;
$timeout ||= 10;
$server->{'kvm_monitor_port'} ||
	return (0, "This system was not started with a monitor port");
my $vhost = &type_kvm_parent($server);
my $monout;
if ($vhost->{'id'} eq '0') {
	# Make a direct local connection
	my $err;
	alarm($timeout) if ($timeout > 0);
	my $out;
	eval {
		local $SIG{'ALRM'} = sub { die "timeout" };
		&open_socket("127.0.0.1", $server->{'kvm_monitor_port'},
			     MON, \$err);
		return (0, $err) if ($err);
		foreach my $c (@$cmds) {
			sleep($delay) if ($delay);
			print MON $c,"\n";
			}
		shutdown(MON, 1);
		while(<MON>) {
			$out .= $_;
			}
		close(MON);
		};
	alarm(0);
	if ($@ =~ /timeout/) {
		return (0, "Monitor command timed out after $timeout seconds");
		}
	elsif ($@) {
		return (0, $@);
		}
	$monout = $out;
	}
else {
	# Connect via nc.pl
	&has_command_on_server($vhost, "/usr/bin/nc.pl") ||
	  return (0, "The nc.pl command is needed on $vhost->{'host'} to run ".
		     "KVM monitor commands");
	@$cmds || return (0, "No monitor commands given");

	# Run nc with echo into it. Only take the last 2 lines, as the KVM
	# console sometimes outputs huge long lines that take wait_for_lines
	# a long time to parse
	my @echos;
	foreach my $c (@$cmds) {
		push(@echos, "echo ".quotemeta($c));
		}
	my $sleep = $delay ? "--sleep $delay" : "";
	my ($out, $ex, $err) = &execute_command_on_server($vhost,
		"(".join(" ; ", @echos).") | ".
		"/usr/bin/nc.pl $sleep 127.0.0.1 $server->{'kvm_monitor_port'}",
		$timeout > 0 ? $timeout : undef);
	if ($ex || $err) {
		return (0, $err || $out);
		}
	$monout = $out;
	}
if ($monout =~ /unknown\s+command/i) {
	return (0, $monout);
	}
return (1, $monout);
}

# list_kvm_pci_devices(&server)
# Returns a list of hash refs with the following keys
# bus - PCI bus number
# device - Device number on the bus
# type - PCI device type (Ethernet controller, Storage controller)
sub list_kvm_pci_devices
{
my ($ok, $out) = &run_kvm_monitor_command($server, [ "info pci" ]);
return $out if (!$ok);
my @rv;
my $pci;
foreach my $l (split(/\r?\n/, $out)) {
	if ($l =~ /Bus\s+(\d+),\s+device\s+(\d+)/i) {
		$pci = { 'bus' => $1,
			 'device' => $2, };
		push(@rv, $pci);
		}
	elsif ($l =~ /^\s+(\S.*):\s+PCI\s+device\s+(\S+):(\S+)/i && $pci) {
		$pci->{'type'} = $1;
		$pci->{'major'} = $2;
		$pci->{'minor'} = $3;
		}
	elsif ($l =~ /^\s+id\s+"(.*)"/) {
		$pci->{'id'} = $1;
		}
	}
return \@rv;
}

# load_kvm_hotplug_modules(&server)
# Load kernel modules needed for hotplug support
sub load_kvm_hotplug_modules
{
my ($server) = @_;
if (&can_ssh_status($server)) {
	&execute_command_on_server($server, "modprobe acpiphp", $short_timeout);
	&execute_command_on_server($server, "modprobe pci_hotplug", $short_timeout);
	}
}

# kvm_host_supports_flag(&vhost, flag)
# Checks if KVM on some host system supports a flag
sub kvm_host_supports_flag
{
my ($vhost, $flag) = @_;
my $out = $kvm_host_supports_flag_cache{$vhost->{'id'}};
if (!$out) {
	my $cmd = &find_qemu_kvm_command($vhost);
	($out) = &execute_command_on_server($vhost, $cmd." --help");
	if (!$ex && !$err) {
		$kvm_host_supports_flag_cache{$vhost->{'id'}} = $out;
		}
	}
return $out =~ /-$flag/ ? 1 : 0;
}

# kvm_host_version(&vhost)
# Returns the version of KVM installed
sub kvm_host_version
{
my ($vhost) = @_;
if (!$kvm_host_version_cache{$vhost->{'id'}}) {
	my $cmd = &find_qemu_kvm_command($vhost);
        my ($out) = &execute_command_on_server($vhost, $cmd." --help");
	if ($out =~ /version\s+(\S+)/) {
		$kvm_host_version_cache{$vhost->{'id'}} = $1;
		}
	}
return $kvm_host_version_cache{$vhost->{'id'}};
}

# delete_kvm_cgroup(&server, [&vhost])
# Delete the cgroup for a VM on it's host
sub delete_kvm_cgroup
{
my ($server, $vhost) = @_;
$vhost ||= &type_kvm_parent($server);
if ($vhost->{'kvm_cgroup_support'} && &can_ssh_status($vhost)) {
	&execute_command_on_server($vhost, "cgdelete cpu:$server->{'id'}");
	}
}

# regenerate_all_kvm_bridge_scripts(&server)
# Re-write out all bridge scripts for a KVM instance
sub regenerate_all_kvm_bridge_scripts
{
my ($server) = @_;
my $vhost = &type_kvm_parent($server);
my @nets = split(/\s+/, $server->{'kvm_net'});
my @bridges = split(/\s+/, $server->{'kvm_hostifaces'});
my $i = 0;
foreach my $net (@nets) {
	my $bridge = $bridges[$i];
	if ($net =~ /script=([^,]+-(eth\d+)\.sh)/) {
		my $script = $1;
		my $eth = $2;
                $bridge = undef if ($bridge eq '*');
                my ($data, undef) = &generate_kvm_bridge_script(
                        $server, { 'name' => $eth }, $bridge);
                my $err = &put_file_data_to_server($vhost, $data, $script);
		return $err if ($err);
		}
	}
return undef;
}

# type_kvm_can_firewall(&server)
# Returns 1 if an allowed IP / MAC address firewall can be managed on some
# system
sub type_kvm_can_firewall
{
my ($server) = @_;
return !&check_firewall_allowed_ips($server);
}

# type_kvm_get_firewall(&server)
# If the IP spoofing firewall is disabled, returns an empty list. If all active
# IPs are allowed, returns just '*'. Otherwise, returns the list of allowed IPs.
sub type_kvm_get_firewall
{
my ($server) = @_;
return split(/\s+/, $server->{'kvm_firewall'});
}

# type_kvm_save_firewall(&server, &ips)
# Enabled or disables the IP spoofing firewall. The ips parameter has the same
# meaning as returned by type_kvm_get_firewall
sub type_kvm_save_firewall
{
my ($server, $ips) = @_;
$server->{'kvm_firewall'} = join(" ", @$ips);

# Need to activate or de-activate firewall
if ($server->{'status'} ne 'down' && $server->{'status'} ne 'nohost') {
	my $ifaces = &type_kvm_list_interfaces($server, 1);
	ref($ifaces) || return "Failed to list interfaces : $ifaces";
	foreach my $iface (grep { $_->{'tap'} } @$ifaces) {
		my $err = &activate_firewall_commands($server,
			$server->{'kvm_firewall'}, $iface->{'tap'});
		return $err if ($err);
		}
	}

# Update interface scripts
return &regenerate_all_kvm_bridge_scripts($server);
}

# type_kvm_open_vnc_port(&server, mode)
# Opens a VNC port on the master system which is connected to the VNC console
# on the VM. Returns a port number and password on success, or 0 and an error
# message on failure.
# XXX drop websockets proxying when Webmin 2.002 is out
sub type_kvm_open_vnc_port
{
my ($server, $mode) = @_;
$server->{'kvm_vnc_display'} ||
	return (0, $text{'vnc_ecannot'});

# Get the VNC port
my $vhost = &type_kvm_parent($server);
my ($port, $wsport);

if ($mode == 0 || $mode == 1) {
	# Check that the VNC port is really open on the KVM host, and connect
	# for proxying
	$port = 5900 + $server->{'kvm_vnc_display'};
	my $err = undef;
	&open_socket($vhost->{'ip'}, $port, VNCSOCK, \$err);
	if ($err) {
		return (0, &text('vnc_nolisten', $port, $vhost->{'host'}));
		}
	}
elsif ($mode == 2) {
	# Also connect to the websockets port on the kVM host for proxying
	my $wserr = undef;
	$wsport = $server->{'kvm_vnc_websocket'};
	&open_socket($vhost->{'ip'}, $wsport, WSSOCK, \$wserr);
	if ($wserr) {
		return (0, &text('vnc_nolisten', $wsport, $vhost->{'host'}));
		}
	}

my $masterport;
my ($wsmasterport, $wsencrypt);
if ($port) {
	if ($vhost->{'id'} == 0) {
		# Special case - this box is the KVM host, so no forwarding
		$masterport = $port;
		$wsport = $server->{'kvm_vnc_websocket'};
		close(VNCSOCK);
		}
	else {
		# Pick a free port on the Cloudmin master, 5900+
		my $err;
		($masterport, $err) = &forward_vnc_port(5900, VNCSOCK);
		return (0, &text('vnc_eforward', $err)) if ($err);
		}
	}
if ($wsport) {
	# Also forward a port in the 5700+ range for websockets
	$wsencrypt = $ENV{'HTTPS'} eq 'ON' ? 1 : 0;
	($wsmasterport, $err) = &forward_vnc_port(5700, WSSOCK, $wsencrypt);
	return (0, &text('vnc_eforwardws', $err)) if ($err);
	}
return ($masterport, $server->{'kvm_vnc_passwd'}, $wsmasterport, $wsencrypt,
	$vhost->{'ip'}, $port, $wsport);
}

# type_kvm_supports_websockets(&server)
# Can this system accept a websockets VNC connection?
sub type_kvm_supports_websockets
{
my ($server) = @_;
return $server->{'kvm_vnc_websocket'};
}

# install_kvm_host_software(&vhost, [qemu-mode])
# Performs all installation and configuration needed to setup a KVM host,
# printing stuff along the way. Returns 0 on failure, 1 on success, or 2 if
# success but a reboot is needed.
sub install_kvm_host_software
{
my ($vhost, $qemu) = @_;

# Install Webmin if missing
if (!&can_webmin_status($vhost)) {
	&$first_print($text{'xeninstall_webmin'});
	if ($vhost->{'status'} eq 'downwebmin' ||
	    $vhost->{'status'} eq 'nowebminlogin') {
		&$second_print($text{'xeninstall_ewebmindown'});
		return 0;
		}
	my ($src, $type, $err) = &get_install_webmin_source($vhost);
	if (!$src) {
		&$second_print($text{'xeninstall_ewebminsrc'});
		return 0;
		}
	my ($out, $err) = &install_webmin_server($vhost, $src, $type, 1);
	if ($err) {
		&$second_print(&text('xeninstall_ewebmin', $err));
		return 0;
		}
	&check_server_status($vhost);
	&save_managed_server($vhost);
	if (!$vhost->{'webminroot'}) {
		&$second_print($text{'xeninstall_ewebminroot'});
		return 0;
		}
	&$second_print($text{'create_done'});
	}

# Check status again, to ensure Webmin is accessible
&$first_print($text{'xeninstall_status'});
if (!&can_webmin_status($vhost)) {
	&$second_print(&text('xeninstall_estatus',&describe_status($vhost, 1)));
	return 0;
	}
&$second_print($text{'create_done'});

if (&redhat_server_type($vhost)) {
	# Install vital packages on Redhat
	&$first_print($text{'xeninstall_pkgs'});
	my ($ok, $err) = &install_package_on_server(
				$vhost, "wget lsof bzip2 psmisc");
	if (!$ok) {
		&$second_print(&text('xeninstall_epkgs', $err));
		return 0;
		}
	else {
		&$second_print($text{'create_done'});
		}
	my ($fok, $ferr) = &install_package_on_server($vhost, "fdisk");
	my ($pok, $perr) = &install_package_on_server($vhost, "parted");
	if (!$fok && !$pok) {
		&$second_print(&text('xeninstall_epkgs', $ferr."\n".$perr));
		return 0;
		}
	else {
		&$second_print($text{'create_done'});
		}

	# Install KVM packages
	&$first_print($text{'kvminstall_kvm'});
	my ($ok, $err) = &install_package_on_server($vhost,
		"kvm kvm-qemu-img qemu-kvm qemu-img qemu-kvm-tools kvm-tools bridge-utils");
	if (!$ok) {
		&$second_print(&text('kvminstall_epkgs', $err));
		return 0;
		}
	else {
		# Also optional packages
		foreach my $p ("kmod-kvm", "ebtables", "openssh-clients",
			       "libcgroup-tools", "libcgroup") {
			&install_package_on_server($vhost, $p);
			}
		&$second_print($text{'create_done'});
		}

	# Activate cgroups
	&$first_print($text{'kvminstall_cgroup'});
	my ($out, $ex, $err) = &execute_command_on_server($vhost,
		"service cgconfig start && chkconfig cgconfig on");
	if ($ex || $err) {
		&$second_print(&text('kvminstall_ecgroup', $err || $out));
		}
	else {
		&$second_print($text{'create_done'});
		}
	}
elsif (&debian_server_type($vhost)) {
	# Install vital packages on Debian
	&$first_print($text{'xeninstall_pkgs'});
	my ($ok, $err) = &install_package_on_server(
				$vhost, "wget lsof bzip2 parted psmisc");
	if (!$ok) {
		&$second_print(&text('xeninstall_epkgs', $err));
		return 0;
		}
	else {
		&$second_print($text{'create_done'});
		}

	# Turm off apparmor
	&$first_print($text{'kvminstall_apparmor'});
	my @st = &stat_file_on_server($vhost, "/etc/init.d/apparmor");
	if (@st) {
		&execute_command_on_server($vhost,
			"/etc/init.d/apparmor stop");
		&execute_command_on_server($vhost,
			"update-rc.d -f apparmor remove");
		&$second_print($text{'create_done'});
		}
	else {
		&$second_print($text{'kvminstall_noapparmor'});
		}

	# Install KVM packages
	&$first_print($text{'kvminstall_kvm'});
	my ($ok, $err) = &install_package_on_server($vhost,
		"kvm qemu");
	if (!$ok) {
		&$second_print(&text('kvminstall_epkgs', $err));
		return 0;
		}
	else {
		# Also optional packages
		foreach my $p ("ebtables", "cgroup-bin") {
			&install_package_on_server($vhost, $p);
			}
		&$second_print($text{'create_done'});
		}

	# Activate cgroups (if a separate init script exists)
	&$first_print($text{'kvminstall_cgroup'});
	my @st = &stat_file_on_server($vhost, "/etc/init.d/cgconfig");
	if (@st) {
		my ($out, $ex, $err) = &execute_command_on_server($vhost,
			"/etc/init.d/cgconfig start && ".
			"update-rc.d cgconfig defaults");
		if ($ex || $err) {
			&$second_print(&text('kvminstall_ecgroup',
					     $err || $out));
			}
		else {
			&$second_print($text{'create_done'});
			}
		}
	else {
		&$second_print($text{'kvminstall_nocgroup'});
		}
	}
else {
	# Unknown OS type
	&$first_print(&text('xeninstall_etype',
			    &describe_os($vhost->{'type'})));
	return 0;
	}

# Activate KVM kernel module
if (!$qemu) {
	&$first_print($text{'kvminstall_kmod'});
	my ($mout, $mex, $merr) = &execute_command_on_server($vhost,
		"modprobe kvm-intel || modprobe kvm-amd");
	my ($out, $ex, $err) = &execute_command_on_server($vhost,
		"/sbin/lsmod");
	if ($out !~ /kvm/) {
		&$first_print(&text('kvminstall_ekmod',$mout || $merr));
		return 0;
		}
	my @st = &stat_file_on_server($vhost, "/dev/kvm");
	if (!@st) {
		&$first_print($text{'kvminstall_ekmod2'});
		return 0;
		}
	&$second_print($text{'create_done'});
	}

# Create missing loopback devices
&$first_print($text{'kvminstall_loop'});
for(my $i=0; $i<8; $i++) {
	my $l = "/dev/loop".$i;
	my @st = &stat_file_on_server($vhost, $l);
	if (!@st) {
		&execute_command_on_server($vhost, "mknod $l b 7 $i");
		}
	}
&$second_print($text{'create_done'});

# Find network bridges
my $ifaces = &list_active_server_interfaces($vhost);
my $br = 0;
if (ref($ifaces)) {
	foreach my $iface (@$ifaces) {
		if ($iface->{'name'} =~ /^br/) {
			$br++;
			}
		}
	}

# Create a network bridge (same for Redhat and Debian-based systems)
&$first_print(&text('xeninstall_xenbr', 'br0'));
if ($br) {
	&$second_print($text{'xeninstall_xenbrgot'});
	}
else {
	# Copy bridge creation script
	my $iface = &first_ethernet_iface($vhost);
	my $eth = $iface ? $iface->{'name'} : 'eth0';
	my $src = $module_root_directory."/create-net-bridge.pl";
	my $dst = $vhost->{'webminroot'}."/net/create-net-bridge.pl";
	my $err = &put_file_to_server($vhost, $src, $dst);
	if ($err) {
		&$second_print(&text('xeninstall_exenbrcopy', $err));
		return 0;
		}
	my $pp = &get_server_perl_path($server);
	my $cmd = $pp." ".$dst." --interface $eth --bridge br0";
	my ($out, $ex, $err) = &execute_command_on_server($vhost, $cmd);
	if ($ex == 1 && !$err) {
		&$second_print($text{'xeninstall_xenbrreboot'});
		return 2;	# Need reboot to activate
		}
	elsif ($ex || $err) {
		&$second_print(&text('xeninstall_exenbr',$err || $out));
		return 0;
		}
	else {
		&$second_print($text{'create_done'});
		}
	}

return 1;
}

# kvm_host_supports_vlan(&vhost)
# Returns 1 if the vlan= net option is supported
sub kvm_host_supports_vlan
{
my ($vhost) = @_;
my $ver = &kvm_host_version($vhost);
return &compare_versions($ver, "2.9.0") < 0;
}

1;

