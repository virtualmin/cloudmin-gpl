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
# If a system can be an iSCSI server, return undef. Otherwise return an error
# message explaining why, such as a missing module
sub check_iscsi_server
{
my ($server) = @_;
if (!&can_ssh_status($server)) {
	return $text{'iscsi_nossh'};
	}
if ($server->{'status'} ne 'virt' && $server->{'status'} ne 'novirt') {
	return $text{'iscsi_nowebmin'};
	}
my $info = &get_server_collected($server);
if ($info->{'general'}->{'version'} < 1.600) {
	return $text{'iscsi_noversion'};
	}
my $mod;
foreach my $m ("iscsi-target", "iscsi-server") {
	if (&remote_foreign_check($server, $m) &&
	    &remote_foreign_installed($server, $m)) {
		$mod = $m;
		last;
		}
	}
if (!$mod) {
	return $text{'iscsi_nomod'};
	}
return undef;
}

1;
