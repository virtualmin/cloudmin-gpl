#!/usr/local/bin/perl
# Add, update to remove a system doing kvm hosting

require './server-manager-lib.pl';
&can_action_error(undef, "global");
&foreign_require("net", "net-lib.pl");
&ReadParse();
&error_setup($text{'kvm_err'});
$kvm = &get_managed_server($in{'id'});
$kvm || &error($text{'kvm_egone'});
&obtain_lock_server($kvm);

if ($in{'delete'}) {
	# Just mark this system as no longer a KVM host
	$kvm->{'kvm_host'} = 0;
	&save_managed_server($kvm);
	}
elsif ($in{'find'}) {
	# Redirect to find form
	&redirect("find_form.cgi?id=$kvm->{'id'}&type=kvm");
	return;
	}
else {
	if ($in{'new'}) {
		# Is the newly selected server actually capable of hosting
		# KVM instances?
		&can_ssh_status($kvm) || &error($text{'kvm_edown'});
		$err = &check_kvm_host_software($kvm);
		$err && &error(&text('kvm_esoft', $err));
		}

	# Save location group
	&parse_host_location_field($kvm, \%in);

	# Validate and save other inputs, starting with the directory
	$kvm->{'kvm_dir'} = $in{'dir'};
	($out, $ex) = &execute_command_on_server($kvm,
			"mkdir ".quotemeta($in{'dir'}).
			" ; test -d ".quotemeta($in{'dir'}));
	$ex && &error($text{'kvm_edir'});

	# Save and check LVM
	if ($in{'lvm_def'}) {
		delete($kvm->{'kvm_vg'});
		}
	else {
		$in{'lvm'} =~ /^[A-Za-z0-9\.\-\_]+$/ ||
			&error($text{'kvm_elvm'});
		$err = &check_xen_host_lvm($kvm, $in{'lvm'});
		&error(&text('kvm_elvmerr', $err)) if ($err);
		$kvm->{'kvm_vg'} = $in{'lvm'};
		}

	# DNS zone
	$in{'zone'} =~ /^[a-z0-9\.\-\_]+$/i || &error($text{'kvm_ezone'});
	$kvm->{'kvm_zone'} = $in{'zone'};

	# IP allocation ranges
	($kvm->{'kvm_start'}, $kvm->{'kvm_end'}, $kvm->{'kvm_cidr'},
	 $kvm->{'kvm_gws'}, $kvm->{'kvm_ifaces'}) = &parse_ip_range_input(\%in);

	# Host system interfaces
	if ($in{'iface_def'}) {
		$kvm->{'kvm_iface'} = undef;
		}
	else {
		$kvm->{'kvm_iface'} = join(' ', split(/\0/, $in{'iface'}));
		}

	# Source for resolv.conf
	$in{'resolv_def'} || -r $in{'resolv'} ||
		&error($text{'kvm_eresolv'});
	$kvm->{'kvm_resolv'} = $in{'resolv_def'} ? undef : $in{'resolv'};

	# Cache directory
	&parse_host_images_cache_table($kvm, \%in, "kvm");

	# Backup dir
	&parse_default_backup_dest_table($kvm, \%in);

	$kvm->{'kvm_host'} = 1;
	&save_managed_server($kvm);

	if ($in{'autoadd'} && $in{'autologin'}) {
		# Added, redirect to find page
		&redirect("find.cgi?id=$kvm->{'id'}&type=kvm&copyauth=1&".
			  "running=".($in{'autoadd'} == 1 ? 1 : 0));
		}
	elsif ($in{'autoadd'} && !$in{'autologin'}) {
		# Redirect to find form
		&redirect("find_form.cgi?id=$kvm->{'id'}&type=kvm&".
			  "running=".($in{'autoadd'} == 1 ? 1 : 0));
		}
	}

&release_lock_server($kvm);
&webmin_log($in{'delete'} ? "unhost" : "host", "server", $kvm->{'host'},
	    { 'type' => 'kvm' });
&redirect("list_kvms.cgi");

