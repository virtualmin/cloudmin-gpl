#!/usr/local/bin/perl
# Show a form for registering a kvm host, and editing config settings

require './server-manager-lib.pl';
&can_action_error(undef, "global");
&ReadParse();
&ui_print_header(undef, $in{'new'} ? $text{'kvm_create'} :
		        $module_info{'onehost'} ? $text{'kvm_editone'} :
				   		  $text{'kvm_edit'}, "",
		 $in{'new'} ? "createkvm" : "editkvm");
@allservers = &list_managed_servers();
($kvm) = grep { $_->{'id'} eq $in{'id'} } @allservers;
$kvm || &error($text{'kvm_egone'});

if ($in{'new'}) {
	# Can this system even host KVM instances?
	$err = &check_kvm_host_software($kvm);
	if ($err) {
		print &ui_confirmation_form(
			"install_kvm.cgi",
			&text('kvm_einstall', $err),
			[ [ 'id', $in{'id'} ] ],
			[ [ undef, $text{'kvm_install'} ] ],
			&ui_checkbox("noqemu", 1, $text{'kvm_installq'}, 1),
			);
		&ui_print_footer("list_kvms.cgi", $text{'kvms_return'});
		return;
		}
	}

print &ui_form_start("save_kvm.cgi", "post");
print &ui_hidden("new", $in{'new'});
print &ui_hidden_table_start($text{'kvm_header'}, "width=100%", 2, "main", 1);

# System to register
print &ui_hidden("id", $in{'id'});
if (!$module_info{'onehost'}) {
	print &ui_table_row($text{'kvm_host'},
			    $kvm->{'host'});
	}

if (!$module_info{'onehost'}) {
	# Location group
	&show_host_location_field($kvm);
	}

# KVM directory
print &ui_table_row($text{'kvm_dir'},
	&ui_textbox("dir", $kvm->{'kvm_dir'} || "/kvm", 60));

# Find volume groups on host, if we can
@pvs = ( );
if ($kvm->{'status'} ne 'down' &&
    &remote_foreign_check($kvm, "lvm")) {
	$last_remote_error = undef;
	&remote_foreign_require($kvm, "lvm", "lvm-lib.pl");
	if (!$last_remote_error) {
		@pvs = &remote_foreign_call($kvm, "lvm",
					    "list_volume_groups");
		$no_lvm = 1 if (!@pvs && !$last_remote_error);
		}
	}

# Use drop-down of VG if possible, text field otherwise
if (@pvs) {
	$lvfield = &ui_select("lvm", $kvm->{'kvm_vg'},
			      [ map { $_->{'name'} } @pvs ], 1, 0,
			      $kvm->{'kvm_vg'} ? 1 : 0);
	}
else {
	$lvfield = &ui_textbox("lvm", $kvm->{'kvm_vg'}, 40);
	}

# Check if iSCSI is supported
@iservers = &list_iscsi_target_servers();
if (&supports_iscsi() && @iservers) {
	$ifield = &ui_select("iscsi", $kvm->{'kvm_iscsi'},
		     [ map { [ $_->{'id'}, $_->{'host'} ] } @iservers ]);
	}

# Build table of storage types
@stable = ( [ 1, $text{'kvm_storage1'} ] );
if (!$no_lvm) {
	push(@stable, [ 0, $text{'kvm_storage0'}, $lvfield ]);
	}
if ($ifield) {
	push(@stable, [ 2, $text{'kvm_storage2'}, $ifield ]);
	}
if (@stable > 1) {
	print &ui_table_row($text{'kvm_storage'},
		&ui_radio_table("lvm_def", $kvm->{'kvm_iscsi'} ne '' ? 2 :
					   $kvm->{'kvm_vg'} ? 0 : 1, \@stable));
	}

# Allow memory over-committing?
print &ui_table_row($text{'openvz_overmemory'},
	&ui_yesno_radio("overmemory", $kvm->{'kvm_overmemory'}));

# DNS domain name to add under (if we host any)
@zones = &list_bind_zones();
$zonename = $kvm->{'kvm_zone'} || $config{'kvm_zone'};
$link = " ".&bind_module_link();
if (@zones) {
	print &ui_table_row($text{'kvm_domain'},
		&ui_select("zone", $zonename,
		    [ map { [ $_->{'name'}, $_->{'desc'} ] } @zones ]).$link);
	}
else {
	print &ui_table_row($text{'kvm_domain2'},
		&ui_textbox("zone", $zonename, 30).$link);
	}

# Add all existing KVM instances at same time?
if ($in{'new'}) {
	# Auto-detect?
	print &ui_table_row($text{'kvm_autoadd'},
		&ui_radio("autoadd", 0,
			  [ [ 0, $text{'no'} ],
			    [ 1, $text{'kvm_autoadd1'} ],
			    [ 2, $text{'kvm_autoadd2'} ] ]));

	# Login type
	print &ui_table_row($text{'kvm_autologin'},
		&ui_radio("autologin", 1,
			  [ [ 0, $text{'kvm_autologin0'} ],
			    [ 1, $text{'kvm_autologin1'} ] ]));
	}

# KVM version
if (&can_ssh_status($kvm)) {
	my $ver = &kvm_host_version($kvm);
	if ($ver) {
		print &ui_table_row($text{'kvm_version'}, $ver);
		}
	}

print &ui_hidden_table_end("main");

print &ui_hidden_table_start($text{'kvm_nheader'}, "width=100%", 2, "net", 0);

# IP allocation range and CIDR
@possifaces = &list_kvm_host_bridges($kvm);
@hostifaces = split(/\s+/, $kvm->{'kvm_iface'});
@allocifaces = &unique(@possifaces, @hostifaces);
$multi_ifaces = @possifaces > 1 || $kvm->{'kvm_iface'};
print &ui_table_row($text{'kvm_range'},
	&show_ip_range_input($kvm, "kvm", 1,
			     $multi_ifaces ? \@allocifaces : undef));

# Show IPv6 allocation ranges, if any
$input6 = &show_ip6_range_input($kvm, "kvm", 1,
				$multi_ifaces ? \@allocifaces : undef);
print &ui_table_row($text{'kvm_range6'}, $input6) if ($input6);

# Network interfaces to use on host system
if ($multi_ifaces) {
	print &ui_table_row($text{'kvm_iface'},
		&ui_radio("iface_def", scalar(@hostifaces) ? 0 : 1,
			  [ [ 1, $text{'kvm_iface1'} ],
			    [ 0, $text{'kvm_iface0'} ] ])."<br>\n".
		&ui_select("iface", \@hostifaces, \@possifaces,
			   scalar(@possifaces), 1, 1));
	}

# Source resolv.conf file
print &ui_table_row($text{'kvm_resolv'},
	&ui_opt_textbox("resolv", $kvm->{'kvm_resolv'}, 30,
			$text{'kvm_resolvdef'}, $text{'kvm_resolvother'})." ".
	&file_chooser_button("resolv"));

print &ui_hidden_table_end("net");

# Section for minimum resources
&show_host_floor_table($kvm);

if (!$module_info{'onehost'}) {
	# Section for caching
	&show_host_images_cache_table($kvm, "kvm");
	}

# Section for default backup destination
&show_default_backup_dest_table($kvm);

print &ui_form_end($in{'new'} ? [ [ undef, $text{'kvm_reg'} ] ]
			      : [ [ undef, $text{'save'} ],
				  [ "delete", $text{'kvm_unreg'} ] ]);

if ($module_info{'onehost'}) {
        &ui_print_footer("", $text{'index_return'});
        }
else {
	&ui_print_footer("list_kvms.cgi", $text{'kvms_return'});
	}
