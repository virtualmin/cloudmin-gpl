# Functions for managing iSCSI servers and clients

# supports_iscsi()
# Returns 1 if iSCSI configuration is supported on this Cloudmin install
sub supports_iscsi
{
return &indexof("kvm", @virtual_server_management_types) >= 0 ||
       &indexof("xen", @virtual_server_management_types) >= 0;
}

# list_iscsi_target_servers()
# Returns a list of managed systems that are setup as an iSCSI server
sub list_iscsi_target_servers
{
return grep { $_->{'iscsi_module'} } &list_managed_servers();
}

# list_possible_iscsi_target_servers()
# Returns physical systems only
sub list_possible_iscsi_target_servers
{
return grep { $_->{'manager'} eq 'real' ||
	      $_->{'manager'} eq 'this' } &list_managed_servers();
}

# check_iscsi_server(&server)
# If a system can be an iSCSI server, return 1 and the Webmin module to use.
# Otherwise return 0 and an error message explaining why.
sub check_iscsi_server
{
my ($server) = @_;
if (!&can_ssh_status($server)) {
	return (0, $text{'iscsi_nossh'});
	}
if ($server->{'status'} ne 'virt' && $server->{'status'} ne 'novirt') {
	return (0, $text{'iscsi_nowebmin'});
	}
my $info = &get_server_collected($server);
if ($info->{'general'}->{'version'} < 1.600) {
	return (0, $text{'iscsi_noversion'});
	}
my $mod;
foreach my $m ("iscsi-target", "iscsi-server") {
	next if (!&remote_foreign_check($server, $m));
	&remote_foreign_require($server, $m);
	next if (!&remote_foreign_call($server, $m, "foreign_installed", $m));
	$mod = $m;
	last;
	}
if (!$mod) {
	return (0, $text{'iscsi_nomod'});
	}
return (1, $mod);
}

1;
